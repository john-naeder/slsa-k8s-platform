#!/bin/bash
# ============================================================
# Script 3/3: Install Flannel CNI + Verify Cluster
#
# Chạy bằng: bash 03-install-cni.sh   (KHÔNG cần sudo)
#
# Script này:
#   - Cài Flannel CNI
#   - Patch Flannel dùng interface tailscale0
#   - Chờ tất cả pods Ready
#   - Verify cluster status
# ============================================================
set -euo pipefail

TAILSCALE_IP="100.95.126.102"
NODE_NAME=$(hostname)

echo "============================================"
echo " Installing Flannel CNI + Final Verification"
echo "============================================"
echo ""

# ---- Pre-flight ----
if ! kubectl cluster-info &>/dev/null 2>&1; then
    echo "ERROR: Không kết nối được cluster."
    echo "Đã chạy 02-init-cluster.sh chưa? Đã setup ~/.kube/config chưa?"
    exit 1
fi

# ---- Step 1: Install Flannel ----
echo "[1/3] Installing Flannel..."
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# ---- Step 2: Patch dùng tailscale0 ----
echo ""
echo "[2/3] Patching Flannel to use tailscale0 interface..."
kubectl -n kube-flannel patch daemonset kube-flannel-ds \
    --type='json' \
    -p='[
      {
        "op": "add",
        "path": "/spec/template/spec/containers/0/args/-",
        "value": "--iface=tailscale0"
      }
    ]'

echo ""
echo "Waiting for Flannel rollout..."
kubectl -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout=120s || true

# ---- Step 3: Wait & Verify ----
echo ""
echo "[3/3] Waiting for all system pods..."
sleep 10

# Chờ CoreDNS ready (tối đa 2 phút)
echo "Waiting for CoreDNS..."
kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=kube-dns --timeout=120s 2>/dev/null || true

echo ""
echo "========== CLUSTER STATUS =========="
echo ""
echo "--- Nodes ---"
kubectl get nodes -o wide
echo ""
echo "--- All Pods ---"
kubectl get pods -A
echo ""

# Kiểm tra INTERNAL-IP có đúng Tailscale hay không
NODE_IP=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
if [[ "${NODE_IP}" == "${TAILSCALE_IP}" ]]; then
    echo "[OK] Node IP = ${NODE_IP} (Tailscale)"
else
    echo "[WARN] Node IP = ${NODE_IP} (không phải Tailscale IP ${TAILSCALE_IP}!)"
    echo "       Kiểm tra /var/lib/kubelet/kubeadm-flags.env có --node-ip không."
fi

echo ""
echo "============================================"
echo " [DONE] Control Plane hoàn tất!"
echo ""
echo " Để join worker node, trên máy worker chạy:"
echo ""
cat /tmp/k8s-join-command.sh 2>/dev/null || echo " (Chạy trên control plane: sudo kubeadm token create --print-join-command)"
echo ""
echo "============================================"
