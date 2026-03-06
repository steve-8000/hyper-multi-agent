package main

import (
	"flag"
	"log"
	"os"

	"github.com/anthropics/hyper-ai-proxy/internal/mcp"
)

func main() {
	proxyURL := flag.String("proxy-url", "http://127.0.0.1:8317", "hyper proxy URL")
	ollamaURL := flag.String("ollama-url", "http://localhost:11434", "Ollama server URL (only used in local mode)")
	apiKey := flag.String("api-key", "", "API key for authenticating with remote proxy")
	flag.Parse()

	log.SetOutput(os.Stderr)
	log.SetFlags(log.LstdFlags)

	server := mcp.NewServer(*proxyURL, *ollamaURL, *apiKey)
	if err := server.Run(); err != nil {
		log.Fatalf("[MCP] Server error: %v", err)
	}
}
