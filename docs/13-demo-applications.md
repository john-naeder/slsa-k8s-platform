# 13 — Demo Applications

> Hai Go microservices demo cho E2E SLSA L3 pipeline.
> Cả hai được build bởi Tekton, sign bởi Chains, deploy bởi ArgoCD, verify bởi Kyverno.

## Kiến trúc

```
Internet                      K8s Cluster (namespace: demo)
   │
   │  HTTPS (Cloudflare Tunnel → Traefik)
   ▼
┌──────────────┐    Kafka     ┌──────────────┐
│  demo-api    │──produce──▶  │  demo-worker  │
│  :8080       │  demo-events │  :8081        │
│              │              │               │
│  POST /api/  │              │  Consumer     │
│  v1/events   │              │  group:       │
│              │              │  demo-worker  │
│  GET /health │              │  GET /health  │
│  GET /readyz │              │  GET /readyz  │
└──────────────┘              │  GET /metrics │
                              └──────────────┘
```

## 13.1 — demo-api (HTTP API)

### Overview

| Setting | Giá trị |
|---------|---------|
| Language | Go 1.23 |
| Port | 8080 |
| Image | `harbor.kythuat.vn/demo/demo-api` |
| Runtime | `gcr.io/distroless/static-debian12:nonroot` |
| Exposed | `https://demo.kythuat.vn` (Cloudflare Tunnel) |

### Source code

```
code/src/demo-api/
├── main.go              # HTTP server: /health, /readyz, /api/v1/events
├── go.mod               # Go module definition
├── Dockerfile           # Multi-stage: Go 1.23 builder → distroless
└── k8s/
    ├── deployment.yaml  # Deployment (image pinned by sha256 digest)
    ├── service.yaml     # ClusterIP service
    └── ingressroute.yaml # Traefik IngressRoute: demo.kythuat.vn
```

### API Endpoints

| Method | Path | Mô tả |
|--------|------|-------|
| GET | `/health` | Health check (status, service, version) |
| GET | `/readyz` | Readiness probe |
| GET | `/api/v1/events` | List all events |
| POST | `/api/v1/events` | Create event `{"type":"...", "payload":"..."}` |

### Dockerfile (multi-stage)

```dockerfile
FROM golang:1.23-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o server .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /app/server /server
EXPOSE 8080
ENTRYPOINT ["/server"]
```

### K8s Deployment

```yaml
# Image pinned by sha256 digest (updated by Tekton promote step)
image: harbor.kythuat.vn/demo/demo-api@sha256:acdabb3b...
env:
  - name: PORT
    value: "8080"
  - name: APP_VERSION
    value: "1.1.0"
livenessProbe:
  httpGet: { path: /health, port: 8080 }
readinessProbe:
  httpGet: { path: /readyz, port: 8080 }
```

> **Quan trọng:** Image dùng `@sha256:` (digest pinning) thay vì tag.
> Tekton `update-manifest` task tự động update digest sau mỗi build.

### ArgoCD Application

```yaml
# code/infra/argocd/apps/demo-api.yaml
spec:
  source:
    repoURL: git@github.com:john-naeder/slsa-k8s-platform.git
    path: code/src/demo-api/k8s
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

## 13.2 — demo-worker (Kafka Consumer)

### Overview

| Setting | Giá trị |
|---------|---------|
| Language | Go 1.23 |
| Port | 8081 (health server) |
| Image | `harbor.kythuat.vn/demo/demo-worker` |
| Runtime | `gcr.io/distroless/static-debian12:nonroot` |
| Kafka dependency | `github.com/segmentio/kafka-go` v0.4.50 |

### Source code

```
code/src/demo-worker/
├── main.go              # Kafka consumer + health server
├── go.mod               # Go module (segmentio/kafka-go)
├── go.sum
├── Dockerfile           # Multi-stage: Go 1.23 builder → distroless
└── k8s/
    ├── deployment.yaml  # Deployment (env vars for Kafka config)
    └── service.yaml     # ClusterIP service
