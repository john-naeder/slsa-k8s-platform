# Infrastructure Deployment Methodology
## Tại sao KHÔNG dùng raw `helm install` CLI — và cách làm đúng

> **Vấn đề:** Hai checklist (Option A, Option B) ban đầu dùng `helm install ...` CLI trực tiếp.
> Đây là anti-pattern cho production infrastructure vì:
> - ❌ Không có audit trail (ai chạy gì, lúc nào?)
> - ❌ Không idempotent (`helm install` fail nếu release đã tồn tại → phải `helm upgrade`)
> - ❌ Không reproducible (copy-paste lệnh = human error)
> - ❌ Khó track lịch sử (phải `helm history` từng release)
> - ❌ Không version-controlled (lệnh chạy xong mất — không commit vào Git)

---

## Phân tích các phương án thay thế

| Approach | Audit Trail | Idempotent | State Tracking | Phức tạp | Đánh giá |
|---|---|---|---|---|---|
| **Raw `helm install` CLI** | ❌ Không | ❌ Không | ❌ Chỉ `helm list` | Thấp | ❌ Anti-pattern |
| **Shell scripts** | ✅ Git-tracked | ⚠️ Phải tự handle | ❌ Không native | Thấp | ⚠️ Tạm được |
| **Ansible (`kubernetes.core.helm`)** | ✅ Playbook in Git | ✅ `state: present` | ⚠️ Không native | Trung bình | ✅ Nhưng sai abstraction |
| **Terraform (helm_release)** | ✅ State file | ✅ Plan/Apply | ✅ `.tfstate` | Cao | ❌ Overkill |
| **Helmfile** | ✅ YAML in Git | ✅ `helmfile apply` | ✅ Helm release state | Thấp | ✅ Purpose-built |
| **Argo CD App-of-Apps** | ✅ Git = source of truth | ✅ Reconcile loop | ✅ Argo tracks drift | Trung bình | ✅⭐ Best steady-state |

---

## Chiến lược: 2-Phase Approach

### Tại sao cần 2 phase?

**Chicken-and-egg problem:**
> Argo CD quản lý mọi thứ trên K8s qua GitOps — nhưng ai cài Argo CD?
> cert-manager cấp TLS cho tất cả services — nhưng ai cài cert-manager?

Giải pháp: tách thành **Bootstrap** (one-time) và **Steady-state** (ongoing).

```
┌──────────────────────────────────────────────────────────────────┐
│  PHASE A: BOOTSTRAP (Helmfile)                                   │
│  ─────────────────────────────────                               │
│  Trang bị "minimum viable platform" — chỉ những component       │
│  cần thiết ĐỂ Argo CD có thể chạy + quản lý phần còn lại.      │
│                                                                  │
│  Components:                                                     │
│    1. local-path-provisioner   (PVC cho mọi stateful component)  │
│    2. cert-manager             (TLS cho mọi Ingress)             │
│    3. Traefik                  (Ingress Controller)              │
│    4. cloudflared              (Tunnel ra internet)              │
│    5. Sealed Secrets           (Encrypt secrets in Git)          │
│    6. Argo CD                  (GitOps CD — "king" component)    │
│                                                                  │
│  Tool: Helmfile                                                  │
│  Chạy: `helmfile apply` (one-time, idempotent, re-runnable)     │
│  File: code/infra/helmfile/helmfile-bootstrap.yaml               │
└──────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  PHASE B: STEADY-STATE (Argo CD App-of-Apps)                     │
│  ────────────────────────────────────────────                    │
│  Argo CD quản lý TẤT CẢ remaining components qua GitOps.        │
│  Git commit = audit trail. Argo = reconciliation + drift detect. │
│                                                                  │
│  Components:                                                     │
│    1. Harbor           (OCI Registry)                            │
│    2. Tekton Pipelines (CI engine)                               │
│    3. Tekton Chains    (provenance + signing)                    │
│    4. Kyverno          (admission policy)                        │
│    5. Strimzi Kafka    (messaging)                               │
│    6. kube-prometheus-stack (monitoring)                         │
│    7. Loki + Promtail  (logging)                                │
│    8. Demo apps        (demo-api, demo-worker)                  │
│                                                                  │
│  Tool: Argo CD Application CRDs (declarative YAML in Git)       │
│  Sync: Automatic (Argo CD watches Git → auto-deploy)            │
│  File: code/infra/argocd/app-of-apps.yaml                       │
│        code/infra/argocd/apps/*.yaml                            │
└──────────────────────────────────────────────────────────────────┘
```

---

## Tại sao Helmfile cho Bootstrap?

