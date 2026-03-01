#!/bin/bash
# ============================================================
# Script 2/3: K8s Cluster Init - Control Plane with Tailscale
#
# Chạy bằng: sudo bash 02-init-cluster.sh
#
# Script này:
#   - Pull K8s images
#   - Init cluster với API server advertise trên Tailscale IP
#   - Setup kubeconfig cho user hiện tại
#   - Patch kubelet --node-ip vào kubeadm-flags.env
#   - Lưu join command cho worker
# ============================================================
set -euo pipefail

TAILSCALE_IP="100.95.126.102"
POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.95.0.0/12"
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~${REAL_USER}")
NODE_NAME=$(hostname)

echo "============================================"
echo " Initializing K8s Cluster (Ubuntu Server)"
echo " API Server advertise: ${TAILSCALE_IP}"
echo " Node name: ${NODE_NAME}"
echo " User: ${REAL_USER}"
echo "============================================"
echo ""

# ---- Pre-flight checks ----
if ! systemctl is-active --quiet containerd; then
    echo "ERROR: containerd chưa chạy. Chạy 01-control-plane-setup.sh trước."
    exit 1
fi

if ! tailscale status &>/dev/null; then
    echo "ERROR: Tailscale chưa kết nối."
    exit 1
fi

if [[ $(swapon --show | wc -l) -gt 0 ]]; then
    echo "ERROR: Swap vẫn đang bật. Chạy: swapoff -a"
    exit 1
fi

# Nếu cluster đã tồn tại, hỏi reset
if [[ -f /etc/kubernetes/admin.conf ]]; then
    echo "WARN: Cluster đã tồn tại. Reset trước khi init lại..."
    kubeadm reset -f
    rm -rf /etc/cni/net.d
    iptables -F && iptables -t nat -F
    rm -f "${REAL_HOME}/.kube/config"
fi

# ---- Step 1: Pull images ----
echo "[1/4] Pre-pulling K8s images..."
kubeadm config images pull

# ---- Step 2: Init cluster ----
echo ""
echo "[2/4] Initializing cluster..."
kubeadm init \
    --apiserver-advertise-address="${TAILSCALE_IP}" \
    --apiserver-cert-extra-sans="${TAILSCALE_IP},${NODE_NAME}" \
    --pod-network-cidr="${POD_CIDR}" \
    --service-cidr="${SERVICE_CIDR}" \
    --node-name="${NODE_NAME}" \
    --upload-certs \
    2>&1 | tee /tmp/kubeadm-init.log

# ---- Step 3: Setup kubeconfig ----
echo ""
echo "[3/4] Setting up kubeconfig for user '${REAL_USER}'..."
mkdir -p "${REAL_HOME}/.kube"
cp -f /etc/kubernetes/admin.conf "${REAL_HOME}/.kube/config"
chown "$(id -u "${REAL_USER}"):$(id -g "${REAL_USER}")" "${REAL_HOME}/.kube/config"

# ---- Step 4: Patch kubelet --node-ip ----
# kubeadm init ghi đè /var/lib/kubelet/kubeadm-flags.env mà KHÔNG bao gồm --node-ip
# nên phải patch thủ công vào đây
echo ""
echo "[4/4] Patching kubelet --node-ip=${TAILSCALE_IP}..."
KUBEADM_FLAGS="/var/lib/kubelet/kubeadm-flags.env"
if [[ -f "${KUBEADM_FLAGS}" ]]; then
    # Thêm --node-ip vào cuối args string
    sed -i "s|\"$| --node-ip=${TAILSCALE_IP}\"|" "${KUBEADM_FLAGS}"
    systemctl daemon-reload
    systemctl restart kubelet
    sleep 3
    echo "[OK] kubelet restarted with --node-ip=${TAILSCALE_IP}"
else
    echo "[WARN] ${KUBEADM_FLAGS} not found, kubelet node-ip might not be set."
fi

# ---- Save join command ----
echo ""
echo "--- Worker Join Command ---"
kubeadm token create --print-join-command | tee /tmp/k8s-join-command.sh
echo ""
echo "============================================"
echo " [DONE] Cluster initialized!"
echo ""
echo " Join command saved to: /tmp/k8s-join-command.sh"
echo ""
echo " Tiếp theo chạy:"
echo "   bash 03-install-cni.sh   (KHÔNG cần sudo)"
echo "============================================"
