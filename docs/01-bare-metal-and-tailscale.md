# 01 — Bare Metal Setup & Tailscale VPN

> Phase thủ công: cài OS, Tailscale, SSH key trên mỗi bare metal node.
> Sau phase này, Ansible có thể SSH vào các node qua Tailscale VPN.

## Workflow

```
 ┌─────────────────────────────────────────────────────────────────┐
 │  Bước 1: THỦ CÔNG (trên mỗi bare metal node)                   │
 │                                                                 │
 │  1. Cài Ubuntu Server 24.04                                     │
 │  2. curl -fsSL https://tailscale.com/install.sh | sh            │
 │  3. sudo tailscale up --hostname=<tên-node>                     │
 │  4. Copy SSH public key vào node                                │
 │  5. (Optional) Setup passwordless sudo                          │
 └──────────────────────┬──────────────────────────────────────────┘
                        │
                        ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │  Bước 2: sync-inventory.sh (từ máy local)                       │
 │                                                                 │
 │  Detect Tailscale IPs → Generate Ansible inventory              │
 └─────────────────────────────────────────────────────────────────┘
```

## Bước 1: Cài Ubuntu Server 24.04

Trên mỗi bare metal machine:

1. Boot từ USB (Ubuntu Server 24.04 LTS ISO)
2. Cài minimal, tạo user `john`
3. Enable SSH server (mặc định enabled, hoặc `sudo apt install openssh-server`)

## Bước 2: Cài Tailscale

SSH vào node (LAN IP ban đầu) rồi chạy:

```bash
# Cài Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Join tailnet với hostname cụ thể
sudo tailscale up --hostname=userver-master    # cho master
sudo tailscale up --hostname=userver-home-worker  # cho worker

# Verify
tailscale ip -4    # → 100.x.x.x
tailscale status   # Hiển thị tất cả nodes trên tailnet
```

### Danh sách nodes hiện tại

| Hostname | Role | Tailscale IP |
|----------|------|-------------|
| userver-master | master | 100.95.126.102 |
| userver-home-worker | worker | 100.94.203.28 |

## Bước 3: Copy SSH Key

Từ máy local (cũng đang bật Tailscale):

```bash
# Copy SSH public key lên mỗi node
ssh-copy-id -i ~/.ssh/id_ed25519.pub john@100.95.126.102
ssh-copy-id -i ~/.ssh/id_ed25519.pub john@100.94.203.28

# Test SSH qua Tailscale
ssh john@100.95.126.102 "hostname"
ssh john@100.94.203.28 "hostname"
```

## Bước 4: (Optional) Passwordless sudo

Trên mỗi node:
```bash
sudo visudo
# Thêm dòng:
# john ALL=(ALL) NOPASSWD: ALL
```

## Bước 5: Đăng ký node vào registry

```bash
cd code/infra/bootstrap/

# Cách 1: Dùng register-node.sh (tự detect IP + verify SSH)
bash register-node.sh userver-master master
bash register-node.sh userver-home-worker worker

# Cách 2: Sửa nodes.env thủ công
cat nodes.env
# Format: HOSTNAME|ROLE|TAILSCALE_IP
# userver-master|master|100.95.126.102
# userver-home-worker|worker|100.94.203.28
```

## Bước 6: Sync Ansible Inventory

```bash
cd code/infra/bootstrap/

# Tạo bootstrap.env từ template
cp bootstrap.env.example bootstrap.env
# Sửa ADMIN_USER, SSH_PRIVATE_KEY nếu cần

# Sync inventory (detect Tailscale IPs → generate Ansible files)
bash sync-inventory.sh

# Hoặc chỉ xem preview
bash sync-inventory.sh --dry-run
```

Script sẽ tự động generate:
- `ansible/inventory/hosts.yml` — danh sách hosts
- `ansible/inventory/host_vars/<hostname>.yml` — per-node variables

## Bước 7: Verify connectivity

```bash
cd code/infra/ansible/

# Ping tất cả nodes qua Ansible
make ping
# → SUCCESS cho tất cả nodes
```

## Thêm node mới

1. Cài Ubuntu + Tailscale + SSH key trên node mới (Bước 1-4)
2. Register:
   ```bash
   cd code/infra/bootstrap/
   bash register-node.sh <new-hostname> worker
   ```
3. Sync inventory:
   ```bash
   bash sync-inventory.sh
   ```
4. Join cluster:
   ```bash
   cd ../ansible/
   make worker-one NODE=<new-hostname>
   ```

## Files liên quan

| File | Mô tả |
|------|-------|
| `code/infra/bootstrap/nodes.env` | Node registry (hostname, role, IP) |
| `code/infra/bootstrap/bootstrap.env.example` | Template config cho scripts |
| `code/infra/bootstrap/sync-inventory.sh` | Detect IPs → generate inventory |
| `code/infra/bootstrap/register-node.sh` | Register + verify từng node |
