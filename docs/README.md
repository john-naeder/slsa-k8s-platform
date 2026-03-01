# SLSA K8s Platform — Setup & Recreation Guide

> Tài liệu tổng hợp toàn bộ quá trình setup từ Phase 0 (bare metal) tới trạng thái hiện tại.
> Dùng để recreate toàn bộ platform từ đầu nếu cần.

## Kiến trúc tổng quan

```
                          Internet
                             │
                    ┌────────┴────────┐
                    │  Cloudflare CDN │  WAF, DDoS protection
                    │  (kythuat.vn)   │  Zero Trust Access
                    └────────┬────────┘
                             │ Cloudflare Tunnel (encrypted, no open ports)
                             │
              ┌──────────────┴──────────────┐
              │    cloudflared Pod (K8s)     │
              └──────────────┬──────────────┘
                             │ HTTP
              ┌──────────────┴──────────────┐
              │   Traefik Ingress Controller │  IngressRoute CRDs
              │   (ClusterIP — port 80/443) │  Security headers
              └──────────────┬──────────────┘
                             │
              ┌──────────────┴──────────────┐
              │     K8s Services / Pods      │
              │  ArgoCD, Harbor, Grafana...  │
              └─────────────────────────────┘

        ════════════════════════════════════════
                   Tailscale VPN (100.x.x.x)
        ════════════════════════════════════════
              │                         │
        ┌─────────────┐          ┌─────────────┐
        │   Master    │          │   Worker    │
        │ userver-    │          │ userver-    │
        │ master      │          │ home-worker │
        │ 100.95.     │          │ 100.94.     │
        │ 126.102     │          │ 203.28      │
        └─────────────┘          └─────────────┘
         Ubuntu 24.04             Ubuntu 24.04
         kubeadm 1.32             kubeadm 1.32
         containerd               containerd
```

## Tài liệu theo phase

| # | Tài liệu | Mô tả |
|---|-----------|-------|
| 0 | [00-prerequisites.md](00-prerequisites.md) | Yêu cầu phần cứng, phần mềm, tài khoản |
| 1 | [01-bare-metal-and-tailscale.md](01-bare-metal-and-tailscale.md) | Cài OS, Tailscale VPN, SSH keys |
| 2 | [02-kubernetes-cluster.md](02-kubernetes-cluster.md) | Provision K8s cluster qua Ansible |
| 3 | [03-platform-bootstrap.md](03-platform-bootstrap.md) | Helmfile bootstrap: cert-manager, Traefik, Sealed Secrets, ArgoCD |
| 4 | [04-post-bootstrap.md](04-post-bootstrap.md) | local-path-provisioner, cloudflared, ClusterIssuer |
| 5 | [05-argocd-gitops.md](05-argocd-gitops.md) | ArgoCD App-of-Apps, SSH deploy key, UI access |
| 6 | [06-cloudflare-networking.md](06-cloudflare-networking.md) | Cloudflare Tunnel route, DNS, Zero Trust Access |
| 7 | [07-verification.md](07-verification.md) | Checklist verify toàn bộ hệ thống |
| 8 | [08-troubleshooting.md](08-troubleshooting.md) | Lỗi thường gặp và cách xử lý |

## Cấu trúc code

```
code/
├── .env.example                  # Tham khảo tất cả secrets (KHÔNG dùng trực tiếp)
└── infra/
    ├── bootstrap/                # Phase 1: Bridge scripts (thủ công → Ansible)
    │   ├── nodes.env             # Node registry: hostname|role|tailscale_ip
    │   ├── bootstrap.env.example # SSH user, key path
    │   ├── sync-inventory.sh     # Detect Tailscale IPs → generate Ansible inventory
    │   └── register-node.sh      # Register + verify từng node
    │
    ├── ansible/                  # Phase 2: K8s cluster provisioning
    │   ├── ansible.cfg
    │   ├── Makefile              # make ping/master/worker/reset
    │   ├── inventory/
    │   │   ├── hosts.yml         # ← AUTO-GENERATED bởi sync-inventory.sh
    │   │   ├── group_vars/all/   # versions.yml, network.yml, vault.yml
    │   │   ├── group_vars/masters.yml
    │   │   ├── group_vars/workers.yml
    │   │   └── host_vars/        # Per-node: tailscale_ip, node_role
    │   ├── roles/                # 9 roles (xem chi tiết bên dưới)
    │   └── playbooks/            # site.yml, master.yml, worker.yml, reset.yml
    │
    ├── helmfile/                 # Phase 3: Platform bootstrap
    │   ├── helmfile-bootstrap.yaml   # cert-manager → Traefik → Sealed Secrets → ArgoCD
    │   └── values/               # Helm values per component
    │
    ├── argocd/                   # Phase 4: GitOps steady-state
    │   ├── app-of-apps.yaml      # Root Application
    │   └── apps/                 # Child Applications (8 components)
    │
    └── manifests/                # Raw YAML (non-Helm components)
        ├── argocd/               # IngressRoute, NodePort
        ├── cloudflared/          # Deployment, setup scripts
        ├── cluster-issuer.yaml   # Let's Encrypt ClusterIssuers
        └── local-path-provisioner/
```

## Trạng thái hiện tại,m

| Component | Status | Ghi chú |
|-----------|--------|---------|
| K8s cluster (2 nodes) | ✅ Running | kubeadm v1.32, Flannel CNI |
| Tailscale VPN | ✅ Connected | 2 nodes on tailnet |
| cert-manager | ✅ Deployed | Helmfile bootstrap |
| Traefik | ✅ Deployed | ClusterIP, IngressRoute CRDs |
| Sealed Secrets | ✅ Deployed | Helmfile bootstrap |
| ArgoCD | ✅ Deployed | Helm chart 7.8.7, v2.14.3 |
| local-path-provisioner | ✅ Deployed | Default StorageClass |
| cloudflared | ✅ Running | Tunnel connected to SIN edge |
| ArgoCD App-of-Apps | ✅ Applied | 8 child apps created |
| Cloudflare DNS | ✅ Configured | argocd.kythuat.vn → tunnel CNAME |
| ArgoCD via Tailscale | ✅ Working | http://100.94.203.28:30080 |
| ArgoCD via Cloudflare | ✅ Working | https://argocd.kythuat.vn |
| Cloudflare Zero Trust | ⚠️ Pending | Cần token có Access scope |
