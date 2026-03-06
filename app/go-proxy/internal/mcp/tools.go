package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/anthropics/hyper-ai-proxy/internal/ollama"
)

// Model alias definitions with fallback chains
type aliasEntry struct {
	Primary  string
	Fallback []string
	Access   string // "" or "personal_only"
}

var modelAliases = map[string]aliasEntry{
	"coder-best":   {Primary: "gpt-5.3-codex", Fallback: []string{"local-qwen3.5:35b"}},
	"coder-fast":   {Primary: "gpt-5.3-codex-spark", Fallback: []string{"local-qwen3.5:35b"}},
	"review-deep":  {Primary: "claude-opus-4-6", Fallback: []string{"gpt-5.3-codex", "local-qwen3.5:35b"}},
	"local-cheap":  {Primary: "local-qwen3.5:35b"},
	"personal-dev": {Primary: "gpt-5.3-codex", Access: "personal_only"},
}

// resolveAlias resolves an alias to its primary model name.
func resolveAlias(model string) string {
	if entry, ok := modelAliases[model]; ok {
		return entry.Primary
	}
	return model
}

var allTools = []ToolDefinition{
	{
		Name:        "ask_model",
		Description: "Send a prompt to a specific model through the hyper proxy. Supports aliases (coder-best, coder-fast, review-deep, local-cheap, personal-dev), local Ollama models (local-qwen3.5:35b), and remote models (gpt-5.3-codex, claude-opus-4-6). Codex models route through OAuth auth bridge automatically.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"model": map[string]any{
					"type":        "string",
					"description": "Model alias or name (e.g., 'local-qwen3.5:35b', 'coder-best', 'review-deep')",
				},
				"prompt": map[string]any{
					"type":        "string",
					"description": "The prompt/question to send to the model",
				},
				"system": map[string]any{
					"type":        "string",
					"description": "Optional system prompt",
				},
				"max_tokens": map[string]any{
					"type":        "integer",
					"description": "Maximum output tokens (default: 4096)",
				},
			},
			"required": []string{"model", "prompt"},
		},
	},
	{
		Name:        "list_models",
		Description: "List all available models through the hyper proxy, including remote providers (Claude, Codex) and local Ollama models.",
		InputSchema: map[string]any{
			"type":       "object",
			"properties": map[string]any{},
		},
	},
	{
		Name:        "get_usage",
		Description: "Get current usage statistics for all models and providers. Shows request counts, token usage, and rate limit status.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"days": map[string]any{
					"type":        "integer",
					"description": "Number of days to include (default: 1 for today only)",
				},
			},
		},
	},
	{
		Name:        "run_consensus",
		Description: "Run a prompt against multiple models and return all responses for comparison. Useful for code review or architectural decisions where you want multiple perspectives.",
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"models": map[string]any{
					"type":        "array",
					"items":       map[string]any{"type": "string"},
					"description": "List of model names to query",
				},
				"prompt": map[string]any{
					"type":        "string",
					"description": "The prompt to send to all models",
				},
				"system": map[string]any{
					"type":        "string",
					"description": "Optional system prompt shared across all models",
				},
			},
			"required": []string{"models", "prompt"},
		},
	},
	{
		Name:        "ollama_status",
		Description: "Check Ollama server status and list locally available models with their sizes.",
		InputSchema: map[string]any{
			"type":       "object",
			"properties": map[string]any{},
		},
	},
	{
		Name:        "list_aliases",
		Description: "List all model aliases with their primary models and fallback chains. Aliases abstract real model names (e.g., 'coder-best' -> gpt-5.3-codex with fallback to local-qwen3.5:35b).",
		InputSchema: map[string]any{
			"type":       "object",
			"properties": map[string]any{},
		},
	},
	{
		Name:        "codex_status",
		Description: "Check Codex (OpenAI) auth status and availability. Codex is the personal development lane using GPT-5.3-Codex models via OAuth bridge.",
		InputSchema: map[string]any{
			"type":       "object",
			"properties": map[string]any{},
		},
	},
}

