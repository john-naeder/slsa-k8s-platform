# ⚠️  DEPRECATED — Legacy Setup Scripts
#
# Các script trong thư mục này là phiên bản **thủ công** (pre-Ansible)
# của quá trình setup K8s cluster. Chúng được giữ lại để tham khảo.
#
# 👉  SỬ DỤNG ANSIBLE THAY THẾ:
#     cd code/infra/ansible
#     make setup-master   # hoặc make setup-worker
#
# Xem: code/infra/ansible/README.md

## Files

| Script | Mô tả |
|--------|--------|
| `01-control-plane-setup.sh` | Cài đặt containerd + kubeadm + kubelet (manual) |
| `02-init-cluster.sh` | kubeadm init cluster |
| `03-install-cni.sh` | Cài đặt Flannel CNI |
| `04-worker-setup.sh` | Setup worker node |
| `WORKER-SETUP.md` | Hướng dẫn join worker node (manual) |
