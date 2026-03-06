package proxy

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"regexp"
	"strconv"
	"strings"

	"github.com/anthropics/hyper-ai-proxy/internal/config"
	"github.com/anthropics/hyper-ai-proxy/internal/ollama"
	"github.com/anthropics/hyper-ai-proxy/internal/usage"
)

type modelTokenSpec struct {
	ContextWindow   int
	MaxOutputTokens int
}

const (
	hardTokenCap             = 32000
	minimumHeadroom          = 1024
	headroomRatio            = 0.1
	interleavedThinkingBeta  = "interleaved-thinking-2025-05-14"
	antropicVersion          = "2023-06-01"
	maxUsageCaptureBytes     = 4 << 20
	internalContentTypeJSON  = "application/json"
	internalContentTypePlain = "text/plain; charset=utf-8"
)

var (
	reThinkingSuffix       = regexp.MustCompile(`^(.*)-thinking-([0-9]+)$`)
	reCookieDomain         = regexp.MustCompile(`(?i)Domain=\.?ampcode\.com`)
	errRetryWithAPI        = errors.New("retry with /api prefix")
	defaultModelTokenSpecs = map[string]modelTokenSpec{
		"claude-opus-4-6":     {ContextWindow: 200000, MaxOutputTokens: 128000},
		"claude-sonnet-4-6":   {ContextWindow: 200000, MaxOutputTokens: 64000},
		"gpt-5.3-codex":       {ContextWindow: 400000, MaxOutputTokens: 128000},
		"gpt-5.3-codex-spark": {ContextWindow: 125000, MaxOutputTokens: 8192},
	}
)

type contextKey string

const (
	ctxKeyModel          contextKey = "request_model"
	ctxKeyThinking       contextKey = "thinking_enabled"
	ctxKeyRetryAttempted contextKey = "retry_attempted"
)

type Server struct {
	cfg             config.Config
	tracker         *usage.Tracker
	modelTokenSpecs map[string]modelTokenSpec
	localProxy      *httputil.ReverseProxy
	localRetry      *httputil.ReverseProxy
	ampProxy        *httputil.ReverseProxy
	vercelProxy     *httputil.ReverseProxy
	ollamaProxy     *httputil.ReverseProxy
	localTargetURL  *url.URL
	ollamaClient    *ollama.Client
}

func NewServer(cfg config.Config) *Server {
	localURL := mustParseURL(fmt.Sprintf("http://%s:%d", cfg.TargetHost, cfg.TargetPort))
	ampURL := mustParseURL("https://ampcode.com")
	vercelURL := mustParseURL("https://ai-gateway.vercel.sh")

	s := &Server{
		cfg:             cfg,
		tracker:         usage.NewTracker(),
		modelTokenSpecs: loadModelTokenSpecs(cfg.TokenSpecsFile),
		localTargetURL:  localURL,
		ollamaClient:    ollama.NewClient(cfg.OllamaURL),
	}

	transport := http.DefaultTransport

	s.localProxy = &httputil.ReverseProxy{
		Rewrite:        s.localRewrite,
		ModifyResponse: s.localModifyResponse,
		ErrorHandler:   s.localErrorHandler,
		Transport:      transport,
	}

	s.localRetry = &httputil.ReverseProxy{
		Rewrite:   s.localRewrite,
		Transport: transport,
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
			log.Printf("[HyperProxy] Local retry proxy error: %v", err)
			http.Error(w, "Bad Gateway", http.StatusBadGateway)
		},
	}

	s.ampProxy = &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(ampURL)
			pr.Out.Host = ampURL.Host
			pr.Out.Header.Set("Connection", "close")
		},
		ModifyResponse: s.ampModifyResponse,
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
			log.Printf("[HyperProxy] Amp proxy error: %v", err)
			http.Error(w, "Bad Gateway", http.StatusBadGateway)
		},
		Transport: transport,
	}

	s.vercelProxy = &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(vercelURL)
			pr.Out.URL.Path = "/v1/messages"
			pr.Out.URL.RawPath = ""
			pr.Out.URL.RawQuery = ""
			pr.Out.Host = vercelURL.Host
			pr.Out.Header.Set("Connection", "close")
			pr.Out.Header.Set("x-api-key", s.cfg.VercelAPIKey)
			pr.Out.Header.Set("anthropic-version", antropicVersion)
			pr.Out.Header.Set("content-type", internalContentTypeJSON)
			if thinkingEnabledFromContext(pr.In.Context()) {
				mergeHeaderValue(pr.Out.Header, "anthropic-beta", interleavedThinkingBeta)
			}
		},
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
			log.Printf("[HyperProxy] Vercel proxy error: %v", err)
			http.Error(w, "Bad Gateway", http.StatusBadGateway)
		},
		Transport: transport,
	}

	// Ollama direct proxy (OpenAI-compatible endpoint)
	if cfg.OllamaEnabled {
		ollamaURL := mustParseURL(cfg.OllamaURL)
		s.ollamaProxy = &httputil.ReverseProxy{
			Rewrite: func(pr *httputil.ProxyRequest) {
				ollamaTarget := mustParseURL(ollamaURL.String() + "/v1")
				pr.SetURL(ollamaTarget)
				pr.Out.Host = ollamaURL.Host
				pr.Out.Header.Set("Connection", "close")
			},
			ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
				log.Printf("[HyperProxy] Ollama proxy error: %v", err)
				http.Error(w, "Ollama unavailable", http.StatusBadGateway)
			},
			Transport: transport,
		}
		log.Printf("[HyperProxy] Ollama direct routing enabled: %s", cfg.OllamaURL)
	}

	return s
}

