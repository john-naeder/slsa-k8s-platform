#!/bin/bash
# ============================================================
# Script 1/3: K8s Control Plane Setup - Ubuntu Server
# 
# Chạy bằng: sudo bash 01-control-plane-setup.sh
#
# Script này cài đặt tất cả prerequisites cần thiết:
#   - Kernel modules (overlay, br_netfilter)
#   - Sysctl (ip_forward, bridge-nf-call)
#   - Tắt swap
#   - containerd (container runtime)
#   - CNI plugins (loopback, bridge, flannel...)
#   - kubeadm, kubelet, kubectl
#   - Firewall rules cho K8s + Tailscale
#   - Cấu hình kubelet dùng Tailscale IP
# ============================================================
set -euo pipefail

TAILSCALE_IP="100.95.126.102"
POD_CIDR="10.244.0.0/16"
K8S_VERSION="1.32"
CNI_VERSION="v1.6.2"

echo "============================================"
echo " K8s Control Plane Setup on Ubuntu Server"
echo " Tailscale IP: ${TAILSCALE_IP}"
echo "============================================"
echo ""

# ---- Kiểm tra Tailscale ----
if ! tailscale status &>/dev/null; then
    echo "ERROR: Tailscale chưa chạy. Hãy chạy 'sudo tailscale up' trước."
    exit 1
fi
echo "[OK] Tailscale đang kết nối."

# ----- Step 1: Kernel modules -----
echo ""
echo "[1/8] Loading kernel modules..."
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
echo "[OK] Kernel modules loaded."

# ----- Step 2: Sysctl params -----
echo ""
echo "[2/8] Configuring sysctl..."
cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system > /dev/null 2>&1
echo "[OK] Sysctl configured."

# ----- Step 3: Disable swap -----
echo ""
echo "[3/8] Disabling swap..."
swapoff -a
# Comment out swap entries trong fstab
sed -i '/\sswap\s/s/^/#/' /etc/fstab
# Verify
if [[ $(swapon --show | wc -l) -eq 0 ]]; then
    echo "[OK] Swap completely disabled."
else
    echo "[WARN] Swap vẫn còn, reboot lại để tắt hoàn toàn."
fi

# ----- Step 4: AppArmor (Ubuntu mặc định, tương thích K8s) -----
echo ""
echo "[4/8] Checking AppArmor..."
# Ubuntu dùng AppArmor mặc định thay vì SELinux.
# containerd và kubelet đều tương thích tốt với AppArmor, không cần chỉnh.
if systemctl is-active --quiet apparmor 2>/dev/null; then
    echo "[OK] AppArmor đang chạy (mặc định Ubuntu, tương thích K8s)."
else
    echo "[SKIP] AppArmor không chạy, bỏ qua."
fi

# ----- Step 5: Install containerd -----
echo ""
echo "[5/8] Installing containerd..."
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg

# Thêm Docker official GPG key & repository (để lấy containerd.io mới nhất)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null

apt-get update -qq
apt-get install -y -qq containerd.io

# Tạo config mặc định và bật SystemdCgroup (bắt buộc cho kubeadm)
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl daemon-reload
systemctl enable --now containerd
systemctl restart containerd
sleep 2

# Verify CRI đang hoạt động
if crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock info &>/dev/null; then
    echo "[OK] containerd installed, running, CRI OK."
else
    echo "[ERROR] containerd CRI không phản hồi! Kiểm tra: crictl info"
    exit 1
fi

# ----- Step 5b: CNI plugins -----
echo ""
echo "[5b] Setting up CNI plugins..."
mkdir -p /opt/cni/bin
curl -fsSL "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz" \
    | tar -C /opt/cni/bin -xz

if [[ -f /opt/cni/bin/loopback ]]; then
    echo "[OK] CNI plugins available at /opt/cni/bin/."
else
    echo "[ERROR] CNI plugins not found! CoreDNS sẽ không start được."
    exit 1
fi

# ----- Step 6: Install kubeadm, kubelet, kubectl -----
echo ""
echo "[6/8] Installing kubeadm, kubelet, kubectl..."
apt-get install -y -qq apt-transport-https gpg

mkdir -p /etc/apt/keyrings
curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" | \
    tee /etc/apt/sources.list.d/kubernetes.list > /dev/null

apt-get update -qq
apt-get install -y -qq kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

systemctl enable kubelet
echo "[OK] kubeadm $(kubeadm version -o short), kubectl, kubelet installed."

# ----- Step 7: Firewall rules -----
echo ""
echo "[7/8] Configuring firewall..."
if command -v ufw &>/dev/null; then
    # Bật ufw nếu chưa bật
    ufw --force enable 2>/dev/null || true

    # Control plane ports
    ufw allow 6443/tcp comment "K8s API server"
    ufw allow 2379:2380/tcp comment "etcd"
    ufw allow 10250/tcp comment "kubelet API"
    ufw allow 10259/tcp comment "kube-scheduler"
    ufw allow 10257/tcp comment "kube-controller-manager"
    ufw allow 8472/udp comment "Flannel VXLAN"

    # Trust traffic từ Tailscale interface
    ufw allow in on tailscale0 comment "Tailscale traffic"

    # Trust Pod network
    ufw allow from ${POD_CIDR} comment "K8s Pod network"

    ufw reload
    echo "[OK] Firewall (ufw) configured."
else
    echo "[SKIP] ufw không có sẵn, bỏ qua."
fi

# ----- Step 8: Cấu hình kubelet dùng Tailscale IP -----
echo ""
echo "[8/8] Configuring kubelet for Tailscale IP..."
mkdir -p /etc/default
echo "KUBELET_EXTRA_ARGS=--node-ip=${TAILSCALE_IP}" > /etc/default/kubelet

mkdir -p /etc/systemd/system/kubelet.service.d
cat <<EOF > /etc/systemd/system/kubelet.service.d/20-tailscale.conf
[Service]
Environment="KUBELET_EXTRA_ARGS=--node-ip=${TAILSCALE_IP}"
EOF
systemctl daemon-reload

echo ""
echo "============================================"
echo " [DONE] Prerequisites installed!"
echo ""
echo " Tiếp theo chạy:"
echo "   sudo bash 02-init-cluster.sh"
echo "============================================"
