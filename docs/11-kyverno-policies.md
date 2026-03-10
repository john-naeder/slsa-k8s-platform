# 11 — Kyverno Supply-Chain Security Policies

> Admission controller thực thi Zero Trust: chặn mọi container image không có signature và SLSA provenance.
> Đây là "enforcement gate" — điểm cuối cùng đảm bảo SLSA L3 compliance.

## Kiến trúc

```
Developer push → Tekton build → Chains sign → Harbor (image + sig + att)
                                                         │
                                                         ▼
ArgoCD sync → create Pod → Kyverno Admission Webhook ──verify──→
                                │                                 │
                                │  ✅ Valid signature + provenance │
                                │  → Pod allowed                  │
                                │                                 │
                                │  ❌ Missing/invalid             │
                                │  → Pod DENIED                   │
                                └─────────────────────────────────┘
```

## Thông tin hiện tại

| Setting | Giá trị |
|---------|---------|
| Kyverno | v3.3.7 (Helm chart) |
| Mode | `Enforce` (chặn thật, không chỉ audit) |
| Scope | Namespace `demo` |
| Image pattern | `harbor.kythuat.vn/demo/*` |
| Registry client | `allowInsecure: true` (Harbor self-signed) |

## 11.1 — Kyverno Deployment (ArgoCD)

Kyverno được deploy bởi ArgoCD:

```yaml
# code/infra/argocd/apps/kyverno.yaml
spec:
  source:
    chart: kyverno
    repoURL: https://kyverno.github.io/kyverno
    targetRevision: "3.3.7"
    helm:
      valuesObject:
        replicaCount: 1
        features:
          registryClient:
            allowInsecure: true    # Harbor self-signed cert
        admissionController:
          replicas: 1
```

> `allowInsecure: true` cho phép Kyverno fetch signature/attestation từ Harbor dù TLS self-signed.

## 11.2 — Policy 1: Verify Image Cosign Signature

```bash
kubectl apply -f code/policies/verify-image-signature.yaml
```

### Policy chi tiết

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
spec:
  validationFailureAction: Enforce     # CHẶN THẬT — không chỉ log
  background: false
  rules:
    - name: verify-harbor-image-signature
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [demo]
      verifyImages:
        - imageReferences:
            - "harbor.kythuat.vn/demo/*"
          attestors:
            - entries:
                - keys:
                    publicKeys: |
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEFL4Fi8Y3AuJE...
                      -----END PUBLIC KEY-----
                    rekor:
                      ignoreTlog: true      # Không dùng Rekor (self-hosted)
                    ctlog:
                      ignoreSCT: true       # Không dùng CT log
```

### Logic

1. Khi có Pod trong namespace `demo` với image `harbor.kythuat.vn/demo/*`
2. Kyverno fetch Cosign signature từ Harbor: `sha256-<digest>.sig`
3. Verify signature bằng embedded public key
4. **PASS** → Pod allowed | **FAIL** → Pod denied

## 11.3 — Policy 2: Verify SLSA Provenance Attestation

```bash
kubectl apply -f code/policies/verify-slsa-provenance.yaml
```

### Policy chi tiết

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-slsa-provenance
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: verify-slsa-provenance
      match:
        any:
          - resources:
              kinds: [Pod]
              namespaces: [demo]
      verifyImages:
        - imageReferences:
            - "harbor.kythuat.vn/demo/*"
          attestations:
            - type: https://slsa.dev/provenance/v0.2
              attestors:
                - entries:
                    - keys:
                        publicKeys: |
                          -----BEGIN PUBLIC KEY-----
                          ...cosign public key...
                          -----END PUBLIC KEY-----
              conditions:
                - all:
                    - key: "{{ builder.id }}"
                      operator: Equals
                      value: "https://tekton.dev/chains/v2"
```

### Logic

1. Khi có Pod trong namespace `demo` với image `harbor.kythuat.vn/demo/*`
2. Kyverno fetch attestation từ Harbor: `sha256-<digest>.att`
3. Verify attestation signature bằng Cosign public key
4. **Kiểm tra nội dung provenance:**
   - `predicateType` = `https://slsa.dev/provenance/v0.2`
   - `builder.id` = `https://tekton.dev/chains/v2` (chứng minh build bởi Tekton)
5. **PASS** → Pod allowed | **FAIL** → Pod denied

## 11.4 — Test Policies

### Test PASS (image hợp lệ — đã ký)

```bash
# Dùng image đã được Tekton build + Chains sign
kubectl -n demo run test-pass \
  --image=harbor.kythuat.vn/demo/demo-api@sha256:<valid-digest> \
  --restart=Never

# → Pod created ✅
kubectl -n demo delete pod test-pass
```

### Test FAIL (image không ký)

```bash
# Dùng image bất kỳ — không có Cosign signature
kubectl -n demo run test-fail --image=nginx:latest --restart=Never

# → Error: admission webhook "mutate.kyverno.svc-fail" denied the request:
#   resource Pod/demo/test-fail was blocked due to the following policies:
#   verify-image-signature: verify-harbor-image-signature: ...
```

### Test FAIL (image khác registry)

```bash
# Image từ registry khác (không match pattern)
kubectl -n demo run test-other --image=docker.io/library/alpine:3.20 --restart=Never
# → Tùy policy scope: có thể pass nếu chỉ match harbor.kythuat.vn/demo/*
```

## 11.5 — Kyverno Policy Reports

```bash
# Xem policy violations
kubectl get policyreport -A
kubectl get clusterpolicyreport

# Chi tiết violations
kubectl get policyreport -n demo -o yaml
```

## 11.6 — Quan hệ với SLSA Level 3

| SLSA Requirement | Implementation |
|------------------|----------------|
| Build as code | Tekton Pipeline YAML in Git |
| Isolated builder | Kaniko (rootless, isolated) |
| Signed provenance | Tekton Chains + Cosign |
| Verification at deployment | **Kyverno Enforce policies** |
| Non-falsifiable provenance | Chains auto-generate (pipeline can't modify) |

## Files liên quan

| File | Mô tả |
|------|-------|
| `policies/verify-image-signature.yaml` | ClusterPolicy: verify Cosign signature |
| `policies/verify-slsa-provenance.yaml` | ClusterPolicy: verify SLSA provenance |
| `infra/argocd/apps/kyverno.yaml` | ArgoCD Application (Helm v3.3.7) |
| `infra/manifests/cosign.pub` | Cosign public key (embedded in policies) |
| `policies/README.md` | Policy documentation |
