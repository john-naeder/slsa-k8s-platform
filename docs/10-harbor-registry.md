# 10 — Harbor OCI Registry

> Self-hosted OCI container registry để lưu trữ images, signatures, và SLSA provenance attestations.
> Managed by ArgoCD (Helm chart).

## Kiến trúc

```
Tekton Pipeline                    Harbor Registry
    │                               ┌──────────────────┐
    ├─ kaniko-build ───push──────▶  │  demo/demo-api   │  OCI Image
    │                               │  demo/demo-worker│
    │                               └──────────────────┘
    │
    └─ Tekton Chains ──push──────▶  ┌──────────────────┐
                                    │  Cosign Signature │  OCI Tag: sha256-xxx.sig
                                    │  SLSA Attestation │  OCI Tag: sha256-xxx.att
                                    └──────────────────┘

Kyverno ──verify──────────────────▶  Fetch signature + attestation from Harbor
```

## Thông tin hiện tại

| Setting | Giá trị |
|---------|---------|
| Helm Chart | harbor v1.16.2 |
| External URL | `https://harbor.kythuat.vn` |
| Service type | ClusterIP |
| TLS | Auto-generated (internal), terminated at Cloudflare Tunnel |
| Namespace | harbor |
| Storage | 10Gi registry, 2Gi database |
| Trivy scanner | Enabled |

## 10.1 — Deployment (ArgoCD)

Harbor được deploy bởi ArgoCD thông qua App-of-Apps:

```yaml
# code/infra/argocd/apps/harbor.yaml
spec:
  source:
    chart: harbor
    repoURL: https://helm.goharbor.io
    targetRevision: "1.16.2"
    helm:
      valuesObject:
        expose:
          type: clusterIP
          tls:
            auto:
              commonName: harbor.kythuat.vn
        externalURL: https://harbor.kythuat.vn
        persistence:
          persistentVolumeClaim:
            registry:
              size: 10Gi
            database:
              size: 2Gi
        trivy:
          enabled: true
```

## 10.2 — Expose Harbor qua Cloudflare Tunnel

```bash
# Tạo IngressRoute cho Harbor (nếu chưa có)
cat <<EOF | kubectl apply -f -
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: harbor
  namespace: harbor
spec:
  entryPoints: [web]
  routes:
    - match: Host(\`harbor.kythuat.vn\`)
      kind: Rule
      services:
        - name: harbor-portal
          port: 80
EOF

# Thêm Cloudflare Tunnel route
cd code/infra/manifests/cloudflared/
SUBDOMAIN="harbor" SERVICE_URL="http://harbor-portal.harbor.svc.cluster.local:80" \
  bash setup-route.sh
```

## 10.3 — Harbor Project Setup

Sau khi Harbor deploy xong, tạo project cho demo images:

```bash
# Login Harbor CLI (hoặc dùng Web UI)
# Web UI: https://harbor.kythuat.vn → admin / <password>

# Tạo project "demo" (public, Cosign auto-signature)
curl -s -u admin:<password> -X POST \
  "https://harbor.kythuat.vn/api/v2.0/projects" \
  -H "Content-Type: application/json" \
  -d '{"project_name":"demo","public":true,"metadata":{"auto_scan":"true"}}'
```

## 10.4 — Harbor CA Certificate trên Nodes

Harbor sử dụng TLS tự ký (auto-generated). Các nodes cần trust CA:

```bash
# Trích xuất CA cert từ Harbor nginx secret
kubectl -n harbor get secret harbor-nginx -o jsonpath='{.data.ca\.crt}' | base64 -d > harbor-ca.crt

# Copy CA lên mỗi node
for NODE_IP in 100.95.126.102 100.94.203.28; do
  scp harbor-ca.crt john@${NODE_IP}:/tmp/
  ssh -t john@${NODE_IP} "
    sudo cp /tmp/harbor-ca.crt /usr/local/share/ca-certificates/harbor-ca.crt
    sudo update-ca-certificates
    sudo systemctl restart containerd
  "
done
```

> **Quan trọng:** Khi Harbor TLS cert bị regenerate (ví dụ: pod restart), cần repeat bước này.
> Triệu chứng: `ImagePullBackOff` — `x509: certificate signed by unknown authority`.

### Verify containerd có thể pull từ Harbor

```bash
# Trên node
sudo crictl pull harbor.kythuat.vn/demo/demo-api:latest
```

## 10.5 — Tekton Chains + Harbor

Tekton Chains push Cosign signature và SLSA attestation lên Harbor cùng image.
Chains cần truy cập Harbor → dùng cùng credentials với `tekton-build-sa`:

```bash
# Secret harbor-registry-credentials đã được mount vào tekton-build-sa
# Chains controller cũng cần credentials:
kubectl -n tekton-chains create secret docker-registry harbor-registry-credentials \
  --docker-server=harbor.kythuat.vn \
  --docker-username=admin \
  --docker-password=<HARBOR_PASSWORD>

# Patch Chains controller SA
kubectl -n tekton-chains patch serviceaccount tekton-chains-controller \
  -p '{"secrets":[{"name":"harbor-registry-credentials"}]}'
```

## 10.6 — Kiểm tra image artifacts trong Harbor

Sau khi PipelineRun hoàn tất, Harbor Web UI sẽ hiển thị:

```
Project: demo
└── demo-api
    ├── latest (tag)          → OCI Image
    ├── sha256-xxx.sig        → Cosign Signature
    └── sha256-xxx.att        → SLSA Provenance Attestation
```

Hoặc kiểm tra bằng CLI:

```bash
# List tags
curl -s -u admin:<password> \
  "https://harbor.kythuat.vn/v2/demo/demo-api/tags/list" | jq .

# Xem vulnerability scan kết quả (Trivy)
curl -s -u admin:<password> \
  "https://harbor.kythuat.vn/api/v2.0/projects/demo/repositories/demo-api/artifacts/latest" | jq .
```

## Verify

```bash
# Harbor pods
kubectl get pods -n harbor
# harbor-core, harbor-database, harbor-jobservice, harbor-nginx,
# harbor-portal, harbor-redis, harbor-registry, harbor-trivy

# Harbor services
kubectl get svc -n harbor

# Web UI accessible
curl -sI https://harbor.kythuat.vn
# HTTP/2 200

# Image push test
docker login harbor.kythuat.vn
docker pull alpine:3.20
docker tag alpine:3.20 harbor.kythuat.vn/demo/test:v1
docker push harbor.kythuat.vn/demo/test:v1
```

## Files liên quan

| File | Mô tả |
|------|-------|
| `infra/argocd/apps/harbor.yaml` | ArgoCD Application (Helm chart v1.16.2) |
| `tekton/rbac/harbor-secret.yaml.example` | Template cho Harbor docker-config secret |
| `infra/manifests/cosign.pub` | Cosign public key (verify signatures) |
| `infra/scripts/setup-node-harbor.sh` | Script cập nhật Harbor CA trên nodes |
