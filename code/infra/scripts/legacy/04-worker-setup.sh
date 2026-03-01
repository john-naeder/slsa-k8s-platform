#!/usr/bin/env bash
###############################################################################
#  04-worker-setup.sh
#  Script tổng hợp: cài đặt Ubuntu Server 24.04 thành Kubernetes Worker Node
#  Kết nối vào cluster qua Tailscale VPN
#
#  Môi trường:
#    - Ubuntu Server 24.04
#    - Control plane: Ubuntu Server (Tailscale IP 100.95.126.102)
#    - K8s version:   v1.32.x
#
#  Cách dùng:
#    chmod +x 04-worker-setup.sh
#    sudo ./04-worker-setup.sh              # Chạy full (mặc định)
#    sudo ./04-worker-setup.sh --step N     # Chạy từ bước N
#    sudo ./04-worker-setup.sh --join-only  # Chỉ chạy bước join (5-6)
#
#  LƯU Ý: Script cần chạy bằng sudo (hoặc root).
#          Bước Tailscale login cần tương tác thủ công.
###############################################################################
set -euo pipefail

# ============================ CẤU HÌNH ======================================
CONTROL_PLANE_TS_IP="100.95.126.102"   # Tailscale IP của control plane
CONTROL_PLANE_PORT="6443"
WORKER_NODE_NAME="$(hostname)"         # Tên node worker (dùng hostname)
K8S_VERSION="1.32"                     # Major.Minor version
CNI_VERSION="v1.6.2"                   # CNI plugins version
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
step() { echo -e "\n${CYAN}${BOLD}========== BƯỚC $1: $2 ==========${NC}\n"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Script này cần chạy bằng sudo hoặc root."
        echo "  sudo $0 $*"
        exit 1
    fi
}

# ============================================================================
# BƯỚC 1: Cài đặt và kết nối Tailscale
# ============================================================================
step1_tailscale() {
    step 1 "Cài đặt và kết nối Tailscale"

    # Cài Tailscale nếu chưa có
    if ! command -v tailscale &>/dev/null; then
        log "Cài đặt Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
    else
        log "Tailscale đã được cài"
    fi

    # Bật tailscaled service
    systemctl enable --now tailscaled 2>/dev/null || true

    # Kiểm tra trạng thái kết nối
    if ! tailscale status &>/dev/null; then
        warn "Tailscale chưa kết nối. Đang khởi động..."
        echo -e "${YELLOW}  >>> Nếu hiện link đăng nhập, hãy mở link đó trong trình duyệt <<<${NC}"
        tailscale up
    fi

    WORKER_TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
    if [[ -z "$WORKER_TS_IP" ]]; then
        err "Không lấy được Tailscale IP. Kiểm tra lại kết nối Tailscale."
        exit 1
    fi
    log "Tailscale IP của worker: ${BOLD}$WORKER_TS_IP${NC}"

    # Test kết nối tới control plane
    log "Kiểm tra kết nối tới control plane ($CONTROL_PLANE_TS_IP)..."
    if ping -c 2 -W 3 "$CONTROL_PLANE_TS_IP" &>/dev/null; then
        log "Ping tới control plane: OK"
    else
        warn "Không ping được control plane. Kiểm tra Tailscale trên cả 2 máy."
    fi

    if nc -zw3 "$CONTROL_PLANE_TS_IP" "$CONTROL_PLANE_PORT" 2>/dev/null; then
        log "Port $CONTROL_PLANE_PORT trên control plane: OK"
    else
        warn "Không kết nối được port $CONTROL_PLANE_PORT. API server có thể chưa chạy."
    fi
}

# ============================================================================
# BƯỚC 2: Tắt swap + Kernel modules + sysctl
# ============================================================================
step2_prerequisites() {
    step 2 "Tắt swap, cấu hình kernel modules & sysctl"

    # -- Tắt swap --
    swapoff -a 2>/dev/null || true
    sed -i '/\sswap\s/s/^/#/' /etc/fstab

    if [[ $(swapon --show | wc -l) -eq 0 ]]; then
        log "Swap đã tắt"
    else
        warn "Swap có thể vẫn đang bật. Reboot để tắt hoàn toàn."
    fi

    # -- Kernel modules --
    modprobe overlay
    modprobe br_netfilter

    cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

    # -- Sysctl params --
    cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
    sysctl --system &>/dev/null

    if [[ $(sysctl -n net.ipv4.ip_forward 2>/dev/null) == "1" ]]; then
        log "ip_forward = 1: OK"
    else
        warn "ip_forward chưa được bật"
    fi
    log "Kernel modules & sysctl đã cấu hình"
}

