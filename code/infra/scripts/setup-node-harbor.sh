#!/usr/bin/env bash
# =============================================================================
# setup-node-harbor.sh — Configure Harbor access on K8s nodes
# =============================================================================
#
# Run this script with sudo on EVERY node in the cluster:
#   sudo bash setup-node-harbor.sh
#
# What it does:
#   1. Adds Harbor DNS entry to /etc/hosts (ClusterIP resolution)
#   2. Configures containerd to trust Harbor's self-signed cert
#   3. Restarts containerd to apply changes
#
# =============================================================================
set -euo pipefail

HARBOR_DOMAIN="harbor.kythuat.vn"
HARBOR_CLUSTER_IP="10.90.192.186"
CONTAINERD_CERTS_DIR="/etc/containerd/certs.d/${HARBOR_DOMAIN}"

echo "══════════════════════════════════════════════"
echo "  Harbor Node Configuration"
echo "══════════════════════════════════════════════"

# ── Step 1: /etc/hosts entry ──
if grep -q "${HARBOR_DOMAIN}" /etc/hosts; then
  echo "✅ /etc/hosts already has ${HARBOR_DOMAIN}"
else
  echo "${HARBOR_CLUSTER_IP} ${HARBOR_DOMAIN}" >> /etc/hosts
  echo "✅ Added ${HARBOR_CLUSTER_IP} ${HARBOR_DOMAIN} to /etc/hosts"
fi

# ── Step 2: containerd registry config ──
mkdir -p "${CONTAINERD_CERTS_DIR}"
cat > "${CONTAINERD_CERTS_DIR}/hosts.toml" << EOF
server = "https://${HARBOR_DOMAIN}"

[host."https://${HARBOR_DOMAIN}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF
echo "✅ Created containerd registry config at ${CONTAINERD_CERTS_DIR}/hosts.toml"

# ── Step 3: Restart containerd ──
echo "🔄 Restarting containerd..."
systemctl restart containerd
echo "✅ containerd restarted"

# ── Verify ──
echo ""
echo "🔍 Verification:"
echo "  DNS: $(getent hosts ${HARBOR_DOMAIN} 2>/dev/null || echo 'FAILED')"
echo "  containerd: $(systemctl is-active containerd)"
echo ""
echo "══════════════════════════════════════════════"
echo "  Done! Run on the next node."
echo "══════════════════════════════════════════════"
