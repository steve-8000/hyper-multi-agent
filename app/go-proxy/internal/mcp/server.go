package mcp

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"sync"
)

const (
	protocolVersion = "2024-11-05"
	serverName      = "hyper-proxy"
	serverVersion   = "2.0.0"
)

type Server struct {
	handler *ToolHandler
	mu      sync.Mutex
}

func NewServer(proxyURL, ollamaURL, apiKey string) *Server {
	return &Server{
		handler: NewToolHandler(proxyURL, ollamaURL, apiKey),
	}
}

func (s *Server) Run() error {
	reader := bufio.NewReader(os.Stdin)
	encoder := json.NewEncoder(os.Stdout)

	log.SetOutput(os.Stderr)
	log.Printf("[MCP] Server starting (proxy=%s, ollama=%s)", s.handler.ProxyURL, s.handler.OllamaURL)

	for {
		line, err := reader.ReadBytes('\n')
		if err != nil {
			if err == io.EOF {
				log.Printf("[MCP] stdin closed, shutting down")
				return nil
			}
			return fmt.Errorf("read error: %w", err)
		}

		var req Request
		if err := json.Unmarshal(line, &req); err != nil {
			log.Printf("[MCP] Failed to parse request: %v", err)
			continue
		}

		resp := s.handleRequest(req)
		if resp == nil {
			continue // notification, no response needed
		}

		s.mu.Lock()
		if err := encoder.Encode(resp); err != nil {
			log.Printf("[MCP] Failed to write response: %v", err)
		}
		s.mu.Unlock()
	}
}

func (s *Server) handleRequest(req Request) *Response {
	switch req.Method {
	case "initialize":
		return s.handleInitialize(req)
	case "initialized":
		return nil // notification
	case "notifications/cancelled":
		return nil
	case "tools/list":
		return s.handleToolsList(req)
	case "tools/call":
		return s.handleToolsCall(req)
	case "ping":
		return &Response{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result:  map[string]any{},
		}
	default:
		log.Printf("[MCP] Unknown method: %s", req.Method)
		return &Response{
			JSONRPC: "2.0",
			ID:      req.ID,
			Error: &RPCError{
				Code:    -32601,
				Message: "Method not found: " + req.Method,
			},
		}
	}
}

func (s *Server) handleInitialize(req Request) *Response {
	log.Printf("[MCP] Initialize request received")

	return &Response{
		JSONRPC: "2.0",
		ID:      req.ID,
		Result: InitializeResult{
			ProtocolVersion: protocolVersion,
			Capabilities: ServerCapability{
				Tools: &ToolsCapability{},
			},
			ServerInfo: ServerInfo{
				Name:    serverName,
				Version: serverVersion,
			},
		},
	}
}

func (s *Server) handleToolsList(req Request) *Response {
	return &Response{
		JSONRPC: "2.0",
		ID:      req.ID,
		Result: ToolsListResult{
			Tools: s.handler.ListTools(),
		},
	}
}

func (s *Server) handleToolsCall(req Request) *Response {
	var params ToolCallParams
	if err := json.Unmarshal(req.Params, &params); err != nil {
		return &Response{
			JSONRPC: "2.0",
			ID:      req.ID,
			Error: &RPCError{
				Code:    -32602,
				Message: "Invalid params: " + err.Error(),
			},
		}
	}

	log.Printf("[MCP] Tool call: %s", params.Name)

	result, err := s.handler.CallTool(context.Background(), params.Name, params.Arguments)
	if err != nil {
		return &Response{
			JSONRPC: "2.0",
			ID:      req.ID,
			Error: &RPCError{
				Code:    -32000,
				Message: err.Error(),
			},
		}
	}

	return &Response{
		JSONRPC: "2.0",
		ID:      req.ID,
		Result:  result,
	}
}
