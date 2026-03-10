# Luồng E2E: Dev → Deploy → Internet (SLSA L3 Compliant)

> **Tổng hợp toàn bộ luồng End-to-End** từ lúc developer viết code cho tới khi ứng dụng
> được expose ra internet, đảm bảo tuân thủ SLSA Level 3 trên nền tảng Kubernetes self-hosted.

---

## Tổng quan kiến trúc

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        TỔNG QUAN KIẾN TRÚC                                  │
│                                                                             │
│  Developer ──push──▶ GitHub ──webhook──▶ Tekton Pipeline (K8s)              │
│                                              │                              │
│                                    ┌─────────┴──────────┐                   │
│                                    │  git-clone          │                  │
│                                    │  kaniko-build ──────┤──▶ Harbor        │
│                                    │  update-manifest    │     (OCI Reg)    │
│                                    └─────────┬──────────┘       │           │
│                                              │                  │           │
│                              Tekton Chains (observe)            │           │
│                                    │                            │           │
│                              ┌─────┴──────┐                    │           │
│                              │ Sign image  │──attestation──────▶│           │
│                              │ + Provenance│──signature────────▶│           │
│                              └─────┬──────┘                    │           │
│                                    │                            │           │
│                        update manifest (digest)                 │           │
│                              ──commit──▶ GitHub                 │           │
│                                    │                            │           │
│                              Argo CD (GitOps)                   │           │
│                              detect change                      │           │
│                                    │                            │           │
│                              create Pod ───────────────────pull image       │
│                                    │                                        │
│                              Kyverno (Admission)                            │
│                              ┌─────┴──────┐                                │
│                              │ verify sig  │                                │
│                              │ verify prov │──ALLOW/DENY                    │
│                              └─────┬──────┘                                │
│                                    │ (ALLOW)                                │
│                              Pod Running                                    │
│                                    │                                        │
│                              Traefik (Ingress)                              │
│                                    │                                        │
│                              cloudflared (Tunnel)                           │
│                                    │                                        │
│                              Cloudflare CDN                                 │
│                                    │                                        │
│                              ▶ Internet (https://demo.kythuat.vn)           │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Chuỗi tin cậy tóm tắt (Chain of Trust)

```
① Source Protection    GitHub Branch Protection (block force-push, signed commits)
        ↓
② Automated Build     Tekton Pipeline (K8s Pod, ephemeral, isolated)
        ↓
③ Rootless Build      Kaniko (no Docker daemon, no root)
        ↓
④ Unforgeable Proof   Tekton Chains (control plane ký, build không đụng key)
        ↓
⑤ Signed Artifact     Cosign signature + in-toto provenance → Harbor
        ↓
⑥ Digest Pinning      Deployment ref = sha256:... (không dùng mutable tag)
        ↓
⑦ GitOps Deploy       Argo CD pull-based (no human kubectl)
        ↓
⑧ Admission Gate      Kyverno verify signature + provenance → ALLOW/DENY
        ↓
⑨ Secure Exposure     Traefik → cloudflared tunnel → Cloudflare → Internet
```

> Mỗi bước tạo một **trust boundary** riêng biệt. Để compromise được hệ thống,
> attacker phải đồng thời vượt qua **tất cả 9 lớp** — bản chất của Zero Trust + SLSA L3.

---

## Chi tiết từng Phase

### Phase 1 — Source Control (SLSA Source L3)

| Bước | Chi tiết | Đảm bảo SLSA |
|------|----------|---------------|
| Dev viết code | Push lên GitHub repo `slsa-k8s-platform` | Source được version-controlled (Git) |
| Branch Protection | Block force-push, block delete `main`, require status checks | Source L3: technical controls liên tục |
| Commit signing | GPG/SSH signed commits | Xác thực danh tính dev |
| PR merge | Code vào `main` chỉ qua PR + CI checks pass | Audit trail đầy đủ |

**Trust boundary:** Source platform = GitHub (tách biệt khỏi Build platform = K8s/Tekton).

**Yêu cầu Source L3 (draft SLSA v1.2):**

| # | Yêu cầu | Cách đạt |
|---|---------|----------|
| 1 | Version controlled | Git (GitHub) |
| 2 | Immutable revisions | commit SHA |
| 3 | Authenticated identity | GitHub auth + signed commits |
| 4 | Block force push trên protected branches | GitHub Branch Protection Rules |
| 5 | Block branch deletion | GitHub Branch Protection Rules |
| 6 | Require status checks trước merge | GitHub required checks |
| 7 | Technical controls maintained liên tục | Rules applied permanently |

---

### Phase 2 — CI Trigger (Webhook → Tekton)

```
GitHub push event ──POST──▶ https://tekton.kythuat.vn (EventListener)
                                   │
                            CEL Interceptor:
                              filter chỉ push main +
                              commits chạm code/src/demo-api/**
                                   │
                            TriggerBinding:
                              extract repo-url, revision, commit-sha
                                   │
                            TriggerTemplate:
                              tạo PipelineRun tự động
```

**File cấu hình:**
- `code/tekton/triggers/event-listener.yaml` — EventListener + CEL filter
- `code/tekton/triggers/trigger-binding.yaml` — extract params từ webhook payload
- `code/tekton/triggers/trigger-template.yaml` — template tạo PipelineRun

**CEL filter logic:**
```
body.ref == 'refs/heads/main' &&
!body.head_commit.message.startsWith('[skip ci]') &&
body.commits.exists(c,
  c.modified.exists(f, f.startsWith('code/src/demo-api/')) ||
  c.added.exists(f, f.startsWith('code/src/demo-api/'))
)
```

---

### Phase 3 — Build Pipeline (SLSA Build L3 Core)

Pipeline `build-and-sign` gồm 3 tasks chạy trong **Pod phù du** (ephemeral) trên K8s:

| # | Task | Hành động | SLSA Relevance |
|---|------|-----------|----------------|
| 1 | **git-clone** | Clone source từ GitHub vào shared workspace | `externalParameters.source` trong provenance |
| 2 | **kaniko-build** | Build OCI image rootless, push lên `harbor.kythuat.vn/demo/demo-api@sha256:...` | Tạo artifact với digest chính xác |
| 3 | **update-manifest** | Cập nhật `image: ...@sha256:<new-digest>` trong deployment.yaml → commit lại Git | Đảm bảo deploy đúng digest, không dùng mutable tag |

**File pipeline:** `code/tekton/pipelines/build-and-sign.yaml`

**Pipeline results (output):**
- `IMAGE_URL` — full image reference
- `IMAGE_DIGEST` — sha256 digest của image vừa build
- `COMMIT_SHA` — git commit SHA đã build

**Tại sao đạt Build L3:**

| Yêu cầu SLSA Build L3 | Cách đạt |
|------------------------|----------|
| Automated build | PipelineRun trigger tự động từ webhook |
| Hosted build platform | Tekton Pod chạy trên K8s cluster |
| Isolated builds | Mỗi TaskRun = 1 Pod riêng biệt, không cross-contamination |
| Ephemeral environment | Pod bị delete sau khi TaskRun hoàn thành |
| Unforgeable provenance | Tekton Chains ở cluster-level, build script không đụng signing key |

---

### Phase 4 — Signing + Provenance (Tekton Chains)

```
Tekton Chains Controller (cluster-level, NGOÀI Pod build)
        │
        ├── Observe TaskRun/PipelineRun completion
        ├── Thu thập: source URL, commit SHA, image digest, builder ID
        ├── Tạo in-toto SLSA provenance attestation
        ├── Ký bằng Cosign (key-pair trong K8s Secret signing-secrets)
        └── Push signature + attestation lên Harbor (OCI artifact)
```

**Cấu hình Chains:** `code/tekton/config/chains-config.yaml`

```yaml
# Provenance format
artifacts.taskrun.format: "in-toto"       # SLSA provenance format
artifacts.taskrun.storage: "oci"          # Lưu trên Harbor (OCI registry)
artifacts.pipelinerun.format: "in-toto"
artifacts.pipelinerun.storage: "oci"

# OCI storage
artifacts.oci.storage: "oci"

# Transparency log (disabled — self-hosted, không có public Rekor)
transparency.enabled: "false"
```

**Tại sao unforgeable (Build L3):**

| Đặc điểm | Giải thích |
|-----------|------------|
| Chains chạy cluster-level | Là controller riêng, không nằm trong Pod build |
| Signing key cách ly | Nằm trong `tekton-chains/signing-secrets`, build script không thể truy cập |
| Provenance tự động | Pipeline code **không thể giả mạo** provenance — Chains tự observe và tạo |
| Không cần code trong pipeline | Chains là observer thụ động, không phải step trong pipeline |

**Sau bước này, trên Harbor có:**

```
harbor.kythuat.vn/demo/demo-api@sha256:abc123...
├── OCI Image          (artifact chính)
├── .sig               (Cosign signature)
└── .att               (in-toto SLSA provenance attestation)
```

**Cấu trúc provenance (in-toto v0.2):**

```json
{
  "_type": "https://in-toto.io/Statement/v0.1",
  "predicateType": "https://slsa.dev/provenance/v0.2",
  "subject": [{
    "name": "harbor.kythuat.vn/demo/demo-api",
    "digest": { "sha256": "abc123..." }
  }],
  "predicate": {
    "builder": { "id": "https://tekton.dev/chains/v2" },
    "buildType": "tekton.dev/v1beta1/TaskRun",
    "invocation": {
      "configSource": {
        "uri": "git+https://github.com/john-naeder/slsa-k8s-platform",
        "digest": { "sha1": "commit-sha..." },
        "entryPoint": "build-and-sign"
      }
    },
    "materials": [
      { "uri": "git+https://github.com/john-naeder/slsa-k8s-platform@refs/heads/main" }
    ]
  }
}
```

---

### Phase 5 — GitOps Deployment (Argo CD)

```
Task update-manifest commit new digest vào Git
        │
        ▼
Argo CD (pull-based GitOps)
        │
        ├── Watch repo: code/src/demo-api/k8s/
        ├── Detect drift: deployment.yaml có digest mới
        ├── Sync: tạo/update Deployment trong namespace "demo"
        └── Self-heal: nếu ai kubectl edit → Argo revert về Git state
```

**Root Application:** `code/infra/argocd/app-of-apps.yaml`

```yaml
spec:
  source:
    repoURL: git@github.com:john-naeder/slsa-k8s-platform.git
    targetRevision: main
    path: code/infra/argocd/apps    # Thư mục chứa Application CRDs
  syncPolicy:
    automated:
      prune: true       # Xóa resource nếu file bị xóa khỏi Git
      selfHeal: true    # Revert drift
```

**Deployment sử dụng digest pinning** (`code/src/demo-api/k8s/deployment.yaml`):

```yaml
containers:
  - name: demo-api
    image: harbor.kythuat.vn/demo/demo-api@sha256:acdabb3b89bc5b806f690417b08d5e4345106c24706faa227e907f0eb9a2599e
```

> **KHÔNG** dùng tag như `latest` hoặc `v1.0.0` — chỉ dùng `@sha256:...`
> để đảm bảo immutable reference, phù hợp SLSA L3.

**Zero Trust alignment:**
- Không ai `kubectl apply` trực tiếp vào cluster
- Chỉ Argo CD pull từ Git
- Git history = deployment audit trail

---

### Phase 6 — Admission Verification (Kyverno)

Khi Argo CD tạo Pod, **Kyverno chặn tại Kubernetes Admission** và kiểm tra 2 policy:

#### Policy 1: Verify Cosign Image Signature

**File:** `code/policies/verify-image-signature.yaml`

```
                  Pod request (từ Argo CD)
                          │
                          ▼
                  Kyverno Admission Webhook
                          │
                  ┌───────┴────────┐
                  │ imageReferences │ match "harbor.kythuat.vn/demo/*"
                  └───────┬────────┘
                          │
                  Fetch .sig từ Harbor
                          │
                  Verify signature bằng public key
                          │
                  ┌───────┴────────┐
                  │   PASS → tiếp  │
                  │   FAIL → DENY  │
                  └────────────────┘
```

```yaml
spec:
  validationFailureAction: Enforce    # DENY nếu fail (không phải Audit)
  rules:
    - name: verify-harbor-image-signature
      match:
        resources:
          kinds: [Pod]
          namespaces: [demo]
      verifyImages:
        - imageReferences: ["harbor.kythuat.vn/demo/*"]
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE...
                      -----END PUBLIC KEY-----
```

#### Policy 2: Verify SLSA Provenance Attestation

**File:** `code/policies/verify-slsa-provenance.yaml`

```
                  Pod request (đã pass Policy 1)
                          │
                          ▼
                  Fetch .att (attestation) từ Harbor
                          │
                  Verify attestation signature
                          │
                  Check conditions:
                    builder.id == "https://tekton.dev/chains/v2"
                          │
                  ┌───────┴────────┐
                  │   PASS → ALLOW │  ← Image từ Tekton, có provenance hợp lệ
                  │   FAIL → DENY  │  ← Builder lạ / provenance thiếu
                  └────────────────┘
```

```yaml
verifyImages:
  - imageReferences: ["harbor.kythuat.vn/demo/*"]
    attestations:
      - type: https://slsa.dev/provenance/v0.2
        conditions:
          - all:
              - key: "{{ builder.id }}"
                operator: Equals
                value: "https://tekton.dev/chains/v2"
```

**Kết quả admission:**

| Scenario | Signature | Provenance | Builder ID | Kết quả |
|----------|-----------|------------|------------|---------|
| Happy path (Tekton build) | ✅ Valid | ✅ Valid | ✅ tekton.dev/chains/v2 | **ALLOW** |
| Unsigned image (nginx:latest) | ❌ Missing | ❌ Missing | — | **DENY** |
| Signed nhưng thiếu provenance | ✅ Valid | ❌ Missing | — | **DENY** |
| Provenance từ builder lạ | ✅ Valid | ✅ Valid | ❌ unknown-builder | **DENY** |
| Image digest bị tamper | ❌ Mismatch | — | — | **DENY** |

---

### Phase 7 — Networking & Internet Exposure

```
Pod (demo-api:8080)
    │
    ▼
Service (ClusterIP demo-api:8080)
    │
    ▼
Traefik IngressRoute
    Host(`demo.kythuat.vn`) → demo-api:8080
    │
    ▼
cloudflared Pod (outbound tunnel → Cloudflare edge)
    │
    ▼
Cloudflare CDN + DNS
    demo.kythuat.vn → tunnel
    │
    ▼
Internet user
    curl https://demo.kythuat.vn/health → 200 OK
```

**Luồng chi tiết:**

| Layer | Component | Chức năng | Config file |
|-------|-----------|-----------|-------------|
| L7 App | demo-api Pod | Serve HTTP :8080 | `code/src/demo-api/k8s/deployment.yaml` |
| L4 Service | K8s Service | ClusterIP → Pod | `code/src/demo-api/k8s/service.yaml` |
| L7 Ingress | Traefik IngressRoute | Host-based routing | `code/src/demo-api/k8s/ingressroute.yaml` |
| Tunnel | cloudflared | Outbound tunnel to Cloudflare | `code/infra/manifests/cloudflared/deployment.yaml` |
| CDN/DNS | Cloudflare | `demo.kythuat.vn` → tunnel | Cloudflare Dashboard |

**Tại sao dùng cloudflared tunnel:**
- Bare metal cluster không có public IP
- cloudflared tạo **outbound** connection → không cần mở port trên firewall
- Cloudflare cung cấp CDN, DDoS protection, TLS termination miễn phí

---

## Bảng ánh xạ Component ↔ SLSA Requirement

| SLSA Requirement | Component đảm bảo | Cách verify |
|------------------|--------------------|-------------|
| **Source L3:** Version controlled | Git (GitHub) | `git log` |
| **Source L3:** Block force push | GitHub Branch Protection | Settings → Branches |
| **Source L3:** Require status checks | GitHub required checks | Settings → Branches |
| **Build L3:** Automated build | Tekton Pipeline + Triggers | `kubectl get pipelineruns` |
| **Build L3:** Hosted platform | Tekton on K8s | `kubectl get pods -n tekton-pipelines` |
| **Build L3:** Isolated builds | Mỗi TaskRun = 1 Pod mới | `kubectl get pods` (xem tên Pod unique) |
| **Build L3:** Ephemeral environment | Pod deleted after TaskRun | `kubectl get taskruns` |
| **Build L3:** Signed provenance | Tekton Chains + Cosign | `cosign verify-attestation <image>` |
| **Build L3:** Unforgeable provenance | Chains ở cluster-level | Signing key trong `tekton-chains/signing-secrets` |
| **Verification:** Signature check | Kyverno `verifyImages` | `kubectl get clusterpolicy` |
| **Verification:** Provenance check | Kyverno `attestations` | `kubectl get policyreport -n demo` |
| **Deployment:** Digest pinning | deployment.yaml `@sha256:...` | `kubectl get deploy -o yaml` |
| **Deployment:** GitOps only | Argo CD (pull-based) | `kubectl get applications -n argocd` |

---

## Luồng E2E hoàn chỉnh — Numbered Steps

```
 ┌──────────────────────────────────────────────────────────────────┐
 │  E2E FLOW: Developer → Internet                                  │
 ├──────────────────────────────────────────────────────────────────┤
 │                                                                  │
 │  1. Developer push code lên GitHub (signed commit, qua PR)       │
 │     └─ GitHub Branch Protection: block force-push, require CI    │
 │                                                                  │
 │  2. GitHub gửi webhook POST → Tekton EventListener               │
 │     └─ CEL filter: chỉ trigger cho push main + đúng path        │
 │                                                                  │
 │  3. Tekton tạo PipelineRun tự động                               │
 │     └─ Task 1: git-clone (clone source vào workspace)            │
 │     └─ Task 2: kaniko-build (build rootless → push Harbor)       │
 │     └─ Task 3: update-manifest (cập nhật sha256 digest → Git)   │
 │                                                                  │
 │  4. Tekton Chains (control plane) observe TaskRun hoàn thành     │
 │     └─ Tự động tạo in-toto SLSA provenance                      │
 │     └─ Ký bằng Cosign (key cách ly khỏi build)                  │
 │     └─ Push .sig + .att lên Harbor (cùng image)                  │
 │                                                                  │
 │  5. Argo CD phát hiện Git thay đổi (new digest in manifest)     │
 │     └─ Auto-sync: tạo/update Deployment trong namespace demo     │
 │                                                                  │
 │  6. Kyverno chặn ở Admission:                                    │
 │     └─ Verify Cosign signature → ✅                              │
 │     └─ Verify SLSA provenance (builder = tekton.dev) → ✅       │
 │     └─ ALLOW Pod creation                                        │
 │                                                                  │
 │  7. Pod chạy + Service expose                                    │
 │     └─ Traefik IngressRoute: demo.kythuat.vn → demo-api:8080    │
 │     └─ cloudflared tunnel → Cloudflare edge                      │
 │     └─ Internet: https://demo.kythuat.vn → 200 OK               │
 │                                                                  │
 └──────────────────────────────────────────────────────────────────┘
```

---

## Attack Scenarios — Chứng minh SLSA L3

| # | Kịch bản tấn công | Lớp chặn | Kết quả |
|---|-------------------|-----------|---------|
| 1 | Deploy unsigned image (`nginx:latest`) | Kyverno — thiếu signature | **DENY** |
| 2 | Tamper image digest sau build | Kyverno — digest mismatch | **DENY** |
| 3 | Build thủ công (docker build), ký nhưng không có provenance | Kyverno — thiếu attestation | **DENY** |
| 4 | Build trên CI khác (non-Tekton), có provenance giả | Kyverno — `builder.id ≠ tekton.dev/chains/v2` | **DENY** |
| 5 | Force push mã độc vào main | GitHub Branch Protection | **BLOCK** |
| 6 | kubectl apply trực tiếp vào cluster | Argo CD self-heal revert | **REVERT** |

---

## Quick Reference — Verify toàn bộ

```bash
# === Verify Source ===
# GitHub → Settings → Branches → branch protection rules

# === Verify Build ===
kubectl get pipelineruns -n tekton-pipelines
kubectl get taskruns -n tekton-pipelines

# === Verify Signing + Provenance ===
cosign verify --key k8s://tekton-chains/signing-secrets harbor.kythuat.vn/demo/demo-api@sha256:...
cosign verify-attestation --key k8s://tekton-chains/signing-secrets \
  --type https://slsa.dev/provenance/v0.2 harbor.kythuat.vn/demo/demo-api@sha256:...

# === Verify Policy Enforcement ===
kubectl get clusterpolicy                           # verify-image-signature, verify-slsa-provenance
kubectl get policyreport -n demo                    # xem kết quả verify

# === Verify Deployment ===
kubectl get applications -n argocd                  # Healthy + Synced
kubectl get deploy demo-api -n demo -o yaml | grep image   # phải là @sha256:...

# === Verify Exposure ===
curl -I https://demo.kythuat.vn/health              # 200 OK từ internet

# === Test Attack ===
kubectl run evil --image=nginx:latest -n demo        # Expected: DENIED by Kyverno
```

---

## Mapping: Trust Boundary ↔ Separation of Concerns

```
┌─────────────────────┐    ┌─────────────────────┐    ┌─────────────────────┐
│   SOURCE PLATFORM   │    │   BUILD PLATFORM    │    │  REGISTRY PLATFORM  │
│      (GitHub)       │    │   (K8s / Tekton)    │    │     (Harbor)        │
│                     │    │                     │    │                     │
│  • Source code      │    │  • Pipeline exec    │    │  • OCI images       │
│  • Branch protection│    │  • Kaniko build     │    │  • Signatures       │
│  • Commit signing   │    │  • Chains signing   │    │  • Attestations     │
│  • PR review        │    │  • Pod isolation    │    │  • Vuln scanning    │
└─────────┬───────────┘    └─────────┬───────────┘    └─────────┬───────────┘
          │                          │                          │
          │     webhook              │     push image           │
          ├─────────────────────────▶│─────────────────────────▶│
          │                          │                          │
          │                          │     push sig + att       │
          │                          │─────────────────────────▶│
          │                          │                          │
          │     commit new digest    │                          │
          │◀─────────────────────────│                          │
          │                          │                          │
┌─────────┴───────────┐    ┌─────────┴───────────┐    ┌─────────┴───────────┐
│   DEPLOY PLATFORM   │    │  POLICY PLATFORM    │    │ NETWORK PLATFORM    │
│     (Argo CD)       │    │    (Kyverno)        │    │ (Traefik+cloudflare)│
│                     │    │                     │    │                     │
│  • GitOps pull      │    │  • Verify signature │    │  • Ingress routing  │
│  • Auto-sync        │    │  • Verify provenance│    │  • TLS termination  │
│  • Drift detection  │    │  • Enforce/Deny     │    │  • Tunnel to cloud  │
│  • Rollback         │    │  • Policy reports   │    │  • CDN + DDoS       │
└─────────────────────┘    └─────────────────────┘    └─────────────────────┘
```

> **Separation of Concerns:** Compromise 1 platform → không ảnh hưởng các platform khác.
> Đây là ưu điểm lớn nhất của kiến trúc self-hosted CNCF so với single-vendor SaaS.
