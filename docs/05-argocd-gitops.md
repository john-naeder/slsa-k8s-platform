# 05 — ArgoCD & GitOps Setup

> Kích hoạt ArgoCD quản lý toàn bộ remaining platform components qua Git.
> Từ đây, mọi thay đổi config = Git commit → ArgoCD auto-deploy.

## Yêu cầu

- ArgoCD đang chạy (Phase 03 helmfile bootstrap)
- Git repository: `git@github.com:john-naeder/slsa-k8s-platform.git`

## 5.1 — SSH Deploy Key cho ArgoCD

ArgoCD cần quyền đọc Git repo. Dùng SSH deploy key (read-only).

### Tạo deploy key

```bash
# Generate SSH key pair
ssh-keygen -t ed25519 -C "argocd-deploy-key" -f /tmp/argocd-deploy-key -N ""

# Hiển thị public key → copy lên GitHub
cat /tmp/argocd-deploy-key.pub
```

### Thêm deploy key trên GitHub

1. Repository → Settings → Deploy keys → **Add deploy key**
2. Title: `argocd-deploy-key`
3. Key: paste nội dung `/tmp/argocd-deploy-key.pub`
4. **KHÔNG** check "Allow write access"

### Tạo K8s Secret cho ArgoCD

```bash
kubectl -n argocd create secret generic repo-slsa-k8s-platform \
  --from-file=sshPrivateKey=/tmp/argocd-deploy-key \
  --from-literal=type=git \
  --from-literal=url=git@github.com:john-naeder/slsa-k8s-platform.git

# Label secret cho ArgoCD nhận diện
kubectl -n argocd label secret repo-slsa-k8s-platform \
  argocd.argoproj.io/secret-type=repository

# Xóa key tạm
rm /tmp/argocd-deploy-key /tmp/argocd-deploy-key.pub
```

### Verify

```bash
kubectl -n argocd get secret repo-slsa-k8s-platform
# ArgoCD UI → Settings → Repositories → should show "Connected"
```

## 5.2 — App-of-Apps Deployment

ArgoCD dùng **App-of-Apps pattern**: 1 root Application quản lý N child Applications.

```bash
# Apply root application
kubectl apply -f code/infra/argocd/app-of-apps.yaml
```

### Root Application (`app-of-apps.yaml`)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-apps
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: git@github.com:john-naeder/slsa-k8s-platform.git
    targetRevision: main
    path: code/infra/argocd/apps     # Thư mục chứa child Application CRDs
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true       # Xóa resource nếu file bị xóa khỏi Git
      selfHeal: true    # Revert drift — nếu ai kubectl edit → ArgoCD revert
```

### Child Applications (8 components)

| Application | Chart/Source | Namespace | Mô tả |
|-------------|-------------|-----------|-------|
| strimzi-operator | strimzi.io/charts (v0.44.0) | kafka | Kafka Operator (CRDs) |
| kafka-cluster | Git path: `code/infra/k8s/manifests/kafka` | kafka | Kafka + KafkaTopic CRDs |
| kyverno | kyverno.github.io (v3.3.7) | kyverno | Admission Policy Engine |
| monitoring | prometheus-community (v68.4.5) | monitoring | Prometheus + Grafana + Alertmanager |
| logging | grafana.github.io (v2.10.2) | logging | Loki + Promtail |
| harbor | helm.goharbor.io (v1.16.2) | harbor | OCI Container Registry |
| demo-api | Git path: `code/src/demo-api/k8s` | demo | HTTP API + Kafka Producer |
| demo-worker | Git path: `code/src/demo-worker/k8s` | demo | Kafka Consumer |

### Verify

```bash
# List all ArgoCD Applications
kubectl get applications -n argocd
# NAME               SYNC STATUS   HEALTH STATUS
# platform-apps      Synced        Healthy
# strimzi-operator   Synced        Healthy
# kafka-cluster      ...
# kyverno            ...
# monitoring         ...
# logging            ...
# harbor             ...
# demo-api           ...
# demo-worker        ...
```

## 5.3 — ArgoCD UI Access

### Cách 1: Tailscale VPN (direct — nội bộ)

```bash
# Apply NodePort service
kubectl apply -f code/infra/manifests/argocd/nodeport-tailscale.yaml
```

Truy cập:
- `http://100.94.203.28:30080` (worker node)
- `http://100.95.126.102:30080` (master node)

> Chỉ truy cập được từ thiết bị trong Tailscale network.

### Cách 2: Cloudflare Tunnel (public — bảo mật qua Zero Trust)

```bash
# Apply IngressRoute + security headers middleware
kubectl apply -f code/infra/manifests/argocd/ingressroute.yaml
```

Truy cập: `https://argocd.kythuat.vn`

**Luồng traffic:**
```
Internet → Cloudflare CDN (WAF/DDoS) → Cloudflare Tunnel (encrypted)
  → cloudflared Pod → Traefik (IngressRoute) → argocd-server
```

**5 lớp bảo mật:**
1. Cloudflare WAF + DDoS protection
2. Cloudflare Access — Zero Trust auth (email OTP)
3. Cloudflare Tunnel — encrypted, no open inbound ports
4. Traefik — security headers + request routing
5. ArgoCD login — username/password

### IngressRoute manifest

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd-server
  namespace: argocd
spec:
  entryPoints: [web]
  routes:
    - match: Host(`argocd.kythuat.vn`)
      kind: Rule
      services:
        - name: argocd-server
          port: 80
      middlewares:
        - name: argocd-headers
---
# Security headers middleware
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: argocd-headers
  namespace: argocd
spec:
  headers:
    frameDeny: true                    # X-Frame-Options: DENY
    contentTypeNosniff: true           # X-Content-Type-Options: nosniff
    browserXssFilter: true             # X-XSS-Protection: 1; mode=block
    stsSeconds: 31536000               # Strict-Transport-Security: max-age=1year
    stsIncludeSubdomains: true
    stsPreload: true
    customResponseHeaders:
      X-Robots-Tag: "noindex, nofollow"
      Referrer-Policy: "strict-origin-when-cross-origin"
```

### Login credentials

```bash
# Username
admin

# Password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```

## GitOps Workflow (sau khi setup xong)

```
Developer → Git commit → Push to main
                              │
                              ▼
                    ArgoCD watches repo
                              │
                              ▼
                    Detect drift (Git ≠ Cluster)
                              │
                              ▼
                    Auto-sync → Apply changes
                              │
                              ▼
                    Cluster state = Git state ✅
```

**Thêm component mới:**
1. Tạo file `code/infra/argocd/apps/<new-app>.yaml`
2. Git commit + push
3. ArgoCD tự detect + deploy

## Files liên quan

| File | Mô tả |
|------|-------|
| `argocd/app-of-apps.yaml` | Root Application |
| `argocd/apps/*.yaml` | 8 child Application definitions |
| `manifests/argocd/ingressroute.yaml` | Traefik IngressRoute + security headers |
| `manifests/argocd/nodeport-tailscale.yaml` | NodePort service cho Tailscale access |
| `helmfile/values/argocd.yaml` | ArgoCD Helm values |
