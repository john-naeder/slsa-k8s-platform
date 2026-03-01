# 02 — Kubernetes Cluster Provisioning (Ansible)

> Provision K8s cluster trên bare metal nodes qua Ansible automation.
> Yêu cầu: Phase 01 hoàn tất (nodes có Ubuntu + Tailscale + SSH).

## Tổng quan

```
  Ansible Roles (thứ tự chạy):
  ──────────────────────────────────────────────────────
  tailscale (verify) → common → containerd → kubernetes
  → cni_plugins → firewall → master_init → cni_flannel
  → worker_join
```

## Cluster Specifications

| Setting | Giá trị |
|---------|---------|
| K8s version | 1.32 |
| Container runtime | containerd (Docker repo) |
| CNI | Flannel (--iface=tailscale0) |
| Pod CIDR | 10.244.0.0/16 |
| Service CIDR | 10.95.0.0/12 |
| API server port | 6443 |
| VPN interface | tailscale0 |
| CNI plugins | v1.6.2 |
| Admin user | john |

## Chạy provisioning

```bash
cd code/infra/ansible/

# 1. Verify connectivity
make ping

# 2. Setup toàn bộ cluster (master + workers)
make setup
# Tương đương: ansible-playbook playbooks/site.yml

# HOẶC chạy từng phần:
make master    # Chỉ master (init cluster + CNI)
make worker    # Chỉ workers (join vào cluster)
```

### Dry-run (không thực thi)

```bash
make check
# Tương đương: ansible-playbook playbooks/site.yml --check --diff
```

## Ansible Roles chi tiết

### 1. `tailscale` — Verify Only

**KHÔNG cài Tailscale** (đã cài thủ công ở Phase 01). Chỉ verify:

- Tailscale binary installed
- `tailscaled` service running
- Node connected to tailnet
- Tailscale IP khớp với inventory (`host_vars/<hostname>.yml`)
- `tailscale0` interface exists
- Workers có thể ping master qua Tailscale

### 2. `common` — Kernel & System Prep

- Load kernel modules: `overlay`, `br_netfilter`
- Set sysctl: `net.bridge.bridge-nf-call-iptables = 1`, `net.ipv4.ip_forward = 1`
- Disable swap (immediately + persist qua fstab)
- Check AppArmor status

### 3. `containerd` — Container Runtime

- Add Docker apt repository
- Install `containerd.io`
- Generate default config: `containerd config default`
- Enable `SystemdCgroup = true` (required by kubeadm)
- Force restart containerd (fix CRI 2.2.x issue)
- Verify CRI endpoint via `crictl`

### 4. `kubernetes` — kubeadm/kubelet/kubectl

- Add Kubernetes apt repository (v1.32)
- Install kubeadm, kubelet, kubectl
- `apt-mark hold` (prevent accidental upgrade)
- Configure kubelet to advertise Tailscale IP:
  - `/etc/default/kubelet`: `KUBELET_EXTRA_ARGS=--node-ip=<tailscale_ip>`
  - Systemd drop-in: `20-tailscale.conf`

### 5. `cni_plugins` — CNI Binaries

- Download CNI plugins release (v1.6.2) → `/opt/cni/bin/`
- Includes: loopback, bridge, flannel, host-local, portmap, etc.
- Skip download nếu đã có
- Fail play nếu missing (CoreDNS dependency)

### 6. `firewall` — UFW Rules

**Master ports:**
| Port | Protocol | Service |
|------|----------|---------|
| 22 | TCP | SSH |
| 6443 | TCP | K8s API server |
| 2379:2380 | TCP | etcd |
| 10250 | TCP | kubelet API |
| 10259 | TCP | kube-scheduler |
| 10257 | TCP | kube-controller-manager |
| 8472 | UDP | Flannel VXLAN |

**Worker ports:**
| Port | Protocol | Service |
|------|----------|---------|
| 22 | TCP | SSH |
| 10250 | TCP | kubelet API |
| 10256 | TCP | kube-proxy healthz |
| 30000:32767 | TCP | NodePort Services |
| 8472 | UDP | Flannel VXLAN |

**Đặc biệt:**
- Trust all traffic on `tailscale0` interface
- Trust Pod CIDR (`10.244.0.0/16`)