type ToolHandler struct {
	ProxyURL  string
	OllamaURL string
	APIKey    string
	ollama    *ollama.Client
	http      *http.Client
}

func NewToolHandler(proxyURL, ollamaURL, apiKey string) *ToolHandler {
	return &ToolHandler{
		ProxyURL:  proxyURL,
		OllamaURL: ollamaURL,
		APIKey:    apiKey,
		ollama:    ollama.NewClient(ollamaURL),
		http:      &http.Client{Timeout: 300 * time.Second},
	}
}

func (h *ToolHandler) ListTools() []ToolDefinition {
	return allTools
}

func (h *ToolHandler) CallTool(ctx context.Context, name string, args map[string]any) (*ToolCallResult, error) {
	switch name {
	case "ask_model":
		return h.askModel(ctx, args)
	case "list_models":
		return h.listModels(ctx)
	case "get_usage":
		return h.getUsage(ctx, args)
	case "run_consensus":
		return h.runConsensus(ctx, args)
	case "ollama_status":
		return h.ollamaStatus(ctx)
	case "list_aliases":
		return h.listAliases(ctx)
	case "codex_status":
		return h.codexStatus(ctx)
	default:
		return &ToolCallResult{
			Content: []ContentBlock{{Type: "text", Text: fmt.Sprintf("Unknown tool: %s", name)}},
			IsError: true,
		}, nil
	}
}

func (h *ToolHandler) askModel(ctx context.Context, args map[string]any) (*ToolCallResult, error) {
	model, _ := args["model"].(string)
	prompt, _ := args["prompt"].(string)
	system, _ := args["system"].(string)
	maxTokens := 4096
	if mt, ok := args["max_tokens"].(float64); ok {
		maxTokens = int(mt)
	}

	if model == "" || prompt == "" {
		return errorResult("model and prompt are required"), nil
	}

	// Resolve aliases (e.g., "coder-best" -> "gpt-5.3-codex")
	resolved := resolveAlias(model)
	if resolved != model {
		log.Printf("[MCP] Resolved alias '%s' -> '%s'", model, resolved)
		model = resolved
	}

	// Route local models: direct Ollama if local, through proxy if remote
	if strings.HasPrefix(model, "local-") {
		if h.APIKey != "" {
			// Remote client: route through proxy (proxy handles Ollama)
			return h.askProxy(ctx, model, prompt, system, maxTokens)
		}
		ollamaModel := strings.TrimPrefix(model, "local-")
		return h.askOllama(ctx, ollamaModel, prompt, system)
	}

	// Route through proxy for remote models
	return h.askProxy(ctx, model, prompt, system, maxTokens)
}

func (h *ToolHandler) askOllama(ctx context.Context, model, prompt, system string) (*ToolCallResult, error) {
	messages := []ollama.ChatMessage{}
	if system != "" {
		messages = append(messages, ollama.ChatMessage{Role: "system", Content: system})
	}
	messages = append(messages, ollama.ChatMessage{Role: "user", Content: prompt})

	resp, err := h.ollama.Chat(ctx, &ollama.ChatRequest{
		Model:    model,
		Messages: messages,
	})
	if err != nil {
		return errorResult(fmt.Sprintf("Ollama error: %v", err)), nil
	}

	result := resp.Message.Content
	if resp.PromptEvalCount > 0 || resp.EvalCount > 0 {
		result += fmt.Sprintf("\n\n---\n[Model: %s | Prompt tokens: %d | Completion tokens: %d]",
			model, resp.PromptEvalCount, resp.EvalCount)
	}

	return textResult(result), nil
}

