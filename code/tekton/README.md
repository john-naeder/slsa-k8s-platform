# Tekton Pipelines & Tasks

Thư mục chứa Tekton resources cho SLSA L3 CI/CD pipeline.

## Cấu trúc dự kiến

```
tekton/
├── README.md
├── tasks/
│   ├── git-clone.yaml          # ClusterTask: clone source
│   ├── kaniko-build.yaml       # Task: build image với Kaniko
│   ├── cosign-sign.yaml        # Task: sign image với Cosign (keyless)
│   ├── harbor-push.yaml        # Task: push image lên Harbor
│   └── trivy-scan.yaml         # Task: vulnerability scanning
├── pipelines/
│   ├── build-and-sign.yaml     # Pipeline: clone → build → sign → push
│   └── full-slsa.yaml          # Pipeline: clone → build → sign → attest → push
└── triggers/
    ├── github-webhook.yaml     # EventListener cho GitHub webhook
    └── trigger-template.yaml   # TriggerTemplate tạo PipelineRun
```

## SLSA L3 Pipeline Flow

```
Git Push → GitHub Webhook → Tekton EventListener
    → PipelineRun:
       1. git-clone (fetch source)
       2. kaniko-build (build OCI image — no Docker daemon)
       3. cosign-sign (keyless signing via Fulcio/Rekor)
       4. tekton-chains (auto-generate SLSA provenance)
       5. harbor-push (push signed image + attestation)
    → Argo CD sync → Kyverno verify → Deploy
```

## Tekton Chains Config

Tekton Chains tự động tạo SLSA provenance cho mỗi TaskRun/PipelineRun.
Config qua ConfigMap `chains-config` trong namespace `tekton-chains`:

```yaml
artifacts.taskrun.format: slsa/v1
artifacts.taskrun.storage: oci
artifacts.oci.storage: oci
transparency.enabled: "true"  # Log vào Rekor
```

## Lưu ý

- Tekton Pipelines + Chains được cài qua Helmfile (Option A)
- Cosign keyless signing yêu cầu OIDC provider (Fulcio)
- Xem: https://tekton.dev/docs/ và https://slsa.dev/spec/v1.0/
