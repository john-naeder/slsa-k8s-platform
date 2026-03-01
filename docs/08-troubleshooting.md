# 08 — Troubleshooting

> Lỗi thường gặp và cách xử lý khi setup hoặc recreate platform.

---

## Ansible / K8s Provisioning

### 1. Ansible "UNREACHABLE" — SSH fail qua Tailscale

**Triệu chứng:**
```
fatal: [userver-master]: UNREACHABLE!
```

**Nguyên nhân:** Node offline trên tailnet, hoặc SSH key chưa copy.

**Fix:**
```bash
# Kiểm tra Tailscale
tailscale status | grep userver-master
# Nếu offline → SSH vào node qua LAN và: sudo tailscale up

# Test SSH thủ công
ssh -i ~/.ssh/id_ed25519 john@100.95.126.102

# Copy lại SSH key nếu cần
ssh-copy-id -i ~/.ssh/id_ed25519.pub john@100.95.126.102
```

### 2. kubeadm init fail — "port already in use"

**Nguyên nhân:** Cluster cũ chưa được reset.

**Fix:**
```bash
cd code/infra/ansible/
make reset     # Reset tất cả nodes
make master    # Re-init master
```

### 3. Flannel pods CrashLoopBackOff

**Nguyên nhân:** Flannel không tìm thấy `tailscale0` interface.

**Fix:**
```bash
# Kiểm tra interface trên node
ssh john@100.95.126.102 "ip link | grep tailscale"

# Kiểm tra Flannel DaemonSet args
kubectl -n kube-flannel get ds kube-flannel-ds -o yaml | grep -A5 containers

# Nếu thiếu --iface=tailscale0, patch thủ công:
kubectl -n kube-flannel patch daemonset kube-flannel-ds --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--iface=tailscale0"}]'
```

### 4. CoreDNS Pending — CNI not ready

**Nguyên nhân:** CNI plugins chưa cài, hoặc Flannel chưa deploy.

**Fix:**
```bash
# Kiểm tra CNI plugins
ssh john@100.95.126.102 "ls /opt/cni/bin/"

# Kiểm tra Flannel
kubectl get pods -n kube-flannel
```

### 5. Worker node NotReady

**Nguyên nhân:** kubelet không advertise đúng IP, hoặc firewall block.

**Fix:**
```bash
# Kiểm tra kubelet trên worker
ssh john@100.94.203.28 "systemctl status kubelet"
ssh john@100.94.203.28 "journalctl -u kubelet --no-pager -n 50"

# Kiểm tra node-ip trong kubelet args
ssh john@100.94.203.28 "cat /var/lib/kubelet/kubeadm-flags.env"
# Phải có: --node-ip=100.94.203.28

# Kiểm tra UFW
ssh john@100.94.203.28 "sudo ufw status"
```

---

## Helmfile / Helm

### 6. helmfile apply — "release already exists"

**Fix:**
```bash
# helmfile apply tự handle (idempotent). Nếu vẫn lỗi:
helmfile -f helmfile-bootstrap.yaml destroy
helmfile -f helmfile-bootstrap.yaml apply
```

### 7. Helm chart timeout — pod pending

**Nguyên nhân:** nodeSelector không match, hoặc insufficient resources.

**Fix:**
```bash
# Kiểm tra pending pods
kubectl get pods -A --field-selector=status.phase=Pending

# Describe pod để xem lý do
kubectl describe pod <pod-name> -n <namespace>

# Kiểm tra node labels
kubectl get nodes --show-labels

# Gán label nếu thiếu
kubectl label node userver-home-worker node-role=worker
kubectl label node userver-home-worker workload-type=heavy
```

---

## Cloudflare Tunnel

### 8. cloudflared pod CrashLoopBackOff

**Nguyên nhân:** Tunnel token sai hoặc hết hạn.

**Fix:**
```bash
# Kiểm tra logs
kubectl -n cloudflare logs deploy/cloudflared

# Nếu token lỗi → tạo lại
kubectl -n cloudflare delete secret cloudflared-token
kubectl -n cloudflare create secret generic cloudflared-token \
  --from-literal=tunnel-token=<NEW_TOKEN>

# Restart
kubectl -n cloudflare rollout restart deploy/cloudflared
```