### So sánh Helmfile vs Ansible cho K8s

| Tiêu chí | Helmfile | Ansible (`kubernetes.core.helm`) |
|---|---|---|
| Mục đích | K8s Helm orchestration | General automation |
| `helmfile diff` | ✅ Xem changes trước khi apply | ❌ Không có |
| Environments | ✅ Built-in (dev/staging/prod) | ✅ Inventory groups |
| Secret management | ✅ helm-secrets plugin (SOPS) | ✅ Ansible Vault |
| Dependencies / ordering | ✅ `needs:` directive | ✅ Task ordering |
| Learning curve | Thấp (đã biết Helm) | Trung bình (cần module) |
| **Separation of concerns** | **K8s apps only** | **Everything (OS + K8s)** |

**Kết luận:** Ansible cho OS/node-level provisioning (đã có). Helmfile cho K8s platform bootstrapping.
Tách bạch = dễ maintain, dễ debug, dễ hiểu.

### Helmfile Features

```yaml
# helmfile-bootstrap.yaml — Ví dụ đơn giản
repositories:
  - name: jetstack
    url: https://charts.jetstack.io

releases:
  - name: cert-manager
    namespace: cert-manager
    createNamespace: true
    chart: jetstack/cert-manager
    version: 1.16.3
    values:
      - crds:
          enabled: true
          keep: true
```

```bash
# Lệnh chạy:
helmfile diff      # Xem changes TRƯỚC — audit khả năng ảnh hưởng
helmfile apply     # Idempotent — chạy bao nhiêu lần cũng được
helmfile destroy   # Tear down toàn bộ platform (nếu cần)
helmfile list      # Xem trạng thái tất cả releases
```

---

## Tại sao Argo CD App-of-Apps cho Steady-state?

### App-of-Apps Pattern

```
Root Application (app-of-apps)
├── harbor.yaml            → Argo CD Application for Harbor
├── tekton-pipelines.yaml  → Argo CD Application for Tekton
├── tekton-chains.yaml     → Argo CD Application for Tekton Chains
├── kyverno.yaml           → Argo CD Application for Kyverno
├── strimzi.yaml           → Argo CD Application for Strimzi Operator
├── kafka-cluster.yaml     → Argo CD Application for Kafka CRDs
├── monitoring.yaml        → Argo CD Application for kube-prometheus-stack
├── logging.yaml           → Argo CD Application for Loki + Promtail
├── demo-api.yaml          → Argo CD Application for demo-api
└── demo-worker.yaml       → Argo CD Application for demo-worker
```

**Lợi ích:**
1. **Git = Audit trail**: Mọi thay đổi config → Git commit → PR review → merge → Argo sync
2. **Drift detection**: Nếu ai đó `kubectl edit` trực tiếp → Argo phát hiện + revert
3. **Declarative**: Trạng thái mong muốn = YAML file. Argo đảm bảo cluster = desired state.
4. **Rollback**: `git revert` commit → Argo auto-rollback
5. **Visibility**: Argo dashboard hiển thị health + sync status toàn bộ platform
6. **Tự động**: Argo CD auto-sync = không cần chạy lệnh thủ công

---

## Áp dụng cho Option A vs Option B

### Option A (Full CNCF Self-hosted)

```
Ansible playbooks          →  OS/node provisioning (đã có)
Helmfile (bootstrap)       →  6 components (cert-manager → Argo CD)
Argo CD App-of-Apps        →  10+ components (Harbor → Demo apps)
```

| Phase | Tool | Components | Audit |
|---|---|---|---|
| OS/Node | Ansible | K8s, containerd, Flannel, Tailscale | Git + Ansible logs |
| Bootstrap | Helmfile | cert-manager, Traefik, cloudflared, Sealed Secrets, Argo CD | Git (helmfile.yaml) |
| Steady-state | Argo CD | Harbor, Tekton, Kyverno, Strimzi, Monitoring, Demo | Git (App CRDs) |

### Option B (SaaS Lightweight)

```
Ansible playbooks          →  OS/node provisioning (đã có)
Helmfile (bootstrap + all) →  3-4 components (cert-manager, Traefik, Kyverno)
GitHub Actions             →  CI/CD pipeline (SaaS)
```

| Phase | Tool | Components | Audit |
|---|---|---|---|
| OS/Node | Ansible | K8s, containerd, Flannel, Tailscale | Git + Ansible logs |
| Platform | Helmfile | cert-manager, Traefik, cloudflared, Kyverno | Git (helmfile.yaml) |
| CI/CD | GitHub Actions | Build, sign, provenance, deploy | GitHub audit log |

