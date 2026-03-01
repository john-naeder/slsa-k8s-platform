# Kyverno Policies

Thư mục chứa các Kyverno ClusterPolicy / Policy cho cluster.

## Kế hoạch

| Policy | Mô tả | Priority |
|--------|--------|----------|
| `verify-image-signature.yaml` | Verify Cosign signature trên container images | 🔴 High |
| `require-labels.yaml` | Bắt buộc label `app.kubernetes.io/name` | 🟡 Medium |
| `disallow-privileged.yaml` | Block privileged containers | 🟡 Medium |
| `require-resource-limits.yaml` | Bắt buộc CPU/memory limits | 🟢 Low |

## Verify Image Signature (SLSA L3 — core policy)

```yaml
# Sẽ implement khi có Tekton + Cosign pipeline
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-cosign-signature
      match:
        any:
          - resources:
              kinds: ["Pod"]
      verifyImages:
        - imageReferences: ["harbor.kythuat.vn/*"]
          attestors:
            - entries:
                - keyless:
                    issuer: "https://token.actions.githubusercontent.com"
                    subject: "https://github.com/your-org/*"
```

## Usage

```bash
kubectl apply -f verify-image-signature.yaml
kubectl apply -f require-labels.yaml
# ...
```

## Lưu ý

- Test policy mode `Audit` trước khi chuyển sang `Enforce`
- Xem Kyverno docs: https://kyverno.io/docs/writing-policies/