func (s *Server) Handler() http.Handler {
	return http.HandlerFunc(s.serveHTTP)
}

func (s *Server) serveHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/internal/health" {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
		return
	}

	if r.URL.Path == "/internal/stats" {
		s.handleStats(w, r)
		return
	}

	if r.URL.Path == "/internal/ollama/models" {
		s.handleOllamaModels(w, r)
		return
	}

	if r.URL.Path == "/internal/ollama/status" {
		s.handleOllamaStatus(w, r)
		return
	}

	if s.cfg.ExternalAccess && s.cfg.APIKey != "" && !isLocalhostRequest(r) {
		if !validAPIKey(r, s.cfg.APIKey) {
			w.Header().Set("Content-Type", internalContentTypePlain)
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
	}

	if strings.HasPrefix(r.URL.Path, "/auth/cli-login") || strings.HasPrefix(r.URL.Path, "/api/auth/cli-login") {
		loginPath := r.URL.Path
		if strings.HasPrefix(loginPath, "/api/") {
			loginPath = strings.TrimPrefix(loginPath, "/api")
		}
		if r.URL.RawQuery != "" {
			loginPath += "?" + r.URL.RawQuery
		}
		http.Redirect(w, r, "https://ampcode.com"+loginPath, http.StatusFound)
		return
	}

	// Rewrite common OpenAI paths that lack /v1 prefix
	if strings.HasPrefix(r.URL.Path, "/provider/") {
		old := r.URL.Path
		r.URL.Path = "/api" + r.URL.Path
		log.Printf("[HyperProxy] Rewriting provider path: %s -> %s", old, r.URL.Path)
	} else if isOpenAIPath(r.URL.Path) {
		old := r.URL.Path
		r.URL.Path = "/v1" + r.URL.Path
		log.Printf("[HyperProxy] Rewriting OpenAI path: %s -> %s", old, r.URL.Path)
	}

	if isAmpManagementPath(r.URL.Path) {
		s.ampProxy.ServeHTTP(w, r)
		return
	}

	r = s.prepareRequest(r)
	model := modelFromContext(r.Context())
	if model != "" {
		s.tracker.RecordRequest(model)
	}

	if s.cfg.VercelEnabled && s.cfg.VercelAPIKey != "" && r.Method == http.MethodPost && isClaudeModel(model) {
		s.serveWithUsageCapture(w, r, s.vercelProxy)
		return
	}

	// Direct Ollama routing for local-* models (bypass cli-proxy-api-plus)
	if s.cfg.OllamaEnabled && s.ollamaProxy != nil && isLocalModel(model) {
		log.Printf("[HyperProxy] Routing local model '%s' directly to Ollama", model)
		s.serveWithUsageCapture(w, r, s.ollamaProxy)
		return
	}

	s.serveWithUsageCapture(w, r, s.localProxy)
}

