# OPTION B — SaaS + LIGHTWEIGHT STACK (GitHub Actions / GitLab CI)
## Checklist Triển khai End-to-End: SLSA Level 3 via SaaS CI/CD

> **Mô tả:** CI/CD chạy trên GitHub Actions (hoặc GitLab CI). Registry dùng GHCR (hoặc GitLab Registry).
> K8s cluster vẫn dùng làm runtime nhưng **KHÔNG cài Tekton, Harbor, Argo CD, Strimzi**.
> Giảm ~60% component, giảm ~50% RAM, triển khai nhanh hơn rất nhiều.
>
> **Triết lý:** Tận dụng SaaS cho CI/CD pipeline → chỉ self-host phần runtime (K8s + policy enforcement).
> Vẫn đạt SLSA Level 3 đầy đủ — đã chứng minh trong plan (I.B).
>
> **Ước tính tài nguyên:** ~3-4 GB RAM, ~10 GB PVC, ~2 CPU cores
>
> **Thời gian deploy platform:** ~3-5 ngày

---

## SO SÁNH VỚI OPTION A

| Khía cạnh | Option A (Full CNCF) | Option B (SaaS) |
|---|---|---|
| **CI/CD** | Tekton Pipelines + Chains | GitHub Actions |
| **Build** | Kaniko (K8s Pod) | Docker build (GH runner) |
| **Signing** | Cosign keyless (Tekton Chains) | Cosign keyless (GH Actions) |
| **Provenance** | Tekton Chains (in-toto) | slsa-github-generator |
| **Registry** | Harbor (self-hosted) | GHCR (GitHub Container Registry) |
| **CD** | Argo CD (GitOps pull-based) | GitHub Actions deploy (`kubectl apply`) |
| **Secrets** | Sealed Secrets (CRD) | GitHub Secrets (SaaS) |
| **Messaging** | Kafka (Strimzi Operator) | ❌ Không cần (1 demo app đơn giản) |
| **Policy** | Kyverno | Kyverno (giống — cần cho K8s admission) |
| **Monitoring** | kube-prometheus-stack + Loki | Metrics Server (built-in) + kubectl logs |
| **Effort** | ~2-3 tuần | ~3-5 ngày |
| **RAM** | ~8-10 GB | ~3-4 GB |
| **Giá trị học thuật** | Rất cao | Trung bình |
| **Enterprise relevance** | Cao (self-hosted) | Thấp hơn (vendor lock-in) |

> **Lưu ý:** Option B hoàn toàn ĐỘC LẬP với Option A — KHÔNG dùng chung CRD nào
> (không Tekton, không Argo CD, không Strimzi, không Harbor).
> Chỉ Kyverno là chung vì nó là admission controller duy nhất trên K8s — không có alternative
> nào làm cùng việc mà nhẹ hơn (OPA Gatekeeper nặng hơn + cần Ratify).

---

## COMPONENT LIST — Chỉ những gì CẦN thiết

### Components DÙNG (Option B):

| # | Component | Vai trò | Nơi chạy | Ghi chú |
|---|---|---|---|---|
| 1 | **K8s (kubeadm)** | Container runtime platform | Bare metal | Giống Option A |
| 2 | **Flannel** | Pod networking | K8s | Giống Option A |
| 3 | **Tailscale** | VPN inter-node | OS-level | Giống Option A |
| 4 | **Helm** | Package manager | CLI | Giống Option A |
| 5 | **local-path-provisioner** | Dynamic PV | K8s | Giống Option A |
| 6 | **Traefik** | Ingress Controller | K8s | Giống Option A |
| 7 | **cloudflared** | Cloudflare Tunnel | K8s | Giống Option A |
| 8 | **Kyverno** | Admission policy (verify images) | K8s | Giống Option A — SLSA enforcement |
| 9 | **GitHub Actions** | CI/CD pipeline | GitHub (SaaS) | **Thay thế Tekton** |
| 10 | **slsa-github-generator** | SLSA L3 provenance | GitHub (SaaS) | **Thay thế Tekton Chains** |
| 11 | **Cosign** | Image signing | GitHub Action step | Keyless (Sigstore OIDC) |
| 12 | **GHCR** | Container registry | GitHub (SaaS) | **Thay thế Harbor** |
| 13 | **cert-manager** | TLS certificates | K8s | Giống Option A |
| 14 | **Metrics Server** | Basic metrics | K8s | **Thay thế Prometheus stack** (built-in, ~50MB) |

