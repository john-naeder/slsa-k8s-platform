# Worker Node Setup - Ubuntu Server 24.04

## Tổng quan

| Thông tin | Giá trị |
|---|---|
| OS Worker | Ubuntu Server 24.04 |
| Control plane | Ubuntu Server (Tailscale IP `100.95.126.102`) |
| K8s version | v1.32.x |
| Container runtime | containerd |
| CNI | Flannel (cài trên control plane, tự deploy xuống worker) |

> **Script tự động**: Chạy `sudo ./04-worker-setup.sh` để thực hiện toàn bộ các bước bên dưới.

---

## Bước 1: Tailscale

```bash
# Cài Tailscale
curl -fsSL https://tailscale.com/install.sh | sh

# Kết nối
sudo tailscale up

# Kiểm tra
tailscale ip -4

# Ping control plane
ping -c 3 100.95.126.102

# Test API server port
nc -zv 100.95.126.102 6443
```

---

## Bước 2: Tắt swap + Kernel modules + sysctl

```bash
# Tắt swap
sudo swapoff -a
sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab

# Kernel modules
sudo modprobe overlay && sudo modprobe br_netfilter
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

# Sysctl
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system
```

---

## Bước 3: containerd

```bash
# Cài từ Docker repo (phiên bản mới nhất)
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y containerd.io

# Config SystemdCgroup
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable --now containerd
sudo systemctl restart containerd
```

---

## Bước 4: kubeadm, kubelet, kubectl + CNI plugins

```bash
# K8s packages
sudo apt-get install -y apt-transport-https gpg
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.32/deb/Release.key | \
    sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.32/deb/ /' | \
    sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable kubelet

# CNI plugins
CNI_VERSION="v1.6.2"
sudo mkdir -p /opt/cni/bin
curl -fsSL "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz" | \
    sudo tar -C /opt/cni/bin -xz
```

---

## Bước 5: Cấu hình kubelet Tailscale IP + Join cluster

```bash
# Lấy Tailscale IP
WORKER_TS_IP=$(tailscale ip -4)

# Cấu hình kubelet --node-ip
echo "KUBELET_EXTRA_ARGS=--node-ip=${WORKER_TS_IP}" | sudo tee /etc/default/kubelet
sudo mkdir -p /etc/systemd/system/kubelet.service.d
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service.d/20-tailscale.conf
[Service]
Environment="KUBELET_EXTRA_ARGS=--node-ip=${WORKER_TS_IP}"
EOF
sudo systemctl daemon-reload
```

### Lấy join command từ control plane:
```bash
# TRÊN CONTROL PLANE, chạy:
sudo kubeadm token create --print-join-command
```

### Chạy join TRÊN WORKER:
```bash
sudo kubeadm join 100.95.126.102:6443 \
    --token <TOKEN> \
    --discovery-token-ca-cert-hash sha256:<HASH> \
    --node-name $(hostname)
```

### Patch kubelet --node-ip (SAU KHI join):
```bash
WORKER_TS_IP=$(tailscale ip -4)
sudo sed -i "s|\"$| --node-ip=${WORKER_TS_IP}\"|" /var/lib/kubelet/kubeadm-flags.env
sudo systemctl restart kubelet
```

---

## Bước 6: Verify (trên Control Plane)

```bash
kubectl get nodes -o wide
```

Kết quả mong đợi:
```
NAME             STATUS   ROLES           AGE   VERSION    INTERNAL-IP
<master>         Ready    control-plane   Xm    v1.32.x    100.95.126.102
<worker>         Ready    <none>          Xm    v1.32.x    <worker-tailscale-ip>
```

```bash
# Kiểm tra tất cả pods:
kubectl get pods -A

# Test deploy:
kubectl create deployment nginx --image=nginx --replicas=2
kubectl get pods -o wide
```

---

## Troubleshooting

### Token hết hạn (mặc định 24h):
```bash
sudo kubeadm token create --print-join-command
```

### Worker stuck ở NotReady:
```bash
sudo journalctl -u kubelet -f --no-pager | tail -50

# Nguyên nhân thường gặp:
# 1. Swap chưa tắt → swapoff -a
# 2. CNI plugins thiếu → ls /opt/cni/bin/
# 3. containerd chưa chạy → systemctl start containerd
# 4. Tailscale chưa kết nối → tailscale status
```

### Pods không communicate giữa nodes:
```bash
kubectl get pods -n kube-flannel -o wide   # Flannel phải Running trên cả 2 nodes
ip route | grep flannel
```

### Reset worker (join lại):
```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d
sudo iptables -F && sudo iptables -t nat -F

# Trên control plane, xóa node cũ:
kubectl delete node <worker-name>
# Rồi join lại từ Bước 5
```
