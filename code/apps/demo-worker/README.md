# demo-worker

Kafka consumer microservice — xử lý message từ demo-api.

## Mô tả

- Subscribe Kafka topic và consume messages
- Xử lý event (logging, transform, store)
- Minh chứng kiến trúc event-driven microservices

## Tech Stack (dự kiến)

- **Language**: Go hoặc Python
- **Messaging**: Kafka consumer (via Strimzi)
- **Container**: Kaniko build, Cosign signed
- **Registry**: Harbor (self-hosted) hoặc GHCR

## Kafka Consumer Config

| Variable | Mô tả | Default |
|----------|--------|---------|
| `KAFKA_BROKERS` | Kafka broker addresses | `kafka-cluster-kafka-bootstrap:9092` |
| `KAFKA_TOPIC` | Topic to consume | `demo-events` |
| `KAFKA_GROUP_ID` | Consumer group ID | `demo-worker-group` |

## Cấu trúc dự kiến

```
demo-worker/
├── README.md
├── Dockerfile
├── main.go (hoặc main.py)
├── go.mod / requirements.txt
├── internal/
│   ├── consumer/
│   ├── processor/
│   └── model/
└── k8s/
    ├── deployment.yaml
    └── service.yaml
```

## Luồng xử lý

```
Kafka Topic (demo-events)
    → demo-worker consumer
    → Process event (log / transform / store)
    → Metrics update (Prometheus)
```

## Build & Deploy

```bash
# Local dev
go run main.go  # hoặc python main.py

# Tekton pipeline tự động build + sign + deploy (giống demo-api)
```