# ============================================================================
# BƯỚC 3: Cài đặt & cấu hình containerd
# ============================================================================
step3_containerd() {
    step 3 "Cài đặt & cấu hình containerd"

    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg

    # Thêm Docker official GPG key & repository
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${VERSION_CODENAME}") stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    apt-get install -y -qq containerd.io

    # Tạo config mặc định và bật SystemdCgroup
    mkdir -p /etc/containerd
    containerd config default > /etc/containerd/config.toml
    sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

    systemctl daemon-reload
    systemctl enable --now containerd
    systemctl restart containerd
    sleep 2

    if systemctl is-active --quiet containerd; then
        log "containerd đang chạy"
    else
        err "containerd không khởi động được!"
        journalctl -u containerd --no-pager | tail -10
        exit 1
    fi

    # Verify CRI đang hoạt động (containerd 2.x cần restart sau khi đổi config)
    if crictl --runtime-endpoint unix:///var/run/containerd/containerd.sock info &>/dev/null; then
        log "CRI runtime: OK (SystemdCgroup = true)"
    else
        err "CRI không phản hồi! Chạy: crictl info để debug"
        exit 1
    fi
}

# ============================================================================
# BƯỚC 4: Cài kubeadm, kubelet, kubectl + CNI plugins
# ============================================================================
step4_install_k8s() {
    step 4 "Cài đặt kubeadm, kubelet, kubectl, CNI plugins"

    # -- kubeadm, kubelet, kubectl --
    if command -v kubeadm &>/dev/null && command -v kubelet &>/dev/null; then
        log "kubeadm & kubelet đã được cài ($(kubeadm version -o short 2>/dev/null))"
    else
        log "Cài đặt kubeadm, kubelet, kubectl..."
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
        log "kubeadm $(kubeadm version -o short 2>/dev/null), kubectl, kubelet installed"
    fi
    systemctl enable kubelet 2>/dev/null || true

    # -- CNI plugins --
    if [[ -f /opt/cni/bin/loopback ]]; then
        log "CNI plugins đã có tại /opt/cni/bin/"
    else
        log "Cài đặt CNI plugins ${CNI_VERSION}..."
        mkdir -p /opt/cni/bin
        curl -fsSL "https://github.com/containernetworking/plugins/releases/download/${CNI_VERSION}/cni-plugins-linux-amd64-${CNI_VERSION}.tgz" \
            | tar -C /opt/cni/bin -xz
        log "CNI plugins đã cài"
    fi

    # -- Firewall (nếu ufw đang bật) --
    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        log "Cấu hình ufw cho worker node..."
        ufw allow 10250/tcp comment "kubelet API"
        ufw allow 10256/tcp comment "kube-proxy healthz"
        ufw allow 30000:32767/tcp comment "NodePort Services"
        ufw allow 8472/udp comment "Flannel VXLAN"
        ufw allow in on tailscale0 comment "Tailscale traffic"
        ufw reload
        log "Firewall (ufw) configured"
    fi
}

# ============================================================================
# BƯỚC 5: Cấu hình kubelet với Tailscale IP + Join cluster
# ============================================================================
step5_configure_and_join() {
    step 5 "Cấu hình kubelet & Join cluster"

    WORKER_TS_IP=$(tailscale ip -4 2>/dev/null || echo "")
    if [[ -z "$WORKER_TS_IP" ]]; then
        err "Không lấy được Tailscale IP!"
        exit 1
    fi
    log "Worker Tailscale IP: $WORKER_TS_IP"

    # -- Cấu hình kubelet node-ip --
    echo "KUBELET_EXTRA_ARGS=--node-ip=${WORKER_TS_IP}" > /etc/default/kubelet

    mkdir -p /etc/systemd/system/kubelet.service.d
    cat > /etc/systemd/system/kubelet.service.d/20-tailscale.conf <<EOF
[Service]
Environment="KUBELET_EXTRA_ARGS=--node-ip=${WORKER_TS_IP}"
EOF
    systemctl daemon-reload
    log "Đã cấu hình kubelet --node-ip=${WORKER_TS_IP}"

    # -- Reset trước khi join (để đảm bảo sạch) --
    log "Reset kubeadm (nếu có cấu hình cũ)..."
    kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock 2>/dev/null || true
    rm -rf /etc/cni/net.d 2>/dev/null || true

    # Flush iptables cũ
    iptables -F 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -t mangle -F 2>/dev/null || true

    # -- Lấy join command --
    echo ""
    echo -e "${CYAN}${BOLD}Bạn cần join command từ control plane.${NC}"
    echo -e "Trên control plane (${CONTROL_PLANE_TS_IP}), chạy:"
    echo -e "  ${BOLD}sudo kubeadm token create --print-join-command${NC}"
    echo ""
    read -rp "Paste lệnh kubeadm join ở đây (hoặc nhấn Enter để nhập từng phần): " JOIN_CMD

    if [[ -z "$JOIN_CMD" ]]; then
        read -rp "Token: " JOIN_TOKEN
        read -rp "Discovery token CA cert hash (sha256:...): " JOIN_HASH
        JOIN_CMD="kubeadm join ${CONTROL_PLANE_TS_IP}:${CONTROL_PLANE_PORT} --token ${JOIN_TOKEN} --discovery-token-ca-cert-hash ${JOIN_HASH}"
    fi

    # Thêm --node-name nếu chưa có
    if [[ "$JOIN_CMD" != *"--node-name"* ]]; then
        JOIN_CMD="$JOIN_CMD --node-name ${WORKER_NODE_NAME}"
    fi

    # Đảm bảo lệnh chạy không có sudo prefix thừa
    JOIN_CMD="${JOIN_CMD#sudo }"

    log "Chạy join command..."
    echo -e "  ${BOLD}$JOIN_CMD${NC}"
    echo ""

    eval "$JOIN_CMD"

    if [[ $? -eq 0 ]]; then
        log "Join cluster thành công!"
    else
        err "Join thất bại. Kiểm tra log:"
        echo "  journalctl -xeu kubelet --no-pager | tail -30"
        exit 1
    fi
}