func (s *Server) prepareRequest(r *http.Request) *http.Request {
	ctx := r.Context()

	if r.Method != http.MethodPost || r.Body == nil {
		if strings.HasPrefix(r.URL.Path, "/api/") || strings.HasPrefix(r.URL.Path, "/v1/") {
			return r
		}
		ctx = context.WithValue(ctx, ctxKeyRetryAttempted, false)
		return r.WithContext(ctx)
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		log.Printf("[HyperProxy] Failed to read request body: %v", err)
		body = nil
	}
	_ = r.Body.Close()

	processedBody, meta := processThinking(body)
	r = resetRequestBody(r, processedBody)

	if meta.model != "" {
		ctx = context.WithValue(ctx, ctxKeyModel, meta.model)
	}
	if meta.thinkingEnabled {
		ctx = context.WithValue(ctx, ctxKeyThinking, true)
		mergeHeaderValue(r.Header, "anthropic-beta", interleavedThinkingBeta)
	}
	if !(strings.HasPrefix(r.URL.Path, "/api/") || strings.HasPrefix(r.URL.Path, "/v1/")) {
		ctx = context.WithValue(ctx, ctxKeyRetryAttempted, false)
	}

	return r.WithContext(ctx)
}

func (s *Server) serveWithUsageCapture(w http.ResponseWriter, r *http.Request, next http.Handler) {
	model := modelFromContext(r.Context())
	if model == "" {
		next.ServeHTTP(w, r)
		return
	}

	cw := newCaptureWriter(w, maxUsageCaptureBytes)
	next.ServeHTTP(cw, r)

	prompt, completion, ok := extractUsageFromJSON(cw.Bytes())
	if !ok {
		return
	}
	if prompt > 0 || completion > 0 {
		s.tracker.RecordTokens(model, prompt, completion)
	}
}

func (s *Server) handleStats(w http.ResponseWriter, r *http.Request) {
	days := 0
	if rawDays := strings.TrimSpace(r.URL.Query().Get("days")); rawDays != "" {
		parsed, err := strconv.Atoi(rawDays)
		if err != nil || parsed < 0 {
			http.Error(w, "invalid days query parameter", http.StatusBadRequest)
			return
		}
		days = parsed
	}
	writeJSON(w, http.StatusOK, s.tracker.Snapshot(days))
}

func (s *Server) localRewrite(pr *httputil.ProxyRequest) {
	pr.SetURL(s.localTargetURL)
	pr.Out.Host = s.localTargetURL.Host
	pr.Out.Header.Set("Connection", "close")
	if thinkingEnabledFromContext(pr.In.Context()) {
		mergeHeaderValue(pr.Out.Header, "anthropic-beta", interleavedThinkingBeta)
	}
	// Strip external-access auth headers so the backend doesn't misinterpret them
	if s.cfg.ExternalAccess && s.cfg.APIKey != "" {
		if auth := pr.Out.Header.Get("Authorization"); auth != "" {
			if strings.TrimSpace(strings.TrimPrefix(strings.ToLower(strings.TrimSpace(auth)), "bearer ")) == strings.ToLower(s.cfg.APIKey) ||
				strings.TrimSpace(auth[min(7, len(auth)):]) == s.cfg.APIKey {
				pr.Out.Header.Del("Authorization")
			}
		}
		if pr.Out.Header.Get("x-api-key") == s.cfg.APIKey {
			pr.Out.Header.Del("x-api-key")
		}
	}
}

func (s *Server) localModifyResponse(resp *http.Response) error {
	if isModelsPath(resp) {
		if err := enrichModelsResponse(resp, s.modelTokenSpecs); err != nil {
			log.Printf("[HyperProxy] Failed to enrich /v1/models metadata: %v", err)
		}
	}

	if resp.StatusCode != http.StatusNotFound {
		return nil
	}
	req := resp.Request
	if req == nil {
		return nil
	}
	if retryAttemptedFromContext(req.Context()) {
		return nil
	}
	if strings.HasPrefix(req.URL.Path, "/api/") || strings.HasPrefix(req.URL.Path, "/v1/") {
		return nil
	}
	return errRetryWithAPI
}