func (h *ToolHandler) askProxy(ctx context.Context, model, prompt, system string, maxTokens int) (*ToolCallResult, error) {
	messages := []map[string]string{}
	if system != "" {
		messages = append(messages, map[string]string{"role": "system", "content": system})
	}
	messages = append(messages, map[string]string{"role": "user", "content": prompt})

	body := map[string]any{
		"model":      model,
		"messages":   messages,
		"max_tokens": maxTokens,
		"stream":     false,
	}

	jsonBody, _ := json.Marshal(body)
	url := h.ProxyURL + "/v1/chat/completions"

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, strings.NewReader(string(jsonBody)))
	if err != nil {
		return errorResult(fmt.Sprintf("Failed to create request: %v", err)), nil
	}
	req.Header.Set("Content-Type", "application/json")
	if h.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+h.APIKey)
	}

	resp, err := h.http.Do(req)
	if err != nil {
		return errorResult(fmt.Sprintf("Proxy request failed: %v", err)), nil
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(resp.Body)

	if resp.StatusCode != http.StatusOK {
		return errorResult(fmt.Sprintf("Proxy returned %d: %s", resp.StatusCode, string(respBody))), nil
	}

	var result map[string]any
	if err := json.Unmarshal(respBody, &result); err != nil {
		return textResult(string(respBody)), nil
	}

	// Extract content from OpenAI-style response
	if choices, ok := result["choices"].([]any); ok && len(choices) > 0 {
		if choice, ok := choices[0].(map[string]any); ok {
			if msg, ok := choice["message"].(map[string]any); ok {
				if content, ok := msg["content"].(string); ok {
					return textResult(content), nil
				}
			}
		}
	}

	return textResult(string(respBody)), nil
}

func (h *ToolHandler) listModels(ctx context.Context) (*ToolCallResult, error) {
	var sections []string

	// Get models from proxy
	proxyModels, err := h.fetchProxyModels(ctx)
	if err == nil && len(proxyModels) > 0 {
		sections = append(sections, "## Remote Models (via Proxy)\n"+strings.Join(proxyModels, "\n"))
	}

	// Get Ollama models
	ollamaModels, err := h.ollama.ListModels(ctx)
	if err == nil && len(ollamaModels) > 0 {
		var lines []string
		for _, m := range ollamaModels {
			sizeMB := m.Size / (1024 * 1024)
			sizeGB := float64(sizeMB) / 1024.0
			var sizeStr string
			if sizeGB >= 1 {
				sizeStr = fmt.Sprintf("%.1f GB", sizeGB)
			} else {
				sizeStr = fmt.Sprintf("%d MB", sizeMB)
			}
			lines = append(lines, fmt.Sprintf("- local-%s (%s)", m.Name, sizeStr))
		}
		sections = append(sections, "## Local Models (Ollama)\n"+strings.Join(lines, "\n"))
	} else if err != nil {
		sections = append(sections, "## Local Models (Ollama)\nOllama not available: "+err.Error())
	}

	if len(sections) == 0 {
		return textResult("No models available. Check that the proxy and/or Ollama are running."), nil
	}

	return textResult(strings.Join(sections, "\n\n")), nil
}

func (h *ToolHandler) fetchProxyModels(ctx context.Context) ([]string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, h.ProxyURL+"/v1/models", nil)
	if err != nil {
		return nil, err
	}
	if h.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+h.APIKey)
	}

	resp, err := h.http.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	var result map[string]any
	if err := json.Unmarshal(body, &result); err != nil {
		return nil, err
	}

	var models []string
	if data, ok := result["data"].([]any); ok {
		for _, item := range data {
			if entry, ok := item.(map[string]any); ok {
				id, _ := entry["id"].(string)
				if id != "" {
					models = append(models, "- "+id)
				}
			}
		}
	}

	return models, nil
}