# ============================================================================
# BƯỚC 6: Post-join - Patch kubelet node-ip & Verify
# ============================================================================
step6_post_join_verify() {
    step 6 "Post-join: Patch node-ip & Verify"

    WORKER_TS_IP=$(tailscale ip -4 2>/dev/null || echo "")

    # kubeadm join ghi đè kubeadm-flags.env, nên cần patch lại node-ip
    KUBEADM_FLAGS="/var/lib/kubelet/kubeadm-flags.env"
    if [[ -f "$KUBEADM_FLAGS" ]]; then
        if ! grep -q "node-ip" "$KUBEADM_FLAGS"; then
            sed -i 's|"$| --node-ip='"${WORKER_TS_IP}"'"|' "$KUBEADM_FLAGS"
            log "Đã patch --node-ip vào kubeadm-flags.env"
        else
            log "kubeadm-flags.env đã có --node-ip"
        fi
    fi

    # Restart kubelet
    systemctl daemon-reload
    systemctl restart kubelet
    sleep 5

    # Verify kubelet
    if systemctl is-active --quiet kubelet; then
        log "kubelet đang chạy: OK"
    else
        warn "kubelet chưa active. Có thể cần vài giây..."
        sleep 10
        if systemctl is-active --quiet kubelet; then
            log "kubelet đã khởi động"
        else
            err "kubelet vẫn không chạy. Kiểm tra:"
            echo "  systemctl status kubelet"
            echo "  journalctl -xeu kubelet --no-pager | tail -30"
        fi
    fi

    echo ""
    log "${BOLD}=== HOÀN TẤT ===${NC}"
    echo ""
    echo -e "  Worker node: ${BOLD}${WORKER_NODE_NAME}${NC}"
    echo -e "  Tailscale IP: ${BOLD}${WORKER_TS_IP}${NC}"
    echo ""
    echo -e "  ${CYAN}Trên control plane, kiểm tra:${NC}"
    echo -e "    ${BOLD}kubectl get nodes -o wide${NC}"
    echo ""
    echo -e "  Kết quả mong đợi:"
    echo -e "    ${WORKER_NODE_NAME}   Ready   <none>   ...   ${WORKER_TS_IP}"
    echo ""
    echo -e "  ${YELLOW}Nếu node ở NotReady, đợi 1-2 phút để CNI (Flannel)${NC}"
    echo -e "  ${YELLOW}được deploy. Kiểm tra: kubectl get pods -A${NC}"
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    check_root "$@"

    echo -e "${BOLD}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  K8s Worker Node Setup - Ubuntu Server 24.04               ║"
    echo "║  Control Plane: $CONTROL_PLANE_TS_IP (Tailscale)            ║"
    echo "║  Worker Node:   ${WORKER_NODE_NAME}                         "
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    START_STEP=1

    case "${1:-}" in
        --step)
            START_STEP="${2:-1}"
            ;;
        --join-only)
            START_STEP=5
            ;;
        --help|-h)
            echo "Cách dùng:"
            echo "  sudo $0              # Chạy toàn bộ (bước 1-6)"
            echo "  sudo $0 --step N     # Chạy từ bước N"
            echo "  sudo $0 --join-only  # Chỉ chạy bước join (5-6)"
            echo ""
            echo "Các bước:"
            echo "  1  Cài đặt & kết nối Tailscale"
            echo "  2  Tắt swap, kernel modules, sysctl"
            echo "  3  Cài đặt & cấu hình containerd"
            echo "  4  Cài kubeadm, kubelet, kubectl, CNI plugins"
            echo "  5  Cấu hình kubelet & Join cluster"
            echo "  6  Post-join verify"
            exit 0
            ;;
    esac

    [[ $START_STEP -le 1 ]] && step1_tailscale
    [[ $START_STEP -le 2 ]] && step2_prerequisites
    [[ $START_STEP -le 3 ]] && step3_containerd
    [[ $START_STEP -le 4 ]] && step4_install_k8s
    [[ $START_STEP -le 5 ]] && step5_configure_and_join
    [[ $START_STEP -le 6 ]] && step6_post_join_verify
}

main "$@"