func isModelsPath(resp *http.Response) bool {
	if resp == nil || resp.Request == nil || resp.Request.URL == nil {
		return false
	}
	if resp.Request.Method != http.MethodGet {
		return false
	}
	path := resp.Request.URL.Path
	return path == "/v1/models" || path == "/models" || strings.HasPrefix(path, "/v1/models?") || strings.HasPrefix(path, "/models?")
}

func enrichModelsResponse(resp *http.Response, specs map[string]modelTokenSpec) error {
	if resp.Body == nil {
		return nil
	}
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	_ = resp.Body.Close()

	trimmed := bytes.TrimSpace(body)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		resp.Body = io.NopCloser(bytes.NewReader(body))
		resp.ContentLength = int64(len(body))
		resp.Header.Set("Content-Length", strconv.Itoa(len(body)))
		return nil
	}

	var payload map[string]any
	if err := json.Unmarshal(body, &payload); err != nil {
		resp.Body = io.NopCloser(bytes.NewReader(body))
		resp.ContentLength = int64(len(body))
		resp.Header.Set("Content-Length", strconv.Itoa(len(body)))
		return nil
	}

	rows, ok := payload["data"].([]any)
	if !ok {
		resp.Body = io.NopCloser(bytes.NewReader(body))
		resp.ContentLength = int64(len(body))
		resp.Header.Set("Content-Length", strconv.Itoa(len(body)))
		return nil
	}

	changed := false
	for _, row := range rows {
		entry, ok := row.(map[string]any)
		if !ok {
			continue
		}
		id, _ := entry["id"].(string)
		spec, exists := specs[id]
		if !exists {
			continue
		}
		entry["context_window"] = spec.ContextWindow
		entry["max_output_tokens"] = spec.MaxOutputTokens
		entry["contextWindow"] = spec.ContextWindow
		entry["maxTokens"] = spec.MaxOutputTokens
		changed = true
	}

	if !changed {
		resp.Body = io.NopCloser(bytes.NewReader(body))
		resp.ContentLength = int64(len(body))
		resp.Header.Set("Content-Length", strconv.Itoa(len(body)))
		return nil
	}

	encoded, err := json.Marshal(payload)
	if err != nil {
		resp.Body = io.NopCloser(bytes.NewReader(body))
		resp.ContentLength = int64(len(body))
		resp.Header.Set("Content-Length", strconv.Itoa(len(body)))
		return nil
	}

	resp.Body = io.NopCloser(bytes.NewReader(encoded))
	resp.ContentLength = int64(len(encoded))
	resp.Header.Set("Content-Length", strconv.Itoa(len(encoded)))
	resp.Header.Del("Content-Encoding")
	resp.Header.Set("Content-Type", internalContentTypeJSON)
	return nil
}

type tokenSpecJSON struct {
	ContextWindow   int `json:"contextWindow"`
	MaxOutputTokens int `json:"maxOutputTokens"`
}

func loadModelTokenSpecs(path string) map[string]modelTokenSpec {
	specs := cloneDefaultTokenSpecs()
	if strings.TrimSpace(path) == "" {
		return specs
	}

	data, err := os.ReadFile(path)
	if err != nil {
		log.Printf("[HyperProxy] token specs file not found, using defaults: %v", err)
		return specs
	}

	var payload map[string]tokenSpecJSON
	if err := json.Unmarshal(data, &payload); err != nil {
		log.Printf("[HyperProxy] failed to parse token specs file, using defaults: %v", err)
		return specs
	}

	loaded := 0
	for model, spec := range payload {
		if strings.TrimSpace(model) == "" || spec.ContextWindow <= 0 || spec.MaxOutputTokens <= 0 {
			continue
		}
		specs[model] = modelTokenSpec{
			ContextWindow:   spec.ContextWindow,
			MaxOutputTokens: spec.MaxOutputTokens,
		}
		loaded++
	}

	log.Printf("[HyperProxy] loaded %d token specs from %s", loaded, path)
	return specs
}

func cloneDefaultTokenSpecs() map[string]modelTokenSpec {
	cloned := make(map[string]modelTokenSpec, len(defaultModelTokenSpecs))
	for key, value := range defaultModelTokenSpecs {
		cloned[key] = value
	}
	return cloned
}

