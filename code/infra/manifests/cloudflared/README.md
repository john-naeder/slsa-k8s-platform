# Cloudflare Tunnel (cloudflared)

Expose K8s services ra internet qua Cloudflare Tunnel — không cần public IP.

## Luồng traffic

```
Internet → Cloudflare CDN → Cloudflare Tunnel (encrypted)
    → cloudflared Pod → Traefik (ClusterIP) → App Pod
```

## Setup

### 1. Tạo Tunnel trên Cloudflare Dashboard

1. Vào [Cloudflare Zero Trust](https://one.dash.cloudflare.com/)
2. Networks → Tunnels → Create a tunnel
3. Copy tunnel token

### 2. Tạo K8s Secret

```bash
kubectl apply -f namespace.yaml

kubectl create secret generic cloudflared-token \
  --namespace=cloudflare \
  --from-literal=tunnel-token=<PASTE_TOKEN_HERE>
```

### 3. Deploy cloudflared

```bash
kubectl apply -f deployment.yaml
```

### 4. Verify

```bash
kubectl -n cloudflare get pods
kubectl -n cloudflare logs deploy/cloudflared
```

## GitOps (Sealed Secrets)

Nếu dùng Sealed Secrets để quản lý token trong Git:

```bash
# Tạo plaintext secret → seal → apply sealed version
kubectl create secret generic cloudflared-token \
  --namespace=cloudflare \
  --from-literal=tunnel-token=<TOKEN> \
  --dry-run=client -o yaml | kubeseal -o yaml > sealed-secret.yaml

kubectl apply -f sealed-secret.yaml
```
