# 12 — Kafka Event Streaming (Strimzi)

> Apache Kafka deployed via Strimzi operator trong KRaft mode (không ZooKeeper).
> Event backbone cho demo microservices.

## Kiến trúc

```
┌───────────────┐     Kafka (Strimzi KRaft)      ┌───────────────┐
│   demo-api    │                                 │  demo-worker  │
│  (HTTP API)   │──produce──▶ ┌──────────────┐ ──consume──▶│ (Consumer)    │
│  POST /events │            │ demo-events  │            │  Process msg  │
└───────────────┘            │  (3 partitions)│            └───────────────┘
                             └──────────────┘
                             demo-kafka-kafka-bootstrap:9092
```

## Components

| Component | Version | Vai trò |
|-----------|---------|---------|
| Strimzi Operator | v0.44.0 | Kafka lifecycle management |
| Apache Kafka | v3.8.1 | Message broker |
| KRaft (metadata) | v3.8 | Replace ZooKeeper |
| Entity Operator | — | Topic + User management |

## 12.1 — Strimzi Operator (ArgoCD)

Strimzi Operator quản lý Kafka CRDs (Kafka, KafkaNodePool, KafkaTopic, KafkaUser...).

```yaml
# code/infra/argocd/apps/strimzi.yaml
spec:
  source:
    chart: strimzi-kafka-operator
    repoURL: https://strimzi.io/charts/
    targetRevision: "0.44.0"
    helm:
      valuesObject:
        resources:
          requests: { cpu: 50m, memory: 128Mi }
          limits: { memory: 384Mi }
  syncPolicy:
    syncOptions:
      - ServerSideApply=true    # Strimzi CRDs rất lớn
```

## 12.2 — Kafka Cluster (ArgoCD)

Kafka cluster được deploy qua ArgoCD, đọc manifests từ Git:

```yaml
# code/infra/argocd/apps/kafka-cluster.yaml
spec:
  source:
    repoURL: git@github.com:john-naeder/slsa-k8s-platform.git
    path: code/infra/k8s/manifests/kafka    # kafka-cluster.yaml + kafka-topic.yaml
```

### Kafka Cluster manifest

```
code/infra/k8s/manifests/kafka/
├── kafka-cluster.yaml    # KafkaNodePool + Kafka CR
└── kafka-topic.yaml      # KafkaTopic: demo-events
```

### KafkaNodePool (combined node)

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: combined
  namespace: kafka
spec:
  replicas: 1
  roles:
    - controller       # KRaft metadata
    - broker           # Message handling
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 5Gi
        deleteClaim: false
  resources:
    requests: { cpu: 100m, memory: 512Mi }
    limits: { memory: 1Gi }
```

> **combined** node: vừa controller vừa broker (tiết kiệm resources cho bare-metal 2 node).

### Kafka CR (KRaft mode)

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: demo-kafka
  namespace: kafka
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled       # KRaft — KHÔNG dùng ZooKeeper
spec:
  kafka:
    version: 3.8.1
    metadataVersion: "3.8"
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
    config:
      offsets.topic.replication.factor: 1
      transaction.state.log.replication.factor: 1
      default.replication.factor: 1
      min.insync.replicas: 1
      log.retention.hours: 168          # 7 ngày
  entityOperator:
    topicOperator: { ... }
    userOperator: { ... }
```

### KafkaTopic

```yaml
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: demo-events
  namespace: kafka
  labels:
    strimzi.io/cluster: demo-kafka
spec:
  partitions: 3
  replicas: 1
  config:
    retention.ms: "604800000"     # 7 ngày
    segment.bytes: "1073741824"   # 1 GB
```

## 12.3 — Kết nối từ application

### Kafka Bootstrap Service

Strimzi tự tạo Service:

| Service | Port | Mô tả |
|---------|------|-------|
| `demo-kafka-kafka-bootstrap.kafka.svc.cluster.local` | 9092 | Plain (no TLS) |
| `demo-kafka-kafka-bootstrap.kafka.svc.cluster.local` | 9093 | TLS |

### Trong demo-api (producer)

```go
// Kết nối
brokers := "demo-kafka-kafka-bootstrap.kafka.svc.cluster.local:9092"
writer := kafka.NewWriter(kafka.WriterConfig{
    Brokers: []string{brokers},
    Topic:   "demo-events",
})
```

### Trong demo-worker (consumer)

```go
reader := kafka.NewReader(kafka.ReaderConfig{
    Brokers:  []string{"demo-kafka-kafka-bootstrap.kafka.svc.cluster.local:9092"},
    Topic:    "demo-events",
    GroupID:  "demo-worker",
    MinBytes: 1,
    MaxBytes: 10e6,
})
```

## 12.4 — Monitoring Kafka

Strimzi expose Kafka metrics mà Prometheus có thể scrape:

```bash
# Kafka pods
kubectl get pods -n kafka
# NAME                                    READY   STATUS
# demo-kafka-combined-0                   1/1     Running
# demo-kafka-entity-operator-xxx          2/2     Running

# Topics
kubectl get kafkatopics -n kafka
# NAME          CLUSTER      PARTITIONS   REPLICATION FACTOR
# demo-events   demo-kafka   3            1

# Kafka cluster status
kubectl get kafka -n kafka
# NAME         DESIRED KAFKA REPLICAS   DESIRED ZK REPLICAS   READY   ...
# demo-kafka   1                                              True
```

## Verify

```bash
# Strimzi operator pod
kubectl get pods -n kafka -l strimzi.io/kind=cluster-operator

# Kafka broker pod
kubectl get pods -n kafka -l strimzi.io/cluster=demo-kafka

# Test produce/consume từ trong cluster
kubectl -n kafka run kafka-test --rm -it --image=quay.io/strimzi/kafka:0.44.0-kafka-3.8.1 -- \
  bin/kafka-console-producer.sh \
  --bootstrap-server demo-kafka-kafka-bootstrap:9092 \
  --topic demo-events

# Consume (terminal khác)
kubectl -n kafka run kafka-consumer --rm -it --image=quay.io/strimzi/kafka:0.44.0-kafka-3.8.1 -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server demo-kafka-kafka-bootstrap:9092 \
  --topic demo-events \
  --from-beginning
```

## Files liên quan

| File | Mô tả |
|------|-------|
| `infra/argocd/apps/strimzi.yaml` | ArgoCD Application: Strimzi Operator |
| `infra/argocd/apps/kafka-cluster.yaml` | ArgoCD Application: Kafka Cluster |
| `infra/k8s/manifests/kafka/kafka-cluster.yaml` | KafkaNodePool + Kafka CR |
| `infra/k8s/manifests/kafka/kafka-topic.yaml` | KafkaTopic: demo-events |
