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
| 9 | [09-tekton-ci-pipeline.md](09-tekton-ci-pipeline.md) | Tekton CI pipeline, Chains, SLSA L3 provenance |
| 10 | [10-harbor-registry.md](10-harbor-registry.md) | Harbor OCI registry, TLS, Cosign artifacts |
| 11 | [11-kyverno-policies.md](11-kyverno-policies.md) | Kyverno supply-chain security policies |
| 12 | [12-kafka-event-streaming.md](12-kafka-event-streaming.md) | Strimzi Kafka (KRaft mode), topics |
| 13 | [13-demo-applications.md](13-demo-applications.md) | Demo microservices (demo-api, demo-worker) |

## Cấu trúc code

```
code/
├── .env.example                  # Tham khảo tất cả secrets (KHÔNG dùng trực tiếp)
├── infra/
│   ├── bootstrap/                # Phase 1: Bridge scripts (thủ công → Ansible)
│   │   ├── nodes.env             # Node registry: hostname|role|tailscale_ip
│   │   ├── bootstrap.env.example # SSH user, key path
│   │   ├── sync-inventory.sh     # Detect Tailscale IPs → generate Ansible inventory
│   │   └── register-node.sh      # Register + verify từng node
│   │
│   ├── ansible/                  # Phase 2: K8s cluster provisioning
│   │   ├── ansible.cfg
│   │   ├── Makefile              # make ping/master/worker/reset
│   │   ├── inventory/
│   │   │   ├── hosts.yml         # ← AUTO-GENERATED bởi sync-inventory.sh
│   │   │   ├── group_vars/all/   # versions.yml, network.yml, vault.yml
│   │   │   ├── group_vars/masters.yml
│   │   │   ├── group_vars/workers.yml
│   │   │   └── host_vars/        # Per-node: tailscale_ip, node_role
│   │   ├── roles/                # 9 roles (xem chi tiết bên dưới)
│   │   └── playbooks/            # site.yml, master.yml, worker.yml, reset.yml
│   │
│   ├── helmfile/                 # Phase 3: Platform bootstrap
│   │   ├── helmfile-bootstrap.yaml   # cert-manager → Traefik → Sealed Secrets → ArgoCD
│   │   └── values/               # Helm values per component
│   │
│   ├── argocd/                   # Phase 4: GitOps steady-state
│   │   ├── app-of-apps.yaml      # Root Application
│   │   └── apps/                 # Child Applications (8 components)
│   │
│   ├── k8s/manifests/kafka/      # Kafka cluster + topic manifests (Strimzi CRDs)
│   │
│   └── manifests/                # Raw YAML (non-Helm components)
│       ├── argocd/               # IngressRoute, NodePort
│       ├── cloudflared/          # Deployment, setup scripts
│       ├── cluster-issuer.yaml   # Let's Encrypt ClusterIssuers
│       ├── cosign.pub            # Cosign public key (verify signatures)
│       └── local-path-provisioner/
│
├── policies/                     # Kyverno admission policies
│   ├── verify-image-signature.yaml    # Enforce Cosign signature
│   └── verify-slsa-provenance.yaml    # Enforce SLSA provenance
│
├── src/                          # Application source code
│   ├── demo-api/                 # Go HTTP API (producer)
│   │   ├── main.go, Dockerfile, go.mod
│   │   └── k8s/                  # deployment, service, ingressroute
│   └── demo-worker/              # Go Kafka consumer
│       ├── main.go, Dockerfile, go.mod
│       └── k8s/                  # deployment, service
│
└── tekton/                       # CI pipeline resources
    ├── config/chains-config.yaml # Tekton Chains (SLSA provenance)
    ├── pipelines/                # build-and-sign Pipeline
    ├── tasks/                    # git-clone, kaniko-build, update-manifest
    ├── triggers/                 # EventListener, TriggerBinding, TriggerTemplate
    ├── rbac/                     # ServiceAccount, Harbor credentials
    └── runs/                     # Manual PipelineRun (test/debug)
```

## Trạng thái hiện tại

### Infrastructure

| Component | Status | Version | Ghi chú |
|-----------|--------|---------|---------|
| K8s cluster (2 nodes) | ✅ Running | kubeadm v1.32 | Flannel CNI (`--iface=tailscale0`) |
| Tailscale VPN | ✅ Connected | — | 2 nodes on tailnet |
| cert-manager | ✅ Deployed | v1.16.3 | Helmfile bootstrap |
| Traefik | ✅ Deployed | v34.3.0 | ClusterIP, IngressRoute CRDs |
| Sealed Secrets | ✅ Deployed | v2.17.1 | Helmfile bootstrap |
| ArgoCD | ✅ Deployed | v7.8.7 | App-of-Apps pattern, 8 child apps |
| local-path-provisioner | ✅ Deployed | v0.0.30 | Default StorageClass |
| cloudflared | ✅ Running | v2024.12.2 | Tunnel connected to SIN edge |

### CI/CD & Security

| Component | Status | Version | Ghi chú |
|-----------|--------|---------|---------|
| Tekton Pipelines | ✅ Running | v1 API | build-and-sign pipeline |
| Tekton Triggers | ✅ Running | v1beta1 | GitHub webhook → PipelineRun |
| Tekton Chains | ✅ Running | v0.26.0 | Auto-sign + in-toto SLSA v0.2 |
| Harbor | ✅ Running | v1.16.2 | OCI registry + Trivy scanner |
| Kyverno | ✅ Running | v3.3.7 | Enforce: signature + provenance |
| Cosign | ✅ Configured | — | Key-pair signing (non-keyless) |

### Applications & Observability

| Component | Status | Version | Ghi chú |
|-----------|--------|---------|---------|
| Strimzi Operator | ✅ Running | v0.44.0 | Kafka lifecycle management |
| Kafka Cluster | ✅ Running | v3.8.1 | KRaft mode, single-node, topic: demo-events |
| Monitoring | ✅ Running | v68.4.5 | Prometheus + Grafana + Alertmanager |
| Logging | ✅ Running | v2.10.2 | Loki + Promtail |
| demo-api | ✅ Running | Go 1.23 | HTTP API, image sha256-pinned |
| demo-worker | ✅ Running | Go 1.23 | Kafka consumer |

### Networking & Access

| Component | Status | Ghi chú |
|-----------|--------|---------|
| Cloudflare DNS | ✅ Configured | argocd/harbor/tekton/demo.kythuat.vn |
| ArgoCD via Tailscale | ✅ Working | http://100.94.203.28:30080 |
| ArgoCD via Cloudflare | ✅ Working | https://argocd.kythuat.vn |
| Cloudflare Zero Trust | ✅ Configured | Email OTP authentication |