> Option B không cần Argo CD → Helmfile quản lý toàn bộ K8s components.
> Chỉ 3-4 Helm releases → Helmfile đủ đảm bảo reproducibility.

---

## Cài đặt Helmfile

```bash
# Binary install
curl -fsSL https://github.com/helmfile/helmfile/releases/latest/download/helmfile_linux_amd64.tar.gz \
  | tar xz -C /usr/local/bin helmfile

# Verify
helmfile --version

# Hoặc qua package manager
# macOS: brew install helmfile
# go:    go install github.com/helmfile/helmfile@latest
```

**Plugin cần thiết (optional nhưng recommended):**
```bash
helm plugin install https://github.com/databus23/helm-diff  # helmfile diff
```

---

## Workflow tổng thể

```
┌──────────────────────────────────────────────────────────────────────┐
│  1. git clone → 2. cd code/infra/ → 3. Chọn workflow                │
│                                                                      │
│  ┌── OS/Node Provisioning ───────────────────────────────────┐       │
│  │  cd ansible/                                               │       │
│  │  make setup      → cài K8s + containerd + Flannel          │       │
│  └────────────────────────────────────────────────────────────┘       │
│                              ▼                                       │
│  ┌── K8s Platform Bootstrap ─────────────────────────────────┐       │
│  │  cd helmfile/                                              │       │
│  │  helmfile diff    → xem changes trước                      │       │
│  │  helmfile apply   → cài bootstrap components               │       │
│  └────────────────────────────────────────────────────────────┘       │
│                              ▼                                       │
│  ┌── Steady-state (Option A only) ───────────────────────────┐       │
│  │  cd argocd/                                                │       │
│  │  kubectl apply -f app-of-apps.yaml  → bootstrap Argo apps  │       │
│  │  (từ đây Argo CD tự quản lý mọi thứ qua Git)              │       │
│  └────────────────────────────────────────────────────────────┘       │
│                                                                      │
│  ┌── Day-2 Operations ───────────────────────────────────────┐       │
│  │  Option A: git push → Argo CD auto-sync                    │       │
│  │  Option B: git push → GitHub Actions auto-deploy           │       │
│  └────────────────────────────────────────────────────────────┘       │
└──────────────────────────────────────────────────────────────────────┘
```

---

## File structure trong repo

```
code/infra/
├── ansible/                 # OS/Node provisioning (đã có)
│   ├── playbooks/
│   ├── roles/
│   ├── inventory/
│   └── Makefile
├── helmfile/                # K8s platform bootstrap (MỚI)
│   ├── helmfile-bootstrap.yaml    # Option A: bootstrap components
│   ├── helmfile-option-b.yaml     # Option B: all K8s components
│   ├── values/                    # Helm values per component
│   │   ├── cert-manager.yaml
│   │   ├── traefik.yaml
│   │   ├── argocd.yaml
│   │   ├── kyverno.yaml
│   │   └── ...
│   └── README.md
├── argocd/                  # Argo CD App-of-Apps (MỚI — Option A only)
│   ├── app-of-apps.yaml           # Root Application
│   └── apps/                      # Individual Application CRDs
│       ├── harbor.yaml
│       ├── tekton-pipelines.yaml
│       ├── tekton-chains.yaml
│       ├── kyverno.yaml
│       ├── strimzi.yaml
│       ├── kafka-cluster.yaml
│       ├── monitoring.yaml
│       ├── logging.yaml
│       ├── demo-api.yaml
│       └── demo-worker.yaml
├── bootstrap/               # Bridge scripts (đã có)
│   ├── nodes.env
│   ├── bootstrap.env.example
│   ├── sync-inventory.sh
│   └── register-node.sh
└── k8s/                     # Static K8s manifests (đã có)
    └── setup/
```

---

## Kết luận

| Nguyên tắc | Raw CLI ❌ | Phương án mới ✅ |
|---|---|---|
| **Infrastructure as Code** | Lệnh chạy → mất | YAML in Git → permanent |
| **Idempotency** | `helm install` fail nếu exists | `helmfile apply` / Argo reconcile |
| **Audit trail** | Không có | Git history + Argo events |
| **Reproducibility** | Copy-paste = sai | `helmfile apply` = đúng mọi lần |
| **Drift detection** | Không biết | Argo CD phát hiện + alert |
| **Rollback** | `helm rollback` thủ công | `git revert` → Argo auto-rollback |
| **Review process** | Không có | PR review → merge → auto-deploy |

**Full IaC pipeline:**
```
Ansible (OS) → Helmfile (Bootstrap) → Argo CD (Steady-state) → Git (Audit)
```
