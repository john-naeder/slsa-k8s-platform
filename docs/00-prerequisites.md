# 00 — Prerequisites (Yêu cầu trước khi bắt đầu)

## Phần cứng

| Node | Vai trò | Tối thiểu | Khuyến nghị |
|------|---------|-----------|-------------|
| Master (control plane) | API server, etcd, scheduler | 2 CPU, 4 GB RAM, 30 GB disk | 4 CPU, 8 GB RAM, 50 GB disk |
| Worker | Chạy workloads | 2 CPU, 4 GB RAM, 30 GB disk | 4 CPU, 16 GB RAM, 100 GB disk |

> **Lưu ý:** Dự án này dùng 2 node bare metal (physical machines hoặc VMs). Các node KHÔNG cần public IP — mọi kết nối qua Tailscale VPN.

## Hệ điều hành

- **Ubuntu Server 24.04 LTS** trên mỗi node
- Cài minimal (không cần GUI)

## Tài khoản & Services

| Service | Cần gì | Tạo ở đâu |
|---------|--------|-----------|
| **Tailscale** | Tailscale account (free) | [login.tailscale.com](https://login.tailscale.com) |
| **Cloudflare** | Account + domain (kythuat.vn đã trỏ NS về CF) | [dash.cloudflare.com](https://dash.cloudflare.com) |
| **GitHub** | Repository cho GitOps | [github.com](https://github.com) |

## Cloudflare API Token

Tạo tại [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens):

| Permission | Scope |
|-----------|-------|
| Zone → DNS → Edit | Zone: kythuat.vn |
| Account → Cloudflare Tunnel → Edit | Account |
| Account → Access: Apps and Policies → Edit | Account (cho Zero Trust) |

Lưu token → dùng khi chạy `setup-route.sh` và `setup-access-policy.sh`.

## Phần mềm trên máy local (workstation)

```bash
# Tailscale (workstation cũng phải join tailnet)
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

# SSH key (dùng ed25519)
ssh-keygen -t ed25519 -C "your-email@example.com"
# → Copy public key lên mỗi node: ssh-copy-id user@<tailscale-ip>

# kubectl (cùng version với cluster)
curl -LO "https://dl.k8s.io/release/v1.32.0/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/

# Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Helmfile
curl -fsSL https://github.com/helmfile/helmfile/releases/latest/download/helmfile_linux_amd64.tar.gz \
  | sudo tar xz -C /usr/local/bin helmfile

# helm-diff plugin (bắt buộc cho helmfile diff)
helm plugin install https://github.com/databus23/helm-diff

# Ansible (dùng pip hoặc apt)
pip install ansible
# hoặc: sudo apt install ansible

# Python 3 (cho bootstrap scripts)
python3 --version

# jq, curl, dig (utilities)
sudo apt install -y jq curl dnsutils
```

## Git Repository

Clone repo:
```bash
git clone git@github.com:john-naeder/slsa-k8s-platform.git
cd slsa-k8s-platform
```

## Domain DNS

Domain `kythuat.vn` phải trỏ NS về Cloudflare:
- `kobe.ns.cloudflare.com`
- `ali.ns.cloudflare.com`

Verify:
```bash
dig NS kythuat.vn +short
```