### 9. setup-route.sh — "Authentication error"

**Nguyên nhân:** API token thiếu permission.

**Fix:**
- Vào [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens)
- Edit token → thêm permissions cần thiết:
  - Zone → DNS → Edit
  - Account → Cloudflare Tunnel → Edit
  - Account → Access: Apps and Policies → Edit (cho Zero Trust)

### 10. curl https://argocd.kythuat.vn — timeout

**Debug workflow:**
```bash
# 1. DNS resolve?
dig +short argocd.kythuat.vn
# Phải trả về Cloudflare IPs

# 2. Cloudflared pod running?
kubectl -n cloudflare get pods

# 3. Tunnel connections?
kubectl -n cloudflare logs deploy/cloudflared | grep "Connection"

# 4. Tunnel config đúng?
curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
  -H "Authorization: Bearer $CF_API_TOKEN" | python3 -m json.tool

# 5. Traefik routing OK? (test từ trong cluster)
kubectl run test --image=curlimages/curl --rm -it -- \
  curl -sI -H "Host: argocd.kythuat.vn" http://traefik.traefik.svc.cluster.local

# 6. ArgoCD pod running?
kubectl get pods -n argocd
```

### 11. setup-route.sh — "Duplicate catch-all entries"

**Nguyên nhân:** Bug trong filter logic (đã fix).

**Fix:** Dùng version mới nhất của script. Filter logic phải check `r.get('hostname')`:
```python
filtered = [r for r in existing if r.get('hostname') and r.get('hostname') != hostname]
```

---

## ArgoCD

### 12. ArgoCD Application stuck "Progressing"

**Nguyên nhân:** CRDs chưa có (ví dụ: Kafka CRDs cần Strimzi operator trước).

**Fix:**
```bash
# Check ArgoCD app status
kubectl get application <app-name> -n argocd -o yaml | grep -A10 status

# Manual sync
kubectl -n argocd patch application <app-name> --type=merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'

# Hoặc dùng ArgoCD CLI
argocd app sync <app-name>
```

### 13. ArgoCD "ComparisonError" — repository not accessible

**Nguyên nhân:** SSH deploy key chưa setup hoặc revoked.

**Fix:**
```bash
# Kiểm tra secret
kubectl -n argocd get secret repo-slsa-k8s-platform

# Tạo lại nếu cần
ssh-keygen -t ed25519 -C "argocd-deploy-key" -f /tmp/argocd-deploy-key -N ""
# → Thêm public key lên GitHub Settings → Deploy keys
kubectl -n argocd delete secret repo-slsa-k8s-platform
kubectl -n argocd create secret generic repo-slsa-k8s-platform \
  --from-file=sshPrivateKey=/tmp/argocd-deploy-key \
  --from-literal=type=git \
  --from-literal=url=git@github.com:john-naeder/slsa-k8s-platform.git
kubectl -n argocd label secret repo-slsa-k8s-platform argocd.argoproj.io/secret-type=repository
```

### 14. Quên ArgoCD admin password

```bash
# Lấy initial password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

# Nếu secret đã bị xóa → reset password
# Cách 1: Dùng argocd CLI
argocd account update-password --account admin --new-password <new-pass>

# Cách 2: Patch secret thủ công
NEW_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'new-password', bcrypt.gensalt()).decode())")
kubectl -n argocd patch secret argocd-secret -p "{\"stringData\":{\"admin.password\":\"${NEW_HASH}\"}}"
```

---

## General Tips

### Xem tất cả non-Running pods
```bash
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

### Xem events gần nhất
```bash
kubectl get events -A --sort-by=.lastTimestamp | tail -20
```

### Restart một deployment
```bash
kubectl -n <namespace> rollout restart deploy/<name>
```

### Full cluster reset + recreate
```bash
cd code/infra/ansible/
make reset

# Re-provision
make setup

# Re-bootstrap platform
cd ../helmfile/
kubectl label node userver-home-worker node-role=worker workload-type=heavy
helmfile -f helmfile-bootstrap.yaml apply

# Post-bootstrap (xem 04-post-bootstrap.md)
# ArgoCD setup (xem 05-argocd-gitops.md)
# Cloudflare (xem 06-cloudflare-networking.md)
```