### Components KHÔNG DÙNG (đã có trong Option A):

| Component | Lý do bỏ | Thay thế bằng |
|---|---|---|
| ❌ Tekton Pipelines + Chains | SaaS CI/CD thay thế | GitHub Actions + slsa-github-generator |
| ❌ Kaniko | Không cần build trên K8s | Docker build trên GH runner |
| ❌ Harbor | Không cần self-hosted registry | GHCR (miễn phí, OCI-compliant) |
| ❌ Argo CD | Không cần GitOps CD phức tạp | `kubectl apply` từ GH Actions |
| ❌ Sealed Secrets | Không cần CRD cho secrets | GitHub Secrets (encrypted tại rest) |
| ❌ Kafka (Strimzi) | Không cần messaging cho 1 app | Demo app đơn giản, không event-driven |
| ❌ Prometheus + Grafana | Quá nặng cho Option B | Metrics Server + `kubectl top` + `kubectl logs` |
| ❌ Loki + Promtail | Quá nặng cho Option B | `kubectl logs` trực tiếp |
| ❌ Alertmanager | Không cần alerting | — |
| ❌ Syft + Grype | SBOM optional, giữ cho Option A | — (hoặc chạy trong GH Actions nếu muốn) |
| ❌ Istio / Linkerd | Chỉ 1 service, không cần mesh | — |

---

## PHASE 0: Infrastructure Foundation (Tương tự Option A)

> K8s cluster bare metal — dùng chung infrastructure base.

- [ ] **0.1 — Kubernetes cluster (kubeadm v1.32)**
  - Control plane: `100.95.126.102` (Tailscale IP)
  - Worker node(s): `100.94.203.28`
  - Verify: `kubectl get nodes` → tất cả `Ready`

- [ ] **0.2 — Flannel CNI**
  - `--iface=tailscale0` cho cross-node pod networking
  - Verify: `kubectl get pods -n kube-system | grep flannel`

- [ ] **0.3 — Tailscale VPN**
  - Verify: `tailscale status` → tất cả nodes online

- [ ] **0.4 — Helm CLI + Helmfile CLI**
  - Verify: `helm version`
  - Cài Helmfile:
    ```bash
    curl -fsSL https://github.com/helmfile/helmfile/releases/latest/download/helmfile_linux_amd64.tar.gz \
      | sudo tar xz -C /usr/local/bin helmfile
    helmfile --version
    ```
  - Cài helm-diff plugin:
    ```bash
    helm plugin install https://github.com/databus23/helm-diff
    ```
  > **QUAN TRỌNG:** KHÔNG dùng raw `helm install` CLI để setup infra.
  > Xem [plan/infra-deployment-methodology.md](../infra-deployment-methodology.md) để hiểu tại sao.
  >
  > Option B KHÔNG dùng Argo CD → **Helmfile là steady-state manager** cho tất cả K8s components.
  > Helm repos được khai báo trong `helmfile-option-b.yaml` — KHÔNG cần `helm repo add` thủ công.

- [ ] **0.5 — Deploy all K8s components via Helmfile**
  ```bash
  cd code/infra/helmfile/

  # Xem changes TRƯỚC khi apply (audit trail)
  helmfile -f helmfile-option-b.yaml diff

  # Apply (idempotent — chạy bao nhiêu lần cũng được)
  helmfile -f helmfile-option-b.yaml apply

  # Verify all releases deployed
  helmfile -f helmfile-option-b.yaml list
  ```
  > Helmfile cài: cert-manager, Traefik, Kyverno (3 Helm releases).
  > File `helmfile-option-b.yaml` + `values/*.yaml` = source of truth, version-controlled.