```

### Endpoints

| Method | Path | Mô tả |
|--------|------|-------|
| GET | `/health` | Health check |
| GET | `/readyz` | Readiness (true khi Kafka connected) |
| GET | `/metrics` | Prometheus metrics (messages_consumed, last_message) |

### Kafka Consumer flow

```go
reader := kafka.NewReader(kafka.ReaderConfig{
    Brokers:  []string{brokers},
    Topic:    "demo-events",
    GroupID:  "demo-worker",
    MinBytes: 1,
    MaxBytes: 10e6,
})

// Read loop
for {
    msg, err := reader.ReadMessage(ctx)
    // Parse JSON event
    // Log + update metrics
    // Commit offset (tự động qua GroupID)
}
```

### K8s Deployment

```yaml
image: harbor.kythuat.vn/demo/demo-worker:latest   # TODO: sha256 pin sau build đầu tiên
env:
  - name: KAFKA_BROKERS
    value: "demo-kafka-kafka-bootstrap.kafka.svc.cluster.local:9092"
  - name: KAFKA_TOPIC
    value: "demo-events"
  - name: KAFKA_GROUP_ID
    value: "demo-worker"
livenessProbe:
  httpGet: { path: /health, port: 8081 }
readinessProbe:
  httpGet: { path: /readyz, port: 8081 }
```

### ArgoCD Application

```yaml
# code/infra/argocd/apps/demo-worker.yaml
spec:
  source:
    repoURL: git@github.com:john-naeder/slsa-k8s-platform.git
    path: code/src/demo-worker/k8s
  syncPolicy:
    automated: { prune: true, selfHeal: true }
```

## 13.3 — Build & Deploy Flow

### First build (manual)

```bash
# demo-api
kubectl apply -f code/tekton/runs/demo-api-run.yaml

# demo-worker (tương tự, tạo PipelineRun)
tkn pipeline start build-and-sign \
  -p repo-url=git@github.com:john-naeder/slsa-k8s-platform.git \
  -p image=harbor.kythuat.vn/demo/demo-worker:latest \
  -p context=code/src/demo-worker \
  -w name=shared-workspace,claimName=tekton-workspace \
  -w name=ssh-credentials,secret=git-ssh-credentials \
  -n tekton-pipelines
```

### Subsequent builds (auto via webhook)

1. Push code vào `code/src/demo-api/` → Tekton trigger tự build
2. Chains sign + generate provenance
3. Promote step update digest trong `k8s/deployment.yaml`
4. ArgoCD sync → Kyverno verify → Pod deployed

## 13.4 — E2E Test

```bash
# 1. Kiểm tra pods
kubectl get pods -n demo
# demo-api-xxx       1/1     Running
# demo-worker-xxx    1/1     Running

# 2. Test health
kubectl -n demo exec deploy/demo-api -- wget -qO- http://localhost:8080/health

# 3. Tạo event (qua Traefik/Cloudflare)
curl -X POST https://demo.kythuat.vn/api/v1/events \
  -H "Content-Type: application/json" \
  -d '{"type":"test","payload":"hello from e2e test"}'

# 4. List events
curl https://demo.kythuat.vn/api/v1/events

# 5. Kiểm tra demo-worker consumed message
kubectl -n demo logs deploy/demo-worker | tail -5
# → "Consumed event: id=1 type=test payload=hello from e2e test"

# 6. Kiểm tra worker metrics
kubectl -n demo exec deploy/demo-worker -- wget -qO- http://localhost:8081/metrics
```

## Files liên quan

| File | Mô tả |
|------|-------|
| `src/demo-api/main.go` | HTTP API server |
| `src/demo-api/Dockerfile` | Multi-stage build |
| `src/demo-api/k8s/deployment.yaml` | Deployment (sha256 pinned) |
| `src/demo-api/k8s/service.yaml` | ClusterIP service |
| `src/demo-api/k8s/ingressroute.yaml` | Traefik IngressRoute |
| `src/demo-worker/main.go` | Kafka consumer |
| `src/demo-worker/Dockerfile` | Multi-stage build |
| `src/demo-worker/k8s/deployment.yaml` | Deployment (Kafka env vars) |
| `src/demo-worker/k8s/service.yaml` | ClusterIP service |
| `infra/argocd/apps/demo-api.yaml` | ArgoCD Application |
| `infra/argocd/apps/demo-worker.yaml` | ArgoCD Application |
