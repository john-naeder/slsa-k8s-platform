# 09 — Tekton CI Pipeline & SLSA L3 Supply-Chain Security

> Core CI/CD pipeline: Git push → auto-build → sign → generate SLSA provenance → GitOps promote.
> Đây là trung tâm của SLSA Level 3 compliance.

## Kiến trúc tổng quan

```
GitHub Push → Webhook POST
                │
                ▼
┌─────────────────────────────────────┐
│  Tekton EventListener               │
│  (el-github-listener:8080)          │
│  ├─ CEL Filter: main branch only    │
│  ├─ CEL Filter: skip [skip ci]      │
│  └─ CEL Filter: code/src/demo-api/* │
└──────────────┬──────────────────────┘
               │ TriggerBinding → TriggerTemplate
               ▼
┌─────────────────────────────────────┐
│  PipelineRun (build-and-sign)       │
│                                     │
│  1. git-clone     → fetch source    │
│  2. kaniko-build  → build & push    │
│  3. update-manifest → promote       │
│                                     │
│  ▸ Tekton Chains (auto):            │
│    - Cosign sign image              │
│    - Generate in-toto SLSA v0.2     │
│      provenance attestation         │
│    - Push attestation to OCI (Harbor)│
└──────────────┬──────────────────────┘
               │ Git commit (image digest update)
               ▼
┌─────────────────────────────────────┐
│  ArgoCD auto-sync                   │
│  → Kyverno verify signature         │
│  → Kyverno verify provenance        │
│  → Deploy to cluster                │
└─────────────────────────────────────┘
```

## Components

| Component | Version | Vai trò |
|-----------|---------|---------|
| Tekton Pipelines | v1 API | Pipeline orchestrator |
| Tekton Triggers | v1beta1 | GitHub webhook → PipelineRun |
| Tekton Chains | v0.26.0 | Auto-sign + SLSA provenance |
| Kaniko | v1.23.2 | Rootless container image build |
| Cosign (Sigstore) | — | Image signing (key-pair mode) |
| Harbor | v1.16.2 | OCI registry (image + attestation) |

## Yêu cầu

- K8s cluster + ArgoCD đang chạy (Phase 05 hoàn tất)
- Harbor registry accessible (`harbor.kythuat.vn`)
- Tekton Pipelines, Triggers, Chains đã cài (qua Helmfile hoặc kubectl)
- Cosign key pair đã generate

## 9.1 — Tekton Resources Overview

```
tekton/
├── config/
│   └── chains-config.yaml          # Tekton Chains ConfigMap
├── pipelines/
│   └── build-and-sign.yaml         # Pipeline: clone → build → promote
├── tasks/
│   ├── git-clone.yaml              # Task: clone Git repo
│   ├── kaniko-build.yaml           # Task: build OCI image (Kaniko)
│   └── update-manifest.yaml        # Task: update deployment manifest + git push
├── triggers/
│   ├── event-listener.yaml         # EventListener: receive GitHub webhook
│   ├── trigger-binding.yaml        # TriggerBinding: extract params from payload
│   ├── trigger-template.yaml       # TriggerTemplate: create PipelineRun
│   ├── ingressroute.yaml           # Traefik IngressRoute: tekton.kythuat.vn
│   └── rbac.yaml                   # ServiceAccount + Role for triggers
├── rbac/
│   ├── service-account.yaml        # tekton-build-sa + Harbor credentials
│   └── harbor-secret.yaml.example  # Template cho Harbor docker-config secret
└── runs/
    └── demo-api-run.yaml           # Manual PipelineRun (test/debug)
```

## 9.2 — Setup RBAC & Credentials

### Cosign Key Pair

