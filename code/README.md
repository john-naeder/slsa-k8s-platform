# Code Directory — Graduation Thesis

Triển khai SLSA Level 3 Software Supply Chain Security trên bare-metal Kubernetes.

## Cấu trúc thư mục

```
code/
├── README.md                  ← Bạn đang đọc file này
├── .env.example               ← Template biến môi trường
│
├── apps/                      ← Application source code
│   ├── demo-api/              ← HTTP API + Kafka producer
│   └── demo-worker/           ← Kafka consumer + processor
│
├── infra/                     ← Infrastructure as Code
│   ├── ansible/               ← OS & K8s node provisioning (8 roles)
│   │   ├── playbooks/         ← site.yml, master.yml, worker.yml, reset.yml
│   │   ├── roles/             ← common, containerd, kubernetes, cni_*, master_init, worker_join, tailscale, firewall
│   │   ├── inventory/         ← hosts.yml, group_vars (network, versions, vault), host_vars
│   │   └── Makefile           ← 12 targets (setup-master, setup-worker, reset, ping, ...)
│   │
│   ├── bootstrap/             ← Bridge: Ansible ↔ Helmfile
│   │   ├── nodes.env          ← SSH connection info (gitignored)
│   │   ├── bootstrap.env.example
│   │   ├── sync-inventory.sh  ← Đồng bộ từ nodes.env → Ansible inventory
│   │   └── register-node.sh   ← Đăng ký node mới
│   │
│   ├── helmfile/              ← K8s platform bootstrap (Helmfile)
│   │   ├── helmfile-bootstrap.yaml  ← Option A: cert-manager → Traefik → Sealed Secrets → Argo CD
│   │   ├── helmfile-option-b.yaml   ← Option B: cert-manager → Traefik → Kyverno
│   │   ├── values/            ← Helm values override cho mỗi chart
│   │   └── README.md
│   │
│   ├── argocd/                ← GitOps steady-state (Argo CD App-of-Apps)
│   │   ├── app-of-apps.yaml   ← Root Application
│   │   └── apps/              ← harbor, kyverno, strimzi, kafka, monitoring, logging, demo-*
│   │
│   ├── manifests/             ← Raw K8s manifests (không qua Helm)
│   │   ├── cloudflared/       ← Cloudflare Tunnel (token via K8s Secret)
│   │   ├── local-path-provisioner/  ← Dynamic PV cho bare-metal
│   │   └── cluster-issuer.yaml     ← cert-manager Let's Encrypt issuer
│   │
│   └── scripts/               ← Utility & legacy scripts
│       └── legacy/            ← ⚠️ DEPRECATED — pre-Ansible manual scripts
│
├── policies/                  ← Kyverno ClusterPolicy definitions
│   └── README.md              ← Kế hoạch policies (verify-image, require-labels, ...)
│
└── tekton/                    ← Tekton Pipelines & Tasks (SLSA L3 CI/CD)
    └── README.md              ← Pipeline flow, task definitions, Chains config
```

## IaC Pipeline — 3 giai đoạn

```
Phase 1: Ansible          Phase 2: Helmfile           Phase 3: Argo CD
─────────────────       ──────────────────         ────────────────────
OS packages             cert-manager               Harbor
containerd              Traefik                    Kyverno (Option A)
kubeadm/kubelet   →     Sealed Secrets (A)    →    Strimzi + Kafka
kubeadm init            Argo CD (A)                Monitoring (Prometheus+Grafana)
Flannel CNI             Kyverno (B)                Logging (Loki+Promtail)
Tailscale                                          demo-api, demo-worker
```

## Secrets Management

| Secret | Quản lý bởi | Location |
|--------|-------------|----------|
| Ansible vault password | File `.vault_password` (gitignored) | `infra/ansible/` |
| Ansible vault vars | `vault.yml` encrypted (gitignored) | `infra/ansible/inventory/group_vars/all/` |
| Bootstrap SSH info | `nodes.env` (gitignored) | `infra/bootstrap/` |
| Cloudflare tunnel token | K8s Secret `cloudflared-token` | Tạo manual hoặc Sealed Secrets |
| TLS certificates | cert-manager auto-issue | ClusterIssuer Let's Encrypt |
| Container image signing | Cosign keyless (Fulcio OIDC) | Không có key vĩnh viễn |

## Quick Start

```bash
# 1. Provision nodes
cd infra/ansible && make setup-master && make setup-worker

# 2. Bootstrap K8s platform
cd infra/helmfile && helmfile -f helmfile-bootstrap.yaml apply

# 3. Deploy cloudflared tunnel
kubectl apply -f infra/manifests/cloudflared/namespace.yaml
kubectl create secret generic cloudflared-token --namespace=cloudflare --from-literal=tunnel-token=<TOKEN>
kubectl apply -f infra/manifests/cloudflared/deployment.yaml

# 4. Install local-path-provisioner
chmod +x infra/manifests/local-path-provisioner/install.sh
./infra/manifests/local-path-provisioner/install.sh

# 5. Setup cert-manager issuer
kubectl apply -f infra/manifests/cluster-issuer.yaml

# 6. Deploy app-of-apps (Option A)
kubectl apply -f infra/argocd/app-of-apps.yaml
```
