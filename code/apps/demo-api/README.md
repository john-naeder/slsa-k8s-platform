# demo-api

HTTP API microservice — Kafka producer trong hệ thống demo.

## Mô tả

- RESTful API nhận request từ client
- Publish message lên Kafka topic
- Được build + sign qua Tekton SLSA L3 pipeline

## Tech Stack (dự kiến)

- **Language**: Go hoặc Python (FastAPI)
- **Messaging**: Kafka (via Strimzi)
- **Container**: Kaniko build, Cosign signed
- **Registry**: Harbor (self-hosted) hoặc GHCR

## API Endpoints (dự kiến)

| Method | Path | Mô tả |
|--------|------|--------|
| `GET` | `/health` | Health check |
| `POST` | `/api/v1/events` | Tạo event → publish lên Kafka |
| `GET` | `/api/v1/events` | Lấy danh sách events |

## Cấu trúc dự kiến

```
demo-api/
├── README.md
├── Dockerfile
├── main.go (hoặc main.py)
├── go.mod / requirements.txt
├── internal/
│   ├── handler/
│   ├── kafka/
│   └── model/
└── k8s/
    ├── deployment.yaml
    ├── service.yaml
    └── ingress.yaml
```

## Environment Variables

| Variable | Mô tả | Default |
|----------|--------|---------|
| `PORT` | HTTP server port | `8080` |
| `KAFKA_BROKERS` | Kafka broker addresses | `kafka-cluster-kafka-bootstrap:9092` |
| `KAFKA_TOPIC` | Topic name | `demo-events` |

## Build & Deploy

```bash
# Local dev
go run main.go  # hoặc uvicorn main:app

# Tekton pipeline sẽ tự động:
# 1. Build image với Kaniko
# 2. Sign với Cosign (keyless)
# 3. Push lên Harbor
# 4. Argo CD sync deployment
```