```bash
# Generate signing key pair
cosign generate-key-pair

# → cosign.key (private — dùng cho Tekton Chains)
# → cosign.pub (public — dùng cho Kyverno verify)

# Tạo K8s Secret cho Tekton Chains
kubectl -n tekton-chains create secret generic signing-secrets \
  --from-file=cosign.key=cosign.key \
  --from-file=cosign.pub=cosign.pub \
  --from-literal=cosign.password=""

# Copy cosign.pub vào repo (cho Kyverno policies)
cp cosign.pub code/infra/manifests/cosign.pub
```

### Harbor Registry Credentials

```bash
# Tạo docker-config secret cho Kaniko push
kubectl -n tekton-pipelines create secret docker-registry harbor-registry-credentials \
  --docker-server=harbor.kythuat.vn \
  --docker-username=admin \
  --docker-password=<HARBOR_PASSWORD>
```

### Git SSH Credentials (cho promote step)

```bash
# Tạo SSH key cho Tekton push manifest updates
ssh-keygen -t ed25519 -C "tekton-pipeline" -f /tmp/tekton-git-key -N ""

# Thêm public key lên GitHub: Settings → Deploy keys → "tekton-pipeline" → Allow write access ✅

# Tạo K8s Secret
kubectl -n tekton-pipelines create secret generic git-ssh-credentials \
  --from-file=id_ed25519=/tmp/tekton-git-key \
  --from-file=known_hosts=<(ssh-keyscan github.com 2>/dev/null)

rm /tmp/tekton-git-key /tmp/tekton-git-key.pub
```

### Service Account

```bash
kubectl apply -f code/tekton/rbac/service-account.yaml
# → tekton-build-sa (gắn harbor-registry-credentials)
```

## 9.3 — Tekton Chains Configuration

Chains tự động observe mỗi TaskRun/PipelineRun và:
1. **Sign image** bằng Cosign (key từ `signing-secrets`)
2. **Generate in-toto SLSA v0.2 provenance** attestation
3. **Push attestation** lên OCI registry (Harbor) cùng image

```bash
kubectl apply -f code/tekton/config/chains-config.yaml
```

### ConfigMap chi tiết

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: chains-config
  namespace: tekton-chains
data:
  artifacts.taskrun.format: "in-toto"       # in-toto provenance format
  artifacts.taskrun.storage: "oci"          # Store attestation in OCI registry
  artifacts.pipelinerun.format: "in-toto"
  artifacts.pipelinerun.storage: "oci"
  artifacts.oci.storage: "oci"
  transparency.enabled: "false"             # No public Rekor (self-hosted)