### 7. `master_init` — Control Plane Init

- `kubeadm init` với:
  - `--apiserver-advertise-address=<tailscale_ip>`
  - `--apiserver-cert-extra-sans=<tailscale_ip>`
  - `--pod-network-cidr=10.244.0.0/16`
  - `--service-cidr=10.95.0.0/12`
  - `--cri-socket unix:///run/containerd/containerd.sock`
- Setup `~/.kube/config` cho admin user
- Patch `--node-ip` trong `kubeadm-flags.env`
- Generate join command → save as Ansible fact
- Verify: `kubectl cluster-info`

### 8. `cni_flannel` — Flannel CNI Deployment

- Apply Flannel manifest từ upstream
- **Patch DaemonSet** thêm `--iface=tailscale0`:
  ```bash
  kubectl -n kube-flannel patch daemonset kube-flannel-ds ...
  ```
- Wait for Flannel rollout
- Wait for CoreDNS readiness
- Verify each node's internal IP = Tailscale IP

### 9. `worker_join` — Join Workers

- Reset stale kubeadm state + flush iptables
- Set `--node-ip=<tailscale_ip>` trong kubelet args
- Run join command (from master Ansible fact)
- Patch `kubeadm-flags.env` với `--node-ip`
- Restart kubelet
- Verify service status

## Inventory Structure

```
ansible/inventory/
├── hosts.yml                    # Node list (auto-generated)
├── group_vars/
│   ├── all/
│   │   ├── versions.yml         # K8s 1.32, CNI v1.6.2, etc.
│   │   ├── network.yml          # CIDRs, firewall ports, VPN interface
│   │   └── vault.yml            # Encrypted secrets (ansible-vault)
│   ├── masters.yml              # k8s_admin_user, kubeadm init args
│   └── workers.yml              # auto_join_cluster: true
└── host_vars/
    ├── userver-master.yml       # tailscale_ip, node_role
    └── userver-home-worker.yml  # tailscale_ip, node_role
```

## Ansible Vault

Secrets được mã hóa bằng Ansible Vault:

```bash
# Tạo vault password file
echo "your-vault-password" > code/infra/ansible/.vault_password
chmod 600 code/infra/ansible/.vault_password

# Tạo vault secrets
cd code/infra/ansible/
make vault-edit    # Sửa vault.yml (encrypted)
make vault-view    # Xem nội dung

# Template: inventory/group_vars/all/vault.yml.example
```

## Reset Cluster

```bash
# Reset toàn bộ
make reset

# Reset chỉ workers
make reset-workers

# Reset một node cụ thể
ansible-playbook playbooks/reset.yml --limit userver-home-worker
```

Reset sẽ:
- `kubeadm reset -f`
- Xóa CNI config (`/etc/cni/net.d`)
- Flush iptables
- Xóa kubeconfig (master only)
- Restart kubelet

## Makefile Commands

| Command | Mô tả |
|---------|-------|
| `make help` | Hiển thị tất cả commands |
| `make sync` | Detect Tailscale IPs + generate inventory |
| `make ping` | Test SSH tới tất cả nodes |
| `make setup` | Full cluster setup (master + workers) |
| `make master` | Setup chỉ master node |
| `make worker` | Setup + join tất cả workers |
| `make worker-one NODE=<name>` | Join một worker cụ thể |
| `make reset` | Reset K8s trên tất cả nodes |
| `make check` | Dry-run (không thực thi) |
| `make lint` | Lint playbooks (cần ansible-lint) |
| `make vault-encrypt` | Encrypt vault.yml |
| `make vault-edit` | Edit vault.yml (encrypted) |

## Files liên quan

| File | Mô tả |
|------|-------|
| `ansible/ansible.cfg` | Ansible config (inventory path, SSH settings) |
| `ansible/Makefile` | Quick commands |
| `ansible/playbooks/site.yml` | Full cluster playbook |
| `ansible/playbooks/master.yml` | Master-only playbook |
| `ansible/playbooks/worker.yml` | Worker-only playbook |
| `ansible/playbooks/reset.yml` | Reset playbook |
| `ansible/roles/*/` | 9 Ansible roles |
| `ansible/README.md` | Chi tiết kiến trúc + workflow |
