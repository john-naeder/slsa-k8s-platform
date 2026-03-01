# Helmfile — K8s Platform Bootstrap

> Declarative Helm release management thay thế raw `helm install` CLI.
> Xem [plan/infra-deployment-methodology.md](../../../plan/infra-deployment-methodology.md) cho chi tiết tại sao.

## Prerequisites

```bash
# Helm (đã có)
helm version

# Helmfile
curl -fsSL https://github.com/helmfile/helmfile/releases/latest/download/helmfile_linux_amd64.tar.gz \
  | sudo tar xz -C /usr/local/bin helmfile
helmfile --version

# helm-diff plugin (cho helmfile diff)
helm plugin install https://github.com/databus23/helm-diff
```

## Files

| File | Mục đích | Dùng cho |
|---|---|---|
| `helmfile-bootstrap.yaml` | Bootstrap minimum platform cho Argo CD | **Option A** |
| `helmfile-option-b.yaml` | All K8s components (no Argo CD) | **Option B** |
| `values/*.yaml` | Helm values per component | Cả hai |

## Usage

### Option A — Full CNCF (Bootstrap → Argo CD takes over)

```bash
# 1. Preview changes
helmfile -f helmfile-bootstrap.yaml diff

# 2. Apply (idempotent)
helmfile -f helmfile-bootstrap.yaml apply

# 3. Verify
helmfile -f helmfile-bootstrap.yaml list

# 4. Kích hoạt Argo CD App-of-Apps
kubectl apply -f ../argocd/app-of-apps.yaml
# → Argo CD quản lý phần còn lại (Harbor, Tekton, Kyverno, Strimzi, Monitoring, Demo)
```

### Option B — SaaS Lightweight (Helmfile manages everything)

```bash
# 1. Preview changes
helmfile -f helmfile-option-b.yaml diff

# 2. Apply (idempotent)
helmfile -f helmfile-option-b.yaml apply

# 3. Verify
helmfile -f helmfile-option-b.yaml list
```

## Day-2 Operations

```bash
# Thay đổi config → sửa values/*.yaml → chạy lại
helmfile -f <helmfile>.yaml diff    # Xem changes
helmfile -f <helmfile>.yaml apply   # Apply

# Xóa toàn bộ platform
helmfile -f <helmfile>.yaml destroy

# Xem status tất cả releases
helmfile -f <helmfile>.yaml status
```

## Values Files

Mỗi component có values file riêng trong `values/`:

| File | Component | Ghi chú |
|---|---|---|
| `cert-manager.yaml` | cert-manager | CRDs enabled, resource limits |
| `traefik.yaml` | Traefik | ClusterIP, JSON logging, cross-namespace |
| `sealed-secrets.yaml` | Sealed Secrets | Minimal config |
| `argocd.yaml` | Argo CD | Insecure mode (TLS at Traefik), Dex disabled |
| `kyverno.yaml` | Kyverno | Single replica, all controllers enabled |

> Muốn thay đổi Helm values? → Sửa file `values/<component>.yaml` → `helmfile apply`.
> Git diff = audit trail cho mọi thay đổi.