func (s *Server) localErrorHandler(w http.ResponseWriter, req *http.Request, err error) {
	if errors.Is(err, errRetryWithAPI) {
		newReq := req.Clone(req.Context())
		if req.GetBody != nil {
			body, bodyErr := req.GetBody()
			if bodyErr == nil {
				newReq.Body = body
			}
		}
		newReq.URL.Path = "/api" + req.URL.Path
		newReq.URL.RawPath = ""
		newReq.RequestURI = ""
		ctx := context.WithValue(newReq.Context(), ctxKeyRetryAttempted, true)
		newReq = newReq.WithContext(ctx)
		log.Printf("[HyperProxy] Retrying 404 path with /api prefix: %s -> %s", req.URL.Path, newReq.URL.Path)
		s.localRetry.ServeHTTP(w, newReq)
		return
	}

	log.Printf("[HyperProxy] Local proxy error: %v", err)
	http.Error(w, "Bad Gateway", http.StatusBadGateway)
}

func (s *Server) ampModifyResponse(resp *http.Response) error {
	location := resp.Header.Get("Location")
	if location != "" {
		resp.Header.Set("Location", rewriteAmpLocation(location))
	}

	setCookies := resp.Header.Values("Set-Cookie")
	if len(setCookies) > 0 {
		resp.Header.Del("Set-Cookie")
		for _, cookie := range setCookies {
			resp.Header.Add("Set-Cookie", reCookieDomain.ReplaceAllString(cookie, "Domain=localhost"))
		}
	}

	return nil
}

type thinkingMeta struct {
	model           string
	thinkingEnabled bool
}

func processThinking(body []byte) ([]byte, thinkingMeta) {
	meta := thinkingMeta{}
	body = bytes.TrimSpace(body)
	if len(body) == 0 {
		return body, meta
	}

	var jsonBody map[string]any
	if err := json.Unmarshal(body, &jsonBody); err != nil {
		return body, meta
	}

	rawModel, _ := jsonBody["model"].(string)
	if rawModel == "" {
		return body, meta
	}
	meta.model = rawModel

	if isLocalModel(rawModel) {
		if applyDefaultLocalReasoning(jsonBody) {
			encoded, marshalErr := json.Marshal(jsonBody)
			if marshalErr == nil {
				return encoded, meta
			}
		}
	}

	if !isClaudeModel(rawModel) {
		return body, meta
	}

	if strings.HasSuffix(rawModel, "-thinking") {
		meta.thinkingEnabled = true
		return body, meta
	}

	matches := reThinkingSuffix.FindStringSubmatch(rawModel)
	if len(matches) != 3 {
		return body, meta
	}

	prefix := matches[1]
	budget, err := strconv.Atoi(matches[2])
	if err != nil || budget <= 0 {
		return body, meta
	}

	cleanModel := prefix
	if strings.HasPrefix(rawModel, "gemini-claude-") {
		cleanModel = prefix + "-thinking"
	}
	jsonBody["model"] = cleanModel
	meta.model = cleanModel

	effectiveBudget := budget
	if effectiveBudget > hardTokenCap-1 {
		effectiveBudget = hardTokenCap - 1
	}

	jsonBody["thinking"] = map[string]any{
		"type":          "enabled",
		"budget_tokens": effectiveBudget,
	}
	ensureTokenHeadroom(jsonBody, effectiveBudget)
	meta.thinkingEnabled = true

	encoded, marshalErr := json.Marshal(jsonBody)
	if marshalErr != nil {
		return body, meta
	}
	return encoded, meta
}

func ensureTokenHeadroom(body map[string]any, budget int) {
	headroom := int(float64(budget) * headroomRatio)
	if headroom < minimumHeadroom {
		headroom = minimumHeadroom
	}
	required := budget + headroom
	if required > hardTokenCap {
		required = hardTokenCap
	}
	if required <= budget {
		required = budget + 1
		if required > hardTokenCap {
			required = hardTokenCap
		}
	}

	hasMaxOutput := false
	if _, ok := body["max_output_tokens"]; ok {
		hasMaxOutput = true
	}

	adjusted := false
	if raw, ok := body["max_tokens"]; ok {
		if current, parsed := intFromAny(raw); parsed {
			if current <= budget {
				body["max_tokens"] = required
			}
			adjusted = true
		}
	}
	if raw, ok := body["max_output_tokens"]; ok {
		if current, parsed := intFromAny(raw); parsed {
			if current <= budget {
				body["max_output_tokens"] = required
			}
			adjusted = true
		}
	}

	if !adjusted {
		if hasMaxOutput {
			body["max_output_tokens"] = required
		} else {
			body["max_tokens"] = required
		}
	}
}

