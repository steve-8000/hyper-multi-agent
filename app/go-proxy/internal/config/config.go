package config

import (
	"flag"
	"fmt"
	"log"
)

type Config struct {
	Bind           string
	Port           int
	TargetHost     string
	TargetPort     int
	ExternalAccess bool
	APIKey         string
	VercelEnabled  bool
	VercelAPIKey   string
	TokenSpecsFile string
	OllamaURL      string
	OllamaEnabled  bool
}

func Parse() Config {
	cfg := Config{}
	flag.StringVar(&cfg.Bind, "bind", "127.0.0.1", "bind host")
	flag.IntVar(&cfg.Port, "port", 8317, "proxy listen port")
	flag.IntVar(&cfg.TargetPort, "target-port", 8318, "upstream target port")
	flag.StringVar(&cfg.TargetHost, "target-host", "127.0.0.1", "upstream target host")
	flag.BoolVar(&cfg.ExternalAccess, "external-access", false, "allow non-local access")
	flag.StringVar(&cfg.APIKey, "api-key", "", "api key for external access")
	flag.BoolVar(&cfg.VercelEnabled, "vercel-enabled", false, "enable Vercel AI Gateway for Claude requests")
	flag.StringVar(&cfg.VercelAPIKey, "vercel-api-key", "", "Vercel AI Gateway API key")
	flag.StringVar(&cfg.TokenSpecsFile, "token-specs-file", "", "path to JSON file with dynamic model token specs")
	flag.StringVar(&cfg.OllamaURL, "ollama-url", "http://localhost:11434", "Ollama server URL for direct local model routing")
	flag.BoolVar(&cfg.OllamaEnabled, "ollama-enabled", false, "enable direct Ollama routing for local-* models")
	flag.Parse()

	if cfg.ExternalAccess {
		cfg.Bind = "0.0.0.0"
	}

	return cfg
}

func (c Config) Addr() string {
	return fmt.Sprintf("%s:%d", c.Bind, c.Port)
}

func (c Config) LogStartup() {
	log.Printf("[HyperProxy] Startup config: bind=%s port=%d target=%s:%d external_access=%t api_key_set=%t vercel_enabled=%t vercel_api_key_set=%t token_specs_file=%s ollama_enabled=%t ollama_url=%s",
		c.Bind,
		c.Port,
		c.TargetHost,
		c.TargetPort,
		c.ExternalAccess,
		c.APIKey != "",
		c.VercelEnabled,
		c.VercelAPIKey != "",
		c.TokenSpecsFile,
		c.OllamaEnabled,
		c.OllamaURL,
	)
}
