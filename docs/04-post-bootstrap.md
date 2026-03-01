# 04 — Post-Bootstrap (Non-Helm Components)

> Sau khi Helmfile bootstrap xong, cài tiếp các component không dùng Helm chart.
> Bao gồm: local-path-provisioner, cloudflared, ClusterIssuer.

## Yêu cầu

- Helmfile bootstrap hoàn tất (Phase 03)
- cert-manager, Traefik, ArgoCD đang chạy

## 4.1 — Local Path Provisioner

Dynamic PersistentVolume cho bare-metal cluster (không có cloud storage).

```bash
# Cài từ script có sẵn
cd code/infra/manifests/local-path-provisioner/
chmod +x install.sh && ./install.sh

# Hoặc chạy thủ công
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml

# Set default StorageClass
kubectl patch storageclass local-path \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
```

**Verify:**
```bash
kubectl get storageclass       # local-path (default)
kubectl get pods -n local-path-storage

# Test PVC
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 100Mi
EOF
kubectl get pvc test-pvc       # STATUS: Bound
kubectl delete pvc test-pvc
```

## 4.2 — Cloudflare Tunnel (cloudflared)

Tạo outbound tunnel từ K8s cluster → Cloudflare edge. **Không cần public IP.**

### 4.2.1 — Tạo Tunnel trên Cloudflare Dashboard

1. Vào [Cloudflare Zero Trust](https://one.dash.cloudflare.com/)
2. Networks → Tunnels → **Create a tunnel**
3. Chọn **Cloudflared** connector
4. Copy tunnel token (dùng ở bước tiếp)

> **Tunnel ID hiện tại:** `3d402a26-0f5f-48af-a110-690ceb1c0302`

### 4.2.2 — Deploy cloudflared lên K8s

```bash
cd code/infra/manifests/cloudflared/

# 1. Tạo namespace
kubectl apply -f namespace.yaml

# 2. Tạo Secret chứa tunnel token
kubectl create secret generic cloudflared-token \
  --namespace=cloudflare \
  --from-literal=tunnel-token=<PASTE_TUNNEL_TOKEN_HERE>

# 3. Deploy cloudflared
kubectl apply -f deployment.yaml
```

**Verify:**
```bash
kubectl -n cloudflare get pods
# NAME                           READY   STATUS    RESTARTS   AGE
# cloudflared-xxxxx              1/1     Running   0          ...

kubectl -n cloudflare logs deploy/cloudflared | head -20
# INF Connection registered ... location=SIN
# INF Connection registered ... location=SIN
```

### 4.2.3 — Deployment manifest chi tiết

```yaml
# deployment.yaml (key settings)
image: cloudflare/cloudflared:2024.12.2
args:
  - tunnel
  - --no-autoupdate
  - --protocol http2      # Tối ưu cho Cloudflare edge
  - --metrics 0.0.0.0:2000
  - run
  - --token $(TUNNEL_TOKEN)
```

- Token đọc từ K8s Secret (KHÔNG hardcode trong YAML)
- Liveness/readiness probe: `GET /ready` port 2000
- Resources: 50m-200m CPU, 64-128Mi RAM

### GitOps-safe (Sealed Secrets)

```bash
# Tạo sealed secret thay vì plaintext
kubectl create secret generic cloudflared-token \
  --namespace=cloudflare \
  --from-literal=tunnel-token=<TOKEN> \
  --dry-run=client -o yaml | kubeseal -o yaml > sealed-secret.yaml

kubectl apply -f sealed-secret.yaml
```

## 4.3 — ClusterIssuer (Let's Encrypt)

Tạo ClusterIssuer cho cert-manager:

```bash
kubectl apply -f code/infra/manifests/cluster-issuer.yaml
```

File tạo 2 issuers:
- `letsencrypt-prod` — production certificates
- `letsencrypt-staging` — testing (rate limit cao hơn)

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: johnnaeder6537@gmail.com
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
      - http01:
          ingress:
            class: traefik
```

**Verify:**
```bash
kubectl get clusterissuer
# NAME                  READY   AGE
# letsencrypt-prod      True    ...
# letsencrypt-staging   True    ...
```

## 4.4 — Tạo demo namespace

```bash
kubectl create namespace demo
```

## Verify toàn bộ post-bootstrap

```bash
# Storage
kubectl get storageclass | grep default

# Cloudflare Tunnel
kubectl -n cloudflare get pods -l app=cloudflared

# ClusterIssuer
kubectl get clusterissuer

# Namespaces
kubectl get ns | grep -E "cloudflare|demo|local-path"
```

## Files liên quan

| File | Mô tả |
|------|-------|
| `manifests/local-path-provisioner/install.sh` | Install script |
| `manifests/cloudflared/namespace.yaml` | Namespace definition |
| `manifests/cloudflared/deployment.yaml` | cloudflared Deployment |
| `manifests/cloudflared/secret.yaml.example` | Secret template |
| `manifests/cloudflared/README.md` | Cloudflared setup guide |
| `manifests/cluster-issuer.yaml` | Let's Encrypt ClusterIssuers |