- [ ] **0.6 — Post-Helmfile: non-Helm components**
  ```bash
  # local-path-provisioner
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-provisioner.yaml
  kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

  # cloudflared (token via K8s Secret — xem code/infra/manifests/cloudflared/README.md)
  kubectl apply -f ../manifests/cloudflared/namespace.yaml
  kubectl create secret generic cloudflared-token \
    --namespace=cloudflare \
    --from-literal=tunnel-token=<YOUR_TUNNEL_TOKEN>
  kubectl apply -f ../manifests/cloudflared/deployment.yaml

  # Metrics Server
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  kubectl patch deployment metrics-server -n kube-system --type='json' \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

  # Demo namespace
  kubectl create namespace demo
  ```
  > Chỉ 5 namespaces — so với 12+ của Option A.

---

## PHASE 1: Storage + TLS

> ✅ **cert-manager** đã được cài qua Helmfile (Phase 0.5).
> ✅ **local-path-provisioner** đã được cài qua kubectl (Phase 0.6).

- [ ] **1.1 — local-path-provisioner**
  > ✅ **ĐÃ CÀI** tại Phase 0.6.
  - Verify: `kubectl get storageclass`

- [ ] **1.2 — cert-manager**
  > ✅ **ĐÃ CÀI QUA HELMFILE** — xem `code/infra/helmfile/values/cert-manager.yaml`
  - Tạo ClusterIssuer (Let's Encrypt):
    ```yaml
    apiVersion: cert-manager.io/v1
    kind: ClusterIssuer
    metadata:
      name: letsencrypt-staging
    spec:
      acme:
        server: https://acme-staging-v02.api.letsencrypt.org/directory
        email: your-email@example.com
        privateKeySecretRef:
          name: letsencrypt-staging-key
        solvers:
          - http01:
              ingress:
                class: traefik
    ```
  - Verify: `kubectl get clusterissuer` → Ready

---

## PHASE 2: Networking & Exposure

> ✅ **Traefik** đã được cài qua Helmfile (Phase 0.5).
> ✅ **cloudflared** đã được cài qua kubectl (Phase 0.6).

- [ ] **2.1 — Traefik Ingress Controller**
  > ✅ **ĐÃ CÀI QUA HELMFILE** — xem `code/infra/helmfile/values/traefik.yaml`
  - Verify: `kubectl get pods -n traefik`

- [ ] **2.2 — cloudflared (Cloudflare Tunnel)**
  - Tạo tunnel + DNS record:
    ```bash
    cloudflared tunnel create thesis-b-tunnel
    cloudflared tunnel route dns thesis-b-tunnel "demo-b.kythuat.vn"
    ```
  - Deploy cloudflared trong K8s namespace `cloudflare`:
    ```yaml
    # ConfigMap ingress → route tới traefik.traefik.svc.cluster.local:8000
    ```
  - Verify:
    ```bash
    kubectl get pods -n cloudflare
    curl -I https://demo-b.kythuat.vn
    ```

- [ ] **2.3 — DNS records**
  - `demo-b.kythuat.vn` → tunnel (demo app)
  - (Không cần harbor, grafana, argocd domains — không có những components đó)

---

## PHASE 3: Policy Engine — Kyverno

> Giống Option A — Kyverno là admission controller duy nhất, cần cho SLSA enforcement.
> Verify image signature + provenance tại thời điểm deploy.
> ✅ **Kyverno** đã được cài qua Helmfile (Phase 0.5).

- [ ] **3.1 — Kyverno**
  > ✅ **ĐÃ CÀI QUA HELMFILE** — xem `code/infra/helmfile/values/kyverno.yaml`
  - Verify: `kubectl get pods -n kyverno`

- [ ] **3.2 — Policy: Verify image signature từ GHCR**
  ```yaml
  apiVersion: kyverno.io/v1
  kind: ClusterPolicy
  metadata:
    name: verify-ghcr-image-signature
  spec:
    validationFailureAction: Enforce
    background: false
    rules:
      - name: verify-cosign-signature
        match:
          any:
            - resources:
                kinds: ["Pod"]
                namespaces: ["demo"]
        verifyImages:
          - imageReferences:
              - "ghcr.io/<your-org>/*"
            attestors:
              - entries:
                  - keyless:
                      issuer: "https://token.actions.githubusercontent.com"
                      subject: "https://github.com/<your-org>/<repo>/.github/workflows/*"
                      rekor:
                        url: "https://rekor.sigstore.dev"
  ```

- [ ] **3.3 — Policy: Verify SLSA provenance (slsa-github-generator)**
  ```yaml
  apiVersion: kyverno.io/v1
  kind: ClusterPolicy
  metadata:
    name: verify-slsa-provenance-github
  spec:
    validationFailureAction: Enforce
    rules:
      - name: check-github-provenance
        match:
          any:
            - resources:
                kinds: ["Pod"]
                namespaces: ["demo"]
        verifyImages:
          - imageReferences:
              - "ghcr.io/<your-org>/*"
            attestations:
              - type: https://slsa.dev/provenance/v1
                conditions:
                  - all:
                      - key: "{{ buildDefinition.buildType }}"
                        operator: Equals
                        value: "https://github.com/slsa-framework/slsa-github-generator/delegator-generic@v0"
  ```

---

## PHASE 4: GitHub Actions CI/CD Pipeline (SaaS)

> Thay thế hoàn toàn Tekton + Chains + Kaniko + Harbor.
> Build trên GH runner → Sign bằng Cosign keyless → Provenance bằng slsa-github-generator → Push lên GHCR.

- [ ] **4.1 — GitHub repository setup**
  - Tạo repo: `<your-org>/demo-app-b`
  - Enable GHCR:
    ```
    Settings → Packages → Enable GitHub Packages
    ```
  - Enable Branch Protection (Source Track L3):
    ```
    Settings → Branches → main:
      ✅ Require pull request before merging
      ✅ Require status checks to pass
      ✅ Block force pushes
      ✅ Block branch deletion
    ```

- [ ] **4.2 — GitHub Actions: Build + Push to GHCR**
  ```yaml
  # .github/workflows/build.yml
  name: Build and Push
  on:
    push:
      branches: [main]

  permissions:
    contents: read
    packages: write
    id-token: write       # Cần cho Cosign keyless signing

  jobs:
    build:
      runs-on: ubuntu-latest
      outputs:
        image: ${{ steps.meta.outputs.tags }}
        digest: ${{ steps.build.outputs.digest }}
      steps:
        - name: Checkout
          uses: actions/checkout@v4

        - name: Login to GHCR
          uses: docker/login-action@v3
          with:
            registry: ghcr.io
            username: ${{ github.actor }}
            password: ${{ secrets.GITHUB_TOKEN }}

        - name: Docker meta
          id: meta
          uses: docker/metadata-action@v5
          with:
            images: ghcr.io/${{ github.repository }}
            tags: |
              type=sha,prefix=
              type=ref,event=branch

        - name: Build and Push
          id: build
          uses: docker/build-push-action@v6
          with:
            context: .
            push: true
            tags: ${{ steps.meta.outputs.tags }}
  ```

- [ ] **4.3 — GitHub Actions: Cosign Sign (keyless)**
  ```yaml
  # Thêm vào workflow sau build step:
    sign:
      needs: build
      runs-on: ubuntu-latest
      permissions:
        packages: write
        id-token: write
      steps:
        - name: Install Cosign
          uses: sigstore/cosign-installer@v3

        - name: Login to GHCR
          uses: docker/login-action@v3
          with:
            registry: ghcr.io
            username: ${{ github.actor }}
            password: ${{ secrets.GITHUB_TOKEN }}

        - name: Sign image
          env:
            COSIGN_EXPERIMENTAL: "true"
          run: |
            cosign sign --yes ghcr.io/${{ github.repository }}@${{ needs.build.outputs.digest }}
  ```

- [ ] **4.4 — SLSA Provenance (slsa-github-generator)**
  ```yaml
  # .github/workflows/slsa-provenance.yml
  # Sử dụng reusable workflow từ slsa-framework
  name: SLSA Provenance
  on:
    workflow_run:
      workflows: ["Build and Push"]
      types: [completed]

  # Hoặc tích hợp trực tiếp:
  jobs:
    provenance:
      needs: build
      permissions:
        actions: read
        id-token: write
        packages: write
      uses: slsa-framework/slsa-github-generator/.github/workflows/generator_container_slsa3.yml@v2.1.0
      with:
        image: ghcr.io/${{ github.repository }}
        digest: ${{ needs.build.outputs.digest }}
        registry-username: ${{ github.actor }}
      secrets:
        registry-password: ${{ secrets.GITHUB_TOKEN }}
  ```
  - Verify provenance:
    ```bash
    cosign verify-attestation \
      --type slsaprovenance \
      --certificate-identity-regexp "https://github.com/slsa-framework/slsa-github-generator" \
      --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
      ghcr.io/<your-org>/demo-app-b@sha256:<digest>
    ```

- [ ] **4.5 — GitHub Actions: Deploy to K8s**
  ```yaml
  # Thêm vào workflow:
    deploy:
      needs: [build, sign, provenance]
      runs-on: ubuntu-latest
      steps:
        - name: Checkout
          uses: actions/checkout@v4

        - name: Setup kubeconfig
          # Option 1: Tailscale + kubeconfig qua GitHub Secret
          # Option 2: Self-hosted runner trên cluster
          run: |
            echo "${{ secrets.KUBECONFIG }}" | base64 -d > /tmp/kubeconfig
            export KUBECONFIG=/tmp/kubeconfig

        - name: Update image in manifest
          run: |
            cd k8s
            kustomize edit set image \
              demo-app=ghcr.io/${{ github.repository }}@${{ needs.build.outputs.digest }}

        - name: Deploy
          run: |
            kubectl apply -k k8s/ -n demo
            kubectl rollout status deployment/demo-app -n demo --timeout=120s
  ```

  > **Lưu ý bảo mật:** Cần cung cấp kubeconfig cho GitHub Actions.
  > Cách an toàn nhất: dùng **self-hosted runner** chạy trên cluster.
  > Hoặc: tạo dedicated ServiceAccount với RBAC hạn chế → export kubeconfig → lưu trong GitHub Secrets.

- [ ] **4.6 — (Optional) SBOM trên GitHub Actions**
  ```yaml
  # Thêm step nếu muốn SBOM:
    - name: Generate SBOM
      uses: anchore/sbom-action@v0
      with:
        image: ghcr.io/${{ github.repository }}@${{ needs.build.outputs.digest }}
        format: spdx-json
        output-file: sbom.spdx.json

    - name: Attach SBOM to image
      run: |
        cosign attach sbom --sbom sbom.spdx.json \
          ghcr.io/${{ github.repository }}@${{ needs.build.outputs.digest }}
  ```

---

## PHASE 5: Demo Application — Single Service (Đơn giản)

> Option B chỉ cần 1 service đơn giản — không cần Kafka, không cần multi-service.
> Mục tiêu: chứng minh SLSA L3 pipeline end-to-end.

- [ ] **5.1 — Demo app (Go or Node.js)**
  - Repo structure:
    ```
    demo-app-b/
    ├── .github/
    │   └── workflows/
    │       ├── build.yml              # Build + Sign + Provenance
    │       └── deploy.yml             # Deploy to K8s
    ├── Dockerfile
    ├── main.go (hoặc index.js)
    ├── go.mod / package.json
    └── k8s/
        ├── deployment.yaml
        ├── service.yaml
        ├── kustomization.yaml
        └── ingress.yaml               # Traefik IngressRoute
    ```
  - Endpoints (đơn giản):
    | Endpoint | Mô tả |
    |---|---|
    | `GET /` | Hello + build info (commit SHA, build time) |
    | `GET /healthz` | Health check |
    | `GET /info` | Image digest, signature status, provenance link |

- [ ] **5.2 — K8s Deployment manifest**
  ```yaml
  apiVersion: apps/v1
  kind: Deployment
  metadata:
    name: demo-app
    namespace: demo
  spec:
    replicas: 1
    selector:
      matchLabels:
        app: demo-app
    template:
      metadata:
        labels:
          app: demo-app
      spec:
        containers:
          - name: demo-app
            image: ghcr.io/<your-org>/demo-app-b@sha256:<digest>
            ports:
              - containerPort: 8080
            livenessProbe:
              httpGet:
                path: /healthz
                port: 8080
            readinessProbe:
              httpGet:
                path: /healthz
                port: 8080
            resources:
              requests:
                memory: 64Mi
                cpu: 50m
              limits:
                memory: 128Mi
  ---
  apiVersion: v1
  kind: Service
  metadata:
    name: demo-app
    namespace: demo
  spec:
    selector:
      app: demo-app
    ports:
      - port: 8080
        targetPort: 8080
  ```

- [ ] **5.3 — Traefik IngressRoute cho demo app**
  ```yaml
  apiVersion: traefik.io/v1alpha1
  kind: IngressRoute
  metadata:
    name: demo-app
    namespace: demo
  spec:
    entryPoints: [web]
    routes:
      - match: Host(`demo-b.kythuat.vn`)
        kind: Rule
        services:
          - name: demo-app
            port: 8080
  ```

- [ ] **5.4 — Verify deployment**
  ```bash
  kubectl get pods -n demo             # Running
  curl https://demo-b.kythuat.vn/
  curl https://demo-b.kythuat.vn/healthz
  curl https://demo-b.kythuat.vn/info
  ```

---

## PHASE 6: Monitoring (Minimal)

> Option B dùng giải pháp nhẹ — không cần full Prometheus stack.

- [ ] **6.1 — Metrics Server (K8s built-in)**
  > ✅ **ĐÃ CÀI** tại Phase 0.6.
  - Verify:
    ```bash
    kubectl top nodes
    kubectl top pods -n demo
    ```

- [ ] **6.2 — Monitoring via kubectl (không cần Grafana)**
  ```bash
  # Node resources
  kubectl top nodes

  # Pod resources
  kubectl top pods --all-namespaces --sort-by=memory

  # Logs
  kubectl logs -n demo -l app=demo-app --tail=100 -f

  # Events
  kubectl get events -n demo --sort-by='.lastTimestamp'
  ```

---

## PHASE 7: Validation & Attack Scenarios

> Tương tự Option A — chứng minh SLSA L3 compliance.
> Kyverno vẫn chặn image không hợp lệ.

- [ ] **7.1 — Happy Path**
  ```bash
  # GH Actions build → sign → provenance → push GHCR → deploy → Kyverno verify → Running
  kubectl get pods -n demo   # Running ✅
  ```

- [ ] **7.2 — Attack: Unsigned image**
  ```bash
  kubectl run evil --image=nginx:latest -n demo
  # Expected: denied by Kyverno
  ```

- [ ] **7.3 — Attack: Image without GitHub provenance**
  ```bash
  # Build locally → push to GHCR → deploy (no slsa-github-generator provenance)
  # Expected: denied by Kyverno provenance policy
  ```

- [ ] **7.4 — Attack: Image from unauthorized workflow**
  ```bash
  # Build từ workflow khác (không phải slsa-github-generator reusable workflow)
  # Expected: builder identity mismatch → denied
  ```

- [ ] **7.5 — Attack: Modified image after signing**
  ```bash
  # Tag lại image → digest mismatch → denied
  ```

---

## PHASE 8: So sánh Option A vs Option B (Nội dung cho thesis)

> Nếu chạy được CẢ 2 options → bảng so sánh rất có giá trị cho Chương 4.

- [ ] **8.1 — Bảng so sánh CI/CD: Tekton vs GitHub Actions**
  | Tiêu chí | Tekton (Option A) | GitHub Actions (Option B) |
  |---|---|---|
  | SLSA L3 compliance | ✅ | ✅ |
  | Setup complexity | Cao (CRDs, RBAC, config) | Thấp (YAML workflow) |
  | K8s-native | ✅ (CRDs) | ❌ (external SaaS) |
  | Build isolation | Pod-level | VM-level |
  | Control | Full (self-hosted) | Phụ thuộc GitHub |
  | Separation of concerns | Source ≠ Build platform | Same vendor |
  | Cost | Free (tốn compute K8s) | Free (2000 min/month private repos) |
  | Enterprise fit | Cao (data sovereignty) | Thấp hơn (vendor lock-in) |

- [ ] **8.2 — Bảng so sánh Registry: Harbor vs GHCR**
  | Tiêu chí | Harbor (Option A) | GHCR (Option B) |
  |---|---|---|
  | Self-hosted | ✅ | ❌ (SaaS) |
  | Vuln scanning | ✅ Trivy built-in | ❌ (cần thêm tool) |
  | OCI artifacts | ✅ Full | ✅ Full |
  | Setup | Phức tạp (Helm, TLS, PV) | Không cần (đã có) |
  | RAM | ~1.5 GB | 0 |

- [ ] **8.3 — Performance benchmark**
  - Pipeline time: Tekton (Option A) vs GH Actions (Option B)
  - Deploy time: Argo CD sync vs kubectl apply
  - Admission verify time: Kyverno (giống nhau cả 2 options)
  - Resource usage: Cluster RAM/CPU với full stack vs minimal stack

- [ ] **8.4 — Security posture comparison**
  - Trust boundaries: Option A (3+ boundaries) vs Option B (1-2 boundaries)
  - Blast radius nếu CI/CD bị compromise
  - Key management: keyless (cả 2) nhưng signing identity khác nhau

---

## TỔNG KẾT — OPTION B COMPONENT COUNT

| Layer | Component | Ưu tiên | Ở đâu |
|---|---|---|---|
| **Infrastructure** | K8s, Flannel, Tailscale, Helm, local-path-provisioner | 🔴 CRITICAL | K8s |
| **TLS** | cert-manager | 🟠 HIGH | K8s |
| **Networking** | Traefik + cloudflared | 🔴 CRITICAL | K8s |
| **Policy** | Kyverno | 🔴 CRITICAL | K8s |
| **CI/CD** | GitHub Actions | 🔴 CRITICAL | SaaS |
| **Provenance** | slsa-github-generator | 🔴 CRITICAL | SaaS |
| **Signing** | Cosign (keyless) | 🔴 CRITICAL | SaaS (GH Action) |
| **Registry** | GHCR | 🔴 CRITICAL | SaaS |
| **Monitoring** | Metrics Server | 🟡 NICE | K8s |
| **App** | demo-app (single service) | 🔴 CRITICAL | K8s |

**Tổng: ~10 components trên K8s + 4 SaaS services = ~14 components**
(so với ~21 components của Option A)

---

## QUICK REFERENCE — Kiểm tra nhanh Option B

```bash
# === Cluster health ===
kubectl get nodes
kubectl get pods --all-namespaces | grep -v Running

# === Infrastructure ===
kubectl get storageclass
kubectl get pods -n cert-manager
kubectl get clusterissuer

# === Networking ===
kubectl get pods -n traefik
kubectl get pods -n cloudflare
kubectl get ingressroute --all-namespaces

# === Security ===
kubectl get pods -n kyverno
kubectl get clusterpolicy

# === Demo ===
kubectl get pods -n demo
curl -s https://demo-b.kythuat.vn/healthz

# === Monitoring ===
kubectl top nodes
kubectl top pods -n demo

# === Verify SLSA on GHCR ===
cosign verify ghcr.io/<your-org>/demo-app-b@sha256:<digest>
cosign verify-attestation --type slsaprovenance \
  ghcr.io/<your-org>/demo-app-b@sha256:<digest>
```

---

## TIMELINE GỢI Ý — Option B (3-5 ngày)

```
Ngày 1:  Infrastructure
         ✅ K8s cluster ready (đã có)
         ✅ local-path-provisioner + cert-manager
         ✅ Traefik + cloudflared

Ngày 2:  Policy + CI/CD
         ✅ Kyverno + policies
         ✅ GitHub Actions: build + sign workflow
         ✅ slsa-github-generator workflow

Ngày 3:  Demo App
         ✅ Viết demo-app (Go/Node.js) — endpoints đơn giản
         ✅ Dockerfile + K8s manifests
         ✅ Deploy lần đầu qua GH Actions

Ngày 4:  Validation
         ✅ Test SLSA L3: happy path + attack scenarios
         ✅ Verify signature + provenance trên GHCR
         ✅ Screenshot kết quả

Ngày 5:  (Optional) Polish
         ✅ SBOM generation (Syft trong GH Actions)
         ✅ Cleanup, documentation
         ✅ So sánh notes cho thesis
```
