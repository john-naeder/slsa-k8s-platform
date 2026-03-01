package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"
	"time"
)

// Event represents a demo event
type Event struct {
	ID        string    `json:"id"`
	Type      string    `json:"type"`
	Payload   string    `json:"payload"`
	CreatedAt time.Time `json:"created_at"`
}

var (
	events []Event
	mu     sync.RWMutex
	idSeq  int
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/readyz", readyzHandler)
	mux.HandleFunc("/api/v1/events", eventsHandler)

	log.Printf("demo-api starting on :%s", port)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"status":  "ok",
		"service": "demo-api",
		"version": version(),
	})
}

func readyzHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"ready": "true",
	})
}

func eventsHandler(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		listEvents(w, r)
	case http.MethodPost:
		createEvent(w, r)
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func listEvents(w http.ResponseWriter, _ *http.Request) {
	mu.RLock()
	defer mu.RUnlock()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(events)
}

func createEvent(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Type    string `json:"type"`
		Payload string `json:"payload"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid json", http.StatusBadRequest)
		return
	}

	mu.Lock()
	idSeq++
	evt := Event{
		ID:        fmt.Sprintf("evt-%04d", idSeq),
		Type:      req.Type,
		Payload:   req.Payload,
		CreatedAt: time.Now(),
	}
	events = append(events, evt)
	mu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	json.NewEncoder(w).Encode(evt)
}

func version() string {
	v := os.Getenv("APP_VERSION")
	if v == "" {
		return "dev"
	}
	return v
}