func intFromAny(v any) (int, bool) {
	switch n := v.(type) {
	case int:
		return n, true
	case int32:
		return int(n), true
	case int64:
		return int(n), true
	case float64:
		return int(n), true
	case json.Number:
		i, err := n.Int64()
		if err != nil {
			return 0, false
		}
		return int(i), true
	case string:
		i, err := strconv.Atoi(strings.TrimSpace(n))
		if err != nil {
			return 0, false
		}
		return i, true
	default:
		return 0, false
	}
}

func resetRequestBody(r *http.Request, body []byte) *http.Request {
	if body == nil {
		body = []byte{}
	}
	reader := bytes.NewReader(body)
	r.Body = io.NopCloser(reader)
	r.ContentLength = int64(len(body))
	r.Header.Set("Content-Length", strconv.Itoa(len(body)))
	r.GetBody = func() (io.ReadCloser, error) {
		return io.NopCloser(bytes.NewReader(body)), nil
	}
	return r
}

func extractUsageFromJSON(body []byte) (int, int, bool) {
	body = bytes.TrimSpace(body)
	if len(body) == 0 || body[0] != '{' {
		return 0, 0, false
	}

	var jsonBody map[string]any
	if err := json.Unmarshal(body, &jsonBody); err != nil {
		return 0, 0, false
	}

	if usageObj, ok := jsonBody["usage"].(map[string]any); ok {
		prompt := intValue(usageObj, "prompt_tokens", "input_tokens")
		completion := intValue(usageObj, "completion_tokens", "output_tokens")
		return prompt, completion, prompt > 0 || completion > 0
	}

	if messageObj, ok := jsonBody["message"].(map[string]any); ok {
		if usageObj, ok := messageObj["usage"].(map[string]any); ok {
			prompt := intValue(usageObj, "prompt_tokens", "input_tokens")
			completion := intValue(usageObj, "completion_tokens", "output_tokens")
			return prompt, completion, prompt > 0 || completion > 0
		}
	}

	return 0, 0, false
}

func intValue(dict map[string]any, keys ...string) int {
	for _, key := range keys {
		if v, ok := intFromAny(dict[key]); ok {
			if v < 0 {
				return 0
			}
			return v
		}
	}
	return 0
}

func mergeHeaderValue(h http.Header, name, value string) {
	existing := h.Get(name)
	if existing == "" {
		h.Set(name, value)
		return
	}
	for _, part := range strings.Split(existing, ",") {
		if strings.TrimSpace(part) == value {
			h.Set(name, existing)
			return
		}
	}
	h.Set(name, existing+","+value)
}

func rewriteAmpLocation(location string) string {
	if strings.HasPrefix(location, "https://ampcode.com/") {
		rest := strings.TrimPrefix(location, "https://ampcode.com/")
		return "/api/" + rest
	}
	if strings.HasPrefix(location, "http://ampcode.com/") {
		rest := strings.TrimPrefix(location, "http://ampcode.com/")
		return "/api/" + rest
	}
	if strings.HasPrefix(location, "/") {
		return "/api/" + strings.TrimPrefix(location, "/")
	}
	return location
}

// isOpenAIPath detects common OpenAI-compatible paths that should be routed to /v1/*
func isOpenAIPath(path string) bool {
	switch {
	case strings.HasPrefix(path, "/chat/completions"):
		return true
	case strings.HasPrefix(path, "/completions"):
		return true
	case strings.HasPrefix(path, "/models"):
		return true
	case strings.HasPrefix(path, "/embeddings"):
		return true
	default:
		return false
	}
}

func isAmpManagementPath(path string) bool {
	if strings.HasPrefix(path, "/api/provider/") {
		return false
	}
	if strings.HasPrefix(path, "/v1/") {
		return false
	}
	if strings.HasPrefix(path, "/api/v1/") {
		return false
	}
	return true
}

func isClaudeModel(model string) bool {
	return strings.HasPrefix(model, "claude-") || strings.HasPrefix(model, "gemini-claude-")
}

