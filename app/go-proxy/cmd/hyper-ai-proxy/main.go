package main

import (
	"context"
	"errors"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/anthropics/hyper-ai-proxy/internal/config"
	"github.com/anthropics/hyper-ai-proxy/internal/proxy"
)

const shutdownTimeout = 10 * time.Second

func main() {
	log.SetFlags(log.LstdFlags)

	cfg := config.Parse()
	cfg.LogStartup()

	srv := &http.Server{
		Addr:    cfg.Addr(),
		Handler: proxy.NewServer(cfg).Handler(),
	}

	errCh := make(chan error, 1)
	go func() {
		log.Printf("[HyperProxy] Server starting on %s", cfg.Addr())
		if err := srv.ListenAndServe(); err != nil {
			errCh <- err
		}
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	select {
	case sig := <-sigCh:
		log.Printf("[HyperProxy] Received signal: %s", sig.String())
	case err := <-errCh:
		if !errors.Is(err, http.ErrServerClosed) {
			log.Fatalf("[HyperProxy] Server failed: %v", err)
		}
		log.Printf("[HyperProxy] Server stopped")
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
	defer cancel()

	log.Printf("[HyperProxy] Graceful shutdown started")
	if err := srv.Shutdown(ctx); err != nil {
		log.Printf("[HyperProxy] Graceful shutdown failed: %v", err)
		if closeErr := srv.Close(); closeErr != nil {
			log.Printf("[HyperProxy] Forced close failed: %v", closeErr)
		}
	} else {
		log.Printf("[HyperProxy] Graceful shutdown completed")
	}
}