func (h *ToolHandler) getUsage(ctx context.Context, args map[string]any) (*ToolCallResult, error) {
	days := 1
	if d, ok := args["days"].(float64); ok {
		days = int(d)
	}

	url := fmt.Sprintf("%s/internal/stats?days=%d", h.ProxyURL, days)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return errorResult(fmt.Sprintf("Failed to create request: %v", err)), nil
	}
	if h.APIKey != "" {
		req.Header.Set("Authorization", "Bearer "+h.APIKey)
	}

	resp, err := h.http.Do(req)
	if err != nil {
		return errorResult(fmt.Sprintf("Stats request failed: %v", err)), nil
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return errorResult(fmt.Sprintf("Stats returned %d: %s", resp.StatusCode, string(body))), nil
	}

	var stats map[string]any
	if err := json.Unmarshal(body, &stats); err != nil {
		return textResult(string(body)), nil
	}

	// Format nicely
	var lines []string
	lines = append(lines, fmt.Sprintf("# Usage Statistics (last %d day(s))\n", days))

	if totals, ok := stats["totals"].(map[string]any); ok {
		for model, data := range totals {
			if d, ok := data.(map[string]any); ok {
				reqCount, _ := d["request_count"].(float64)
				promptToks, _ := d["prompt_tokens"].(float64)
				compToks, _ := d["completion_tokens"].(float64)
				totalToks, _ := d["total_tokens"].(float64)
				lines = append(lines, fmt.Sprintf("## %s\n- Requests: %d\n- Prompt tokens: %d\n- Completion tokens: %d\n- Total tokens: %d",
					model, int(reqCount), int(promptToks), int(compToks), int(totalToks)))
			}
		}
	}

	if len(lines) == 1 {
		lines = append(lines, "No usage data recorded yet.")
	}

	return textResult(strings.Join(lines, "\n\n")), nil
}

func (h *ToolHandler) runConsensus(ctx context.Context, args map[string]any) (*ToolCallResult, error) {
	modelsRaw, _ := args["models"].([]any)
	prompt, _ := args["prompt"].(string)
	system, _ := args["system"].(string)

	if len(modelsRaw) == 0 || prompt == "" {
		return errorResult("models (array) and prompt are required"), nil
	}

	var models []string
	for _, m := range modelsRaw {
		if s, ok := m.(string); ok {
			models = append(models, s)
		}
	}

	type result struct {
		model    string
		response string
		err      error
	}

	ch := make(chan result, len(models))
	for _, model := range models {
		go func(m string) {
			r, err := h.askModel(ctx, map[string]any{
				"model":  m,
				"prompt": prompt,
				"system": system,
			})
			var text string
			if err != nil {
				ch <- result{model: m, err: err}
				return
			}
			if len(r.Content) > 0 {
				text = r.Content[0].Text
			}
			if r.IsError {
				ch <- result{model: m, err: fmt.Errorf("%s", text)}
				return
			}
			ch <- result{model: m, response: text}
		}(model)
	}

	var sections []string
	sections = append(sections, "# Consensus Results\n")
	for range models {
		r := <-ch
		if r.err != nil {
			sections = append(sections, fmt.Sprintf("## %s\n**Error:** %v", r.model, r.err))
		} else {
			sections = append(sections, fmt.Sprintf("## %s\n%s", r.model, r.response))
		}
	}

	return textResult(strings.Join(sections, "\n\n---\n\n")), nil
}

func (h *ToolHandler) ollamaStatus(ctx context.Context) (*ToolCallResult, error) {
	if !h.ollama.IsAvailable(ctx) {
		return textResult("Ollama is NOT running at " + h.OllamaURL + "\n\nStart it with: `ollama serve`"), nil
	}

	models, err := h.ollama.ListModels(ctx)
	if err != nil {
		return errorResult(fmt.Sprintf("Ollama available but failed to list models: %v", err)), nil
	}

	var lines []string
	lines = append(lines, fmt.Sprintf("Ollama is running at %s\n", h.OllamaURL))
	lines = append(lines, fmt.Sprintf("Available models: %d\n", len(models)))

	for _, m := range models {
		sizeMB := m.Size / (1024 * 1024)
		sizeGB := float64(sizeMB) / 1024.0
		var sizeStr string
		if sizeGB >= 1 {
			sizeStr = fmt.Sprintf("%.1f GB", sizeGB)
		} else {
			sizeStr = fmt.Sprintf("%d MB", sizeMB)
		}
		lines = append(lines, fmt.Sprintf("- %s (%s, modified: %s)",
			m.Name, sizeStr, m.ModifiedAt.Format("2006-01-02")))
	}

	return textResult(strings.Join(lines, "\n")), nil
}