func isLocalModel(model string) bool {
	return strings.HasPrefix(model, "local-")
}

func applyDefaultLocalReasoning(body map[string]any) bool {
	if _, hasReasoning := body["reasoning"]; hasReasoning {
		return false
	}
	if _, hasThink := body["think"]; hasThink {
		return false
	}
	if _, hasThinking := body["thinking"]; hasThinking {
		return false
	}
	body["reasoning"] = map[string]any{"effort": "none"}
	return true
}

func validAPIKey(r *http.Request, expected string) bool {
	auth := strings.TrimSpace(r.Header.Get("Authorization"))
	if strings.HasPrefix(strings.ToLower(auth), "bearer ") {
		if strings.TrimSpace(auth[7:]) == expected {
			return true
		}
	}
	if strings.TrimSpace(r.Header.Get("x-api-key")) == expected {
		return true
	}
	return false
}

func isLocalhostRequest(r *http.Request) bool {
	host := strings.TrimSpace(r.RemoteAddr)
	if host == "" {
		return true
	}

	addrHost, _, err := net.SplitHostPort(host)
	if err == nil {
		host = addrHost
	}
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	return ip.IsLoopback()
}

func modelFromContext(ctx context.Context) string {
	v, _ := ctx.Value(ctxKeyModel).(string)
	return v
}

func thinkingEnabledFromContext(ctx context.Context) bool {
	v, _ := ctx.Value(ctxKeyThinking).(bool)
	return v
}

func retryAttemptedFromContext(ctx context.Context) bool {
	v, _ := ctx.Value(ctxKeyRetryAttempted).(bool)
	return v
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", internalContentTypeJSON)
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(payload); err != nil {
		log.Printf("[HyperProxy] Failed to encode JSON response: %v", err)
	}
}

func mustParseURL(raw string) *url.URL {
	u, err := url.Parse(raw)
	if err != nil {
		panic(err)
	}
	return u
}

type captureWriter struct {
	http.ResponseWriter
	buffer bytes.Buffer
	limit  int
	over   bool
}

func newCaptureWriter(w http.ResponseWriter, limit int) *captureWriter {
	return &captureWriter{ResponseWriter: w, limit: limit}
}

func (w *captureWriter) Write(p []byte) (int, error) {
	if !w.over {
		remaining := w.limit - w.buffer.Len()
		if remaining > 0 {
			toCopy := len(p)
			if toCopy > remaining {
				toCopy = remaining
			}
			_, _ = w.buffer.Write(p[:toCopy])
		}
		if w.buffer.Len() >= w.limit {
			w.over = true
		}
	}
	return w.ResponseWriter.Write(p)
}

func (w *captureWriter) Bytes() []byte {
	return w.buffer.Bytes()
}

func (w *captureWriter) Flush() {
	if flusher, ok := w.ResponseWriter.(http.Flusher); ok {
		flusher.Flush()
	}
}

func (w *captureWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	hj, ok := w.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, errors.New("response writer does not support hijacking")
	}
	return hj.Hijack()
}

func (w *captureWriter) Push(target string, opts *http.PushOptions) error {
	pusher, ok := w.ResponseWriter.(http.Pusher)
	if !ok {
		return http.ErrNotSupported
	}
	return pusher.Push(target, opts)
}

// Ollama endpoints

func (s *Server) handleOllamaModels(w http.ResponseWriter, r *http.Request) {
	models, err := s.ollamaClient.ListModels(r.Context())
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{
			"error": "Ollama unavailable: " + err.Error(),
		})
		return
	}

	type modelEntry struct {
		Name  string `json:"name"`
		Alias string `json:"alias"`
		Size  int64  `json:"size_bytes"`
	}

	entries := make([]modelEntry, len(models))
	for i, m := range models {
		entries[i] = modelEntry{
			Name:  m.Name,
			Alias: "local-" + m.Name,
			Size:  m.Size,
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"models": entries,
		"count":  len(entries),
	})
}

func (s *Server) handleOllamaStatus(w http.ResponseWriter, _ *http.Request) {
	available := s.ollamaClient.IsAvailable(context.Background())
	writeJSON(w, http.StatusOK, map[string]any{
		"available":  available,
		"ollama_url": s.cfg.OllamaURL,
	})
}
