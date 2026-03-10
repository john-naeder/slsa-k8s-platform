package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/segmentio/kafka-go"
)

// Event mirrors the demo-api Event struct
type Event struct {
	ID        string    `json:"id"`
	Type      string    `json:"type"`
	Payload   string    `json:"payload"`
	CreatedAt time.Time `json:"created_at"`
}

var (
// Metrics
messagesConsumed atomic.Int64
lastMessage      atomic.Value // stores *Event
ready            atomic.Bool
)

func main() {
	port := env("PORT", "8081")
	brokers := env("KAFKA_BROKERS", "demo-kafka-kafka-bootstrap.kafka.svc.cluster.local:9092")
	topic := env("KAFKA_TOPIC", "demo-events")
	groupID := env("KAFKA_GROUP_ID", "demo-worker")

	log.Printf("demo-worker starting — brokers=%s topic=%s group=%s", brokers, topic, groupID)

	// ── Health server ────────────────────────────────────
	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/readyz", readyzHandler)
	mux.HandleFunc("/metrics", metricsHandler)

	srv := &http.Server{Addr: ":" + port, Handler: mux}
	go func() {
		log.Printf("health server listening on :%s", port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("health server: %v", err)
		}
	}()

	// ── Kafka consumer ───────────────────────────────────
	reader := kafka.NewReader(kafka.ReaderConfig{
Brokers:        []string{brokers},
Topic:          topic,
GroupID:        groupID,
MinBytes:       1e3,  // 1 KB
MaxBytes:       10e6, // 10 MB
MaxWait:        3 * time.Second,
CommitInterval: time.Second,
StartOffset:    kafka.FirstOffset,
})
	defer reader.Close()

	// Graceful shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var wg sync.WaitGroup
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)

	// Mark as ready — Kafka reader is configured
	ready.Store(true)

	// ── Consume loop ─────────────────────────────────────
	wg.Add(1)
	go func() {
		defer wg.Done()
		for {
			msg, err := reader.ReadMessage(ctx)
			if err != nil {
				if ctx.Err() != nil {
					log.Println("consumer: context cancelled, shutting down")
					return
				}
				log.Printf("consumer error: %v", err)
				time.Sleep(time.Second)
				continue
			}

			messagesConsumed.Add(1)

			var evt Event
			if err := json.Unmarshal(msg.Value, &evt); err != nil {
				log.Printf("consumer: invalid JSON in message (partition=%d offset=%d): %v",
msg.Partition, msg.Offset, err)
				continue
			}

			lastMessage.Store(&evt)
			log.Printf("consumed event: id=%s type=%s partition=%d offset=%d",
evt.ID, evt.Type, msg.Partition, msg.Offset)
		}
	}()

	// ── Wait for signal ──────────────────────────────────
	sig := <-sigCh
	log.Printf("received signal %v, shutting down gracefully...", sig)
	cancel()

	// Shutdown health server
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	srv.Shutdown(shutdownCtx)

	wg.Wait()
	log.Printf("demo-worker stopped. Total messages consumed: %d", messagesConsumed.Load())
}

func healthHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
"status":            "ok",
"service":           "demo-worker",
"version":           env("APP_VERSION", "dev"),
"messages_consumed": messagesConsumed.Load(),
	})
}

func readyzHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if !ready.Load() {
		w.WriteHeader(http.StatusServiceUnavailable)
		json.NewEncoder(w).Encode(map[string]string{"ready": "false"})
		return
	}
	json.NewEncoder(w).Encode(map[string]string{"ready": "true"})
}

func metricsHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")

	var last interface{} = nil
	if v := lastMessage.Load(); v != nil {
		last = v
	}

	json.NewEncoder(w).Encode(map[string]interface{}{
"messages_consumed": messagesConsumed.Load(),
		"last_message":      last,
	})
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func init() {
	// Ensure version is logged at startup
	log.SetFlags(log.Ldate | log.Ltime | log.Lmsgprefix)
	log.SetPrefix(fmt.Sprintf("[demo-worker/%s] ", env("APP_VERSION", "dev")))
}
