# 07 — Verification Checklist

> Verify toàn bộ hệ thống sau khi setup xong (hoặc sau khi recreate).

## Phase 0: Infrastructure Foundation

### Tailscale VPN
```bash
tailscale status
# Tất cả nodes hiển thị "active"
# userver-master: 100.95.126.102
# userver-home-worker: 100.94.203.28
```

- [ ] Tất cả nodes online trên tailnet
- [ ] Ping giữa các nodes thành công: `ping 100.95.126.102` từ worker

### K8s Cluster
```bash
kubectl get nodes -o wide
```
- [ ] Tất cả nodes STATUS = `Ready`
- [ ] INTERNAL-IP = Tailscale IP (100.x.x.x)
- [ ] VERSION = v1.32.x

### System Pods
```bash
kubectl get pods -n kube-system
```
- [ ] coredns: 2/2 Running
- [ ] etcd: Running
- [ ] kube-apiserver: Running
- [ ] kube-controller-manager: Running
- [ ] kube-proxy: Running (on each node)
- [ ] kube-scheduler: Running

### Flannel CNI
```bash
kubectl get pods -n kube-flannel
kubectl -n kube-flannel get ds kube-flannel-ds -o jsonpath='{.spec.template.spec.containers[0].args}'
```
- [ ] kube-flannel-ds pods Running on each node
- [ ] Args contain `--iface=tailscale0`

---

## Phase 1: Platform Bootstrap (Helmfile)

```bash
helmfile -f code/infra/helmfile/helmfile-bootstrap.yaml list
```

### cert-manager
```bash
kubectl get pods -n cert-manager
kubectl get crds | grep cert-manager
```
- [ ] 3 pods Running: controller, webhook, cainjector
- [ ] CRDs created: certificates, issuers, clusterissuers, etc.

### Traefik
```bash
kubectl get pods -n traefik
kubectl get svc -n traefik
kubectl get crds | grep traefik
```
- [ ] Traefik pod Running
- [ ] Service type = ClusterIP
- [ ] CRDs: IngressRoute, Middleware, etc.

### Sealed Secrets
```bash
kubectl get pods -n sealed-secrets
```
- [ ] sealed-secrets-controller Running

### ArgoCD
```bash
kubectl get pods -n argocd
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```
- [ ] 5+ pods Running: server, controller, repo-server, redis, applicationset
- [ ] Admin password retrievable

---

## Phase 2: Post-Bootstrap

### Local Path Provisioner
```bash
kubectl get storageclass
kubectl get pods -n local-path-storage
```
- [ ] `local-path` StorageClass exists (default)
- [ ] Provisioner pod Running

### Cloudflare Tunnel
```bash
kubectl -n cloudflare get pods
kubectl -n cloudflare logs deploy/cloudflared | grep "Connection"
```
- [ ] cloudflared pod Running
- [ ] Logs show "Connection registered" at SIN (or other edge)

### ClusterIssuer
```bash
kubectl get clusterissuer
```
- [ ] letsencrypt-prod: Ready = True
- [ ] letsencrypt-staging: Ready = True

---

## Phase 3: ArgoCD & GitOps

### Repository Connection
```bash
kubectl -n argocd get secret repo-slsa-k8s-platform
```
- [ ] SSH deploy key secret exists
- [ ] ArgoCD UI → Settings → Repositories → Connected ✅

### App-of-Apps
```bash
kubectl get applications -n argocd
```
- [ ] platform-apps: Synced
- [ ] strimzi-operator: Synced (hoặc Progressing)
- [ ] kafka-cluster: Synced
- [ ] kyverno: Synced
- [ ] monitoring: Synced
- [ ] logging: Synced
- [ ] harbor: Synced
- [ ] demo-api: Synced (hoặc Missing nếu chưa có source code)
- [ ] demo-worker: Synced (hoặc Missing nếu chưa có source code)

---

## Phase 4: Networking & Access

### ArgoCD via Tailscale (NodePort)
```bash
curl -sI http://100.94.203.28:30080
```
- [ ] HTTP 200

### ArgoCD via Cloudflare Tunnel
```bash
curl -sI https://argocd.kythuat.vn
```
- [ ] HTTP/2 200
- [ ] `server: cloudflare`
- [ ] `cf-ray: xxxxx-SIN`
- [ ] Security headers present (X-Frame-Options, HSTS, etc.)

### Cloudflare Tunnel Route
```bash
dig +short argocd.kythuat.vn
```
- [ ] Returns Cloudflare proxy IPs

### In-cluster routing test (optional)
```bash
kubectl run test-curl --image=curlimages/curl --rm -it -- \
  curl -sI -H "Host: argocd.kythuat.vn" http://traefik.traefik.svc.cluster.local
```
- [ ] HTTP 200 với security headers

### Zero Trust Access (nếu đã cấu hình)
- [ ] Truy cập `https://argocd.kythuat.vn` → hiện trang Cloudflare Access login
- [ ] Nhập email → nhận OTP → verify → forward tới ArgoCD login

---

## Quick Health Check Script

```bash
#!/bin/bash
echo "=== Nodes ==="
kubectl get nodes -o wide

echo ""
echo "=== Helmfile Releases ==="
cd code/infra/helmfile && helmfile -f helmfile-bootstrap.yaml list 2>/dev/null || echo "helmfile not available"

echo ""
echo "=== ArgoCD Applications ==="
kubectl get applications -n argocd 2>/dev/null || echo "ArgoCD not installed"

echo ""
echo "=== All Pods (non-Running) ==="
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null

echo ""
echo "=== Storage ==="
kubectl get storageclass

echo ""
echo "=== Cloudflare Tunnel ==="
kubectl -n cloudflare get pods 2>/dev/null || echo "cloudflared not deployed"

echo ""
echo "=== External Access ==="
curl -so /dev/null -w "ArgoCD Tailscale  : HTTP %{http_code}\n" http://100.94.203.28:30080 2>/dev/null
curl -so /dev/null -w "ArgoCD Cloudflare : HTTP %{http_code}\n" https://argocd.kythuat.vn 2>/dev/null
```
