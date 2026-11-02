package agent

import (
	"context"
	"io"
	"net"
	"net/http"
	"testing"
	"time"
)

func TestServeStandaloneOnHealthAndCleanShutdown(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	a := New("test", "test-token")
	serveDone := make(chan error, 1)
	go func() {
		serveDone <- a.ServeStandaloneOn(ctx, listener, "", "", "/ws")
	}()
	response, err := http.Get("http://" + listener.Addr().String() + "/healthz")
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	body, err := io.ReadAll(response.Body)
	response.Body.Close()
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	if response.StatusCode != http.StatusOK || string(body) != "ok" {
		cancel()
		t.Fatalf("health response = %s %q", response.Status, body)
	}
	cancel()
	select {
	case err := <-serveDone:
		if err != nil {
			t.Fatalf("ServeStandaloneOn returned an error on shutdown: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("ServeStandaloneOn did not stop after context cancellation")
	}
}
