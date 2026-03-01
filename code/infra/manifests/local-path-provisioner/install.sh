#!/usr/bin/env bash
# =============================================================================
# Local Path Provisioner — Dynamic PV cho bare-metal K8s
# =============================================================================
# Rancher Local Path Provisioner cung cấp dynamic PersistentVolume
# trên bare-metal cluster bằng cách dùng local storage trên node.
#
# Usage:
#   chmod +x install.sh && ./install.sh
#
# Docs: https://github.com/rancher/local-path-provisioner
# =============================================================================
set -euo pipefail

LOCAL_PATH_VERSION="${LOCAL_PATH_VERSION:-v0.0.30}"
MANIFEST_URL="https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"

echo ">>> Installing Local Path Provisioner ${LOCAL_PATH_VERSION}..."
kubectl apply -f "${MANIFEST_URL}"

# Đặt làm default StorageClass (nếu chưa có default nào khác)
echo ">>> Setting local-path as default StorageClass..."
kubectl patch storageclass local-path \
  -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

echo ">>> Verifying..."
kubectl get storageclass
kubectl -n local-path-storage get pods

echo "✅ Local Path Provisioner installed successfully."