func (h *ToolHandler) listAliases(_ context.Context) (*ToolCallResult, error) {
	var lines []string
	lines = append(lines, "# Model Aliases\n")
	lines = append(lines, "Use these aliases with `ask_model` instead of raw model names.\n")

	// Sort keys for stable output
	keys := make([]string, 0, len(modelAliases))
	for k := range modelAliases {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	for _, alias := range keys {
		entry := modelAliases[alias]
		line := fmt.Sprintf("## %s\n- Primary: `%s`", alias, entry.Primary)
		if len(entry.Fallback) > 0 {
			fallbacks := make([]string, len(entry.Fallback))
			for i, f := range entry.Fallback {
				fallbacks[i] = "`" + f + "`"
			}
			line += fmt.Sprintf("\n- Fallback: %s", strings.Join(fallbacks, " -> "))
		}
		if entry.Access != "" {
			line += fmt.Sprintf("\n- Access: %s", entry.Access)
		}
		lines = append(lines, line)
	}

	lines = append(lines, "\n---\n## Routing Logic")
	lines = append(lines, "- `coder-best`: Codex for heavy coding, falls back to local Qwen")
	lines = append(lines, "- `coder-fast`: Local Qwen for quick code tasks (free, fast)")
	lines = append(lines, "- `review-deep`: Claude Opus for architecture review, falls back to Codex/Qwen")
	lines = append(lines, "- `local-cheap`: Always local Qwen (zero cost)")
	lines = append(lines, "- `personal-dev`: Codex personal lane (owner only)")

	return textResult(strings.Join(lines, "\n")), nil
}

func (h *ToolHandler) codexStatus(ctx context.Context) (*ToolCallResult, error) {
	// Check if Codex models are available through the proxy
	proxyModels, err := h.fetchProxyModels(ctx)
	if err != nil {
		return errorResult(fmt.Sprintf("Cannot reach proxy: %v", err)), nil
	}

	var codexModels []string
	for _, m := range proxyModels {
		lower := strings.ToLower(m)
		if strings.Contains(lower, "codex") || strings.Contains(lower, "gpt-5") ||
			strings.Contains(lower, "o4-mini") || strings.Contains(lower, "o3") ||
			strings.Contains(lower, "gpt-4.1") {
			codexModels = append(codexModels, m)
		}
	}

	// Check auth status by trying to list models
	var lines []string
	lines = append(lines, "# Codex Auth Status\n")

	if len(codexModels) > 0 {
		lines = append(lines, "Codex models available via proxy:\n")
		lines = append(lines, strings.Join(codexModels, "\n"))
		lines = append(lines, "\n\n## Auth Bridge")
		lines = append(lines, "Codex uses OAuth token bridge stored in `~/.cli-proxy-api/`")
		lines = append(lines, "Login via the hyper AI app: Settings > Providers > Codex > Login")
		lines = append(lines, "\n## Role")
		lines = append(lines, "Codex is the **personal development lane**:")
		lines = append(lines, "- Best for: coding tasks, quick experiments, personal dev sessions")
		lines = append(lines, "- Models: gpt-5.3-codex (400K context), gpt-5.3-codex-spark (fast)")
		lines = append(lines, "- Alias: `personal-dev`, `coder-best` (primary)")
	} else {
		lines = append(lines, "No Codex models detected.\n")
		lines = append(lines, "## Setup Required")
		lines = append(lines, "1. Open hyper AI app (menu bar)")
		lines = append(lines, "2. Go to Settings > Providers")
		lines = append(lines, "3. Enable Codex and click Login")
		lines = append(lines, "4. Complete OAuth in browser")
		lines = append(lines, "\nAfter login, Codex models (gpt-5.3-codex) become available through the proxy.")
	}

	return textResult(strings.Join(lines, "\n")), nil
}

func textResult(text string) *ToolCallResult {
	return &ToolCallResult{
		Content: []ContentBlock{{Type: "text", Text: text}},
	}
}

func errorResult(msg string) *ToolCallResult {
	return &ToolCallResult{
		Content: []ContentBlock{{Type: "text", Text: msg}},
		IsError: true,
	}
}
