# 03 — Platform Bootstrap (Helmfile)

> Cài đặt "minimum viable platform" — những component cần thiết ĐỂ ArgoCD có thể chạy.
> Sau phase này, ArgoCD sẽ quản lý tất cả remaining components qua GitOps.

## Tại sao dùng Helmfile?

**Chicken-and-egg problem:** Ai cài ArgoCD nếu ArgoCD quản lý mọi thứ?

→ Giải pháp: **2-Phase Approach**

```
Phase A: BOOTSTRAP (Helmfile)      Phase B: STEADY-STATE (ArgoCD)
─────────────────────────          ────────────────────────────────
cert-manager                       Harbor (OCI Registry)
Traefik                            Strimzi (Kafka Operator)
Sealed Secrets                     Kafka Cluster
ArgoCD ─────────────────────────→  Kyverno (Policy Engine)
                                   Monitoring (Prometheus + Grafana)
                                   Logging (Loki + Promtail)
                                   Demo Apps (API + Worker)
```

> Chi tiết phương pháp: xem `plan/infra-deployment-methodology.md`

## Yêu cầu

- K8s cluster đang chạy (Phase 02 hoàn tất)
- Helm, Helmfile, helm-diff đã cài trên máy local
- kubeconfig đã trỏ đúng cluster

## Thứ tự cài đặt (Helmfile tự quản lý dependencies)

| # | Component | Namespace | Chart Version | Vai trò |
|---|-----------|-----------|---------------|---------|
| 1 | cert-manager | cert-manager | 1.16.3 | TLS foundation — mọi Ingress cần |
| 2 | Traefik | traefik | 34.3.0 | Ingress Controller — cần cert-manager cho TLS |
| 3 | Sealed Secrets | sealed-secrets | 2.17.1 | Encrypt secrets in Git — cần trước ArgoCD |
| 4 | ArgoCD | argocd | 7.8.7 | GitOps CD — "king" — quản lý phần còn lại |

## Chạy Bootstrap

```bash
cd code/infra/helmfile/

# 0. Gán label cho worker node (Helm values dùng nodeSelector)
kubectl label node userver-home-worker node-role=worker
kubectl label node userver-home-worker workload-type=heavy

# 1. Preview changes (audit trail)
helmfile -f helmfile-bootstrap.yaml diff

# 2. Apply (idempotent — chạy bao nhiêu lần cũng được)
helmfile -f helmfile-bootstrap.yaml apply

# 3. Verify
helmfile -f helmfile-bootstrap.yaml list
```

## Helm Values chi tiết

### cert-manager (`values/cert-manager.yaml`)

```yaml
crds:
  enabled: true          # Install CRDs via Helm
  keep: true             # Giữ CRDs khi uninstall
nodeSelector:
  node-role: worker
resources:               # Constrained bare metal
  requests: { cpu: 50m, memory: 64Mi }
  limits: { memory: 128Mi }
```

### Traefik (`values/traefik.yaml`)

```yaml
service:
  type: ClusterIP        # Không cần LoadBalancer (cloudflared forwards trực tiếp)
ports:
  web: { port: 8000, exposedPort: 80 }
  websecure: { port: 8443, exposedPort: 443 }
providers:
  kubernetesCRD:
    allowCrossNamespace: true   # IngressRoute cross-namespace
logs:
  access:
    enabled: true
    format: json          # Structured logs cho Promtail
nodeSelector:
  node-role: worker
```

### Sealed Secrets (`values/sealed-secrets.yaml`)

```yaml
nodeSelector:
  node-role: worker
resources:
  requests: { cpu: 25m, memory: 32Mi }
  limits: { memory: 64Mi }
```

### ArgoCD (`values/argocd.yaml`)

```yaml
server:
  service:
    type: ClusterIP       # Exposed via Traefik IngressRoute + cloudflared
  extraArgs:
    - --insecure          # TLS terminated at Traefik/Cloudflare level
dex:
  enabled: false          # SSO disabled — login bằng admin password
applicationSet:
  enabled: true           # Needed for App-of-Apps pattern
notifications:
  enabled: false
global:
  nodeSelector:
    workload-type: heavy  # ArgoCD nặng → ưu tiên worker có RAM
configs:
  params:
    server.insecure: true
```

## Verify sau bootstrap

```bash
# cert-manager
kubectl get pods -n cert-manager        # 3 pods: controller, webhook, cainjector
kubectl get crds | grep cert-manager    # certificates, issuers, etc.

# Traefik
kubectl get pods -n traefik
kubectl get svc -n traefik              # ClusterIP
kubectl get crds | grep traefik         # IngressRoute, Middleware, etc.

# Sealed Secrets
kubectl get pods -n sealed-secrets

# ArgoCD
kubectl get pods -n argocd              # 5+ pods: server, controller, repo-server, redis, applicationset
kubectl get svc -n argocd               # argocd-server ClusterIP

# Lấy admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
# → dùng username "admin" + password này để login
```

## Files liên quan

| File | Mô tả |
|------|-------|
| `helmfile/helmfile-bootstrap.yaml` | Helmfile definition (thứ tự + dependencies) |
| `helmfile/values/cert-manager.yaml` | cert-manager Helm values |
| `helmfile/values/traefik.yaml` | Traefik Helm values |
| `helmfile/values/sealed-secrets.yaml` | Sealed Secrets Helm values |
| `helmfile/values/argocd.yaml` | ArgoCD Helm values |
| `helmfile/README.md` | Helmfile usage guide |