```

> **Lưu ý:** `transparency.enabled: false` vì đây là self-hosted environment, không có Rekor instance.
> Chains vẫn generate provenance đầy đủ, chỉ không log lên transparency log công khai.

### Chains nhận diện image thế nào?

Chains scan kết quả của Task/Pipeline để tìm `IMAGE_URL` và `IMAGE_DIGEST` results.
Task `kaniko-build` output chính xác 2 results này → Chains tự động pick up.

## 9.4 — Pipeline: build-and-sign

```bash
kubectl apply -f code/tekton/pipelines/build-and-sign.yaml
```

### Pipeline flow

| # | Task | Image | Mô tả |
|---|------|-------|-------|
| 1 | `clone` | git-clone | Clone source code từ GitHub |
| 2 | `build` | kaniko v1.23.2 | Build OCI image, push to Harbor, output digest |
| 3 | `promote` | alpine/git:2.47.2 | Update deployment.yaml với `image@sha256:...`, git push |

### Pipeline params

| Param | Mô tả | Ví dụ |
|-------|-------|-------|
| `repo-url` | SSH URL của Git repo | `git@github.com:john-naeder/slsa-k8s-platform.git` |
| `revision` | Git branch/tag/sha | `main` |
| `image` | Full image reference | `harbor.kythuat.vn/demo/demo-api:latest` |
| `dockerfile` | Path to Dockerfile | `./Dockerfile` |
| `context` | Build context subdirectory | `code/src/demo-api` |

### Pipeline results

| Result | Mô tả |
|--------|-------|
| `IMAGE_URL` | `harbor.kythuat.vn/demo/demo-api:latest` |
| `IMAGE_DIGEST` | `sha256:acdabb3b...` |
| `COMMIT_SHA` | Git commit SHA was built |

## 9.5 — Tasks chi tiết

### git-clone

Standard Tekton Hub task. Clone repo vào shared workspace.

### kaniko-build

- **Image:** `gcr.io/kaniko-project/executor:v1.23.2`
- Build Dockerfile → push OCI image to Harbor
- Output `IMAGE_URL` và `IMAGE_DIGEST` (required by Chains)
- Extra args: `--insecure`, `--skip-tls-verify` (Harbor self-signed cert)
- `--snapshot-mode=redo`, `--compressed-caching=false` (optimize for bare-metal)

### update-manifest (promote)

- **Image:** `alpine/git:2.47.2`
- Đọc `IMAGE_DIGEST` từ task trước
- `sed` update deployment.yaml: thay dòng `image:` bằng `image@sha256:<digest>`
- `git commit + push` → trigger ArgoCD auto-sync
- Sử dụng SSH credentials từ workspace

## 9.6 — Triggers: GitHub Webhook → PipelineRun

### Apply trigger resources

```bash
kubectl apply -f code/tekton/triggers/rbac.yaml
kubectl apply -f code/tekton/triggers/trigger-binding.yaml
kubectl apply -f code/tekton/triggers/trigger-template.yaml
kubectl apply -f code/tekton/triggers/event-listener.yaml
kubectl apply -f code/tekton/triggers/ingressroute.yaml
```

### EventListener

- **Service tự động tạo:** `el-github-listener:8080` trong namespace `tekton-pipelines`
- **Expose qua Traefik:** `tekton.kythuat.vn` (IngressRoute → el-github-listener:8080)
- **Expose qua Cloudflare Tunnel:** cần setup route cho `tekton.kythuat.vn`

### CEL Filter (chỉ trigger khi cần)

```yaml
filter: >-
  body.ref == 'refs/heads/main' &&
  !body.head_commit.message.startsWith('[skip ci]') &&
  body.commits.exists(c,
    c.modified.exists(f, f.startsWith('code/src/demo-api/')) ||
    c.added.exists(f, f.startsWith('code/src/demo-api/'))
  )
```

Chỉ trigger khi:
1. Push vào branch `main`
2. Commit message KHÔNG bắt đầu bằng `[skip ci]`
3. Có file thay đổi trong `code/src/demo-api/`

### TriggerBinding

Extract params từ GitHub webhook payload:
- `git-repo-url` ← `body.repository.ssh_url`
- `git-revision` ← `body.after` (commit SHA)
- `git-repo-name` ← `body.repository.name`

### TriggerTemplate

Tạo PipelineRun với:
- Pipeline: `build-and-sign`
- SA: `tekton-build-sa`
- Image: `harbor.kythuat.vn/demo/demo-api:latest`
- Context: `code/src/demo-api`
- Workspace: 1Gi PVC (dynamic)
- Timeout: 30 phút

## 9.7 — GitHub Webhook Setup

1. Repository → Settings → **Webhooks** → Add webhook
2. **Payload URL:** `https://tekton.kythuat.vn`
3. **Content type:** `application/json`
4. **Secret:** (optional — thêm interceptor nếu cần)
5. **Events:** "Just the push event"
6. **Active:** ✅

### Verify webhook delivery

GitHub → Settings → Webhooks → Recent Deliveries:
- **Response:** 202 Accepted = ✅ EventListener nhận thành công
- **Response:** 404 = IngressRoute chưa match
- **Response:** Timeout = cloudflared / Traefik chưa route

## 9.8 — Manual PipelineRun (Test/Debug)

```bash
# Chạy pipeline thủ công (không qua webhook)
kubectl apply -f code/tekton/runs/demo-api-run.yaml

# Hoặc dùng tkn CLI
tkn pipeline start build-and-sign \
  -p repo-url=git@github.com:john-naeder/slsa-k8s-platform.git \
  -p revision=main \
  -p image=harbor.kythuat.vn/demo/demo-api:latest \
  -p context=code/src/demo-api \
  -w name=shared-workspace,claimName=tekton-workspace \
  -w name=ssh-credentials,secret=git-ssh-credentials \
  --use-param-defaults \
  -n tekton-pipelines

# Theo dõi
tkn pipelinerun logs -f -n tekton-pipelines
```

## 9.9 — Verify SLSA Provenance

Sau khi PipelineRun hoàn tất:

```bash
# 1. Kiểm tra image đã được sign
cosign verify --key code/infra/manifests/cosign.pub \
  harbor.kythuat.vn/demo/demo-api@sha256:<digest>

# 2. Kiểm tra SLSA provenance attestation
cosign verify-attestation --key code/infra/manifests/cosign.pub \
  --type slsaprovenance \
  harbor.kythuat.vn/demo/demo-api@sha256:<digest>

# 3. Xem nội dung provenance
cosign verify-attestation --key code/infra/manifests/cosign.pub \
  --type slsaprovenance \
  harbor.kythuat.vn/demo/demo-api@sha256:<digest> \
  | jq -r '.payload' | base64 -d | jq .
```

### SLSA Provenance fields

```json
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://slsa.dev/provenance/v0.2",
  "predicate": {
    "builder": { "id": "https://tekton.dev/chains/v2" },
    "buildType": "tekton.dev/v1/PipelineRun",
    "invocation": {
      "configSource": { ... },
      "parameters": { ... }
    },
    "materials": [
      { "uri": "git+https://github.com/john-naeder/slsa-k8s-platform", "digest": { "sha1": "..." } }
    ]
  }
}
```

## 9.10 — E2E Flow tóm tắt

```
1. Developer push code → GitHub
2. GitHub webhook → tekton.kythuat.vn → EventListener
3. CEL filter match → TriggerTemplate tạo PipelineRun
4. git-clone → kaniko-build (push to Harbor) → update-manifest (git push)
5. Tekton Chains tự động:
   a. Sign image bằng Cosign
   b. Generate in-toto SLSA v0.2 provenance
   c. Push attestation lên Harbor (OCI)
6. update-manifest commit image digest → Git
7. ArgoCD detect Git change → auto-sync
8. Kyverno verify:
   a. Image có Cosign signature? ✅
   b. Image có SLSA provenance? ✅
   c. Builder ID = tekton.dev/chains/v2? ✅
9. Pod deployed ✅
```

## Files liên quan

| File | Mô tả |
|------|-------|
| `tekton/config/chains-config.yaml` | Chains ConfigMap (provenance format, storage) |
| `tekton/pipelines/build-and-sign.yaml` | Pipeline definition |
| `tekton/tasks/git-clone.yaml` | Git clone task |
| `tekton/tasks/kaniko-build.yaml` | Kaniko build task (IMAGE_URL + IMAGE_DIGEST) |
| `tekton/tasks/update-manifest.yaml` | GitOps promote task |
| `tekton/triggers/event-listener.yaml` | GitHub webhook receiver |
| `tekton/triggers/trigger-binding.yaml` | Extract params from webhook |
| `tekton/triggers/trigger-template.yaml` | Create PipelineRun |
| `tekton/triggers/ingressroute.yaml` | Expose EventListener via Traefik |
| `tekton/triggers/rbac.yaml` | Triggers ServiceAccount + Role |
| `tekton/rbac/service-account.yaml` | Build SA + Harbor credentials |
| `tekton/runs/demo-api-run.yaml` | Manual PipelineRun |
| `infra/manifests/cosign.pub` | Cosign public key |
