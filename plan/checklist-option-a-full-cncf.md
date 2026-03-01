# OPTION A — FULL CNCF SELF-HOSTED ON KUBERNETES
## Checklist Triển khai End-to-End: SLSA Level 3 + Microservices Platform

> **Mô tả:** Tất cả components chạy self-hosted trên bare metal K8s cluster.
> CI/CD, Registry, CD, Policy, Observability — mọi thứ là K8s-native CRDs.
> Effort cao nhất, giá trị học thuật & enterprise relevance cao nhất.
>
> **Ước tính tài nguyên:** ~8 GB RAM (không Istio) / ~10 GB RAM (có Istio), ~25 GB PVC, ~4 CPU cores
>
> **Thời gian deploy platform:** ~2-3 tuần (nếu đã quen K8s)

---

## PHASE 0: Infrastructure Foundation (Đã có — via Ansible)

> K8s cluster bare metal qua Tailscale VPN, Ubuntu Server 24.04.

- [ ] **0.1 — Kubernetes cluster (kubeadm v1.32)**
  - Control plane: `100.95.126.102` (Tailscale IP)
  - Worker node(s): `100.94.203.28`
  - Verify: `kubectl get nodes` → tất cả `Ready`

- [ ] **0.2 — Flannel CNI**
  - Cấu hình: `--iface=tailscale0` cho cross-node pod networking
  - Pod CIDR: `10.244.0.0/16`
  - Verify: `kubectl get pods -n kube-system | grep flannel`

- [ ] **0.3 — Tailscale VPN**
  - Đã cài thủ công + bootstrap scripts
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
  > **Chiến lược 2-phase:**
  > - **Bootstrap** (Helmfile): cert-manager, Traefik, Sealed Secrets, Argo CD
  > - **Steady-state** (Argo CD App-of-Apps): Harbor, Tekton, Kyverno, Strimzi, Monitoring, Demo
  >
  > Helm repos được khai báo trong `helmfile-bootstrap.yaml` — KHÔNG cần `helm repo add` thủ công.

- [ ] **0.5 — Bootstrap platform via Helmfile**
  ```bash
  cd code/infra/helmfile/

  # Xem changes TRƯỚC khi apply (audit trail)
  helmfile -f helmfile-bootstrap.yaml diff

  # Apply (idempotent — chạy bao nhiêu lần cũng được)
  helmfile -f helmfile-bootstrap.yaml apply

  # Verify all releases deployed
  helmfile -f helmfile-bootstrap.yaml list
  ```
  > Helmfile sẽ tự động: tạo namespaces, add repos, install releases theo đúng thứ tự dependencies.
  > File `helmfile-bootstrap.yaml` + `values/*.yaml` = source of truth, version-controlled trong Git.

- [ ] **0.6 — Post-bootstrap: non-Helm components**
  ```bash
  # local-path-provisioner (raw YAML manifest, không phải Helm chart)
  kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-provisioner.yaml
  kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

  # cloudflared (token via K8s Secret — xem code/infra/manifests/cloudflared/README.md)
  kubectl apply -f ../manifests/cloudflared/namespace.yaml
  kubectl create secret generic cloudflared-token \
    --namespace=cloudflare \
    --from-literal=tunnel-token=<YOUR_TUNNEL_TOKEN>
  kubectl apply -f ../manifests/cloudflared/deployment.yaml

  # Demo namespace
  kubectl create namespace demo
  ```

- [ ] **0.7 — Bootstrap Argo CD App-of-Apps (steady-state)**
  ```bash
  # Kích hoạt Argo CD quản lý TẤT CẢ remaining components
  kubectl apply -f ../argocd/app-of-apps.yaml

  # Verify: Argo CD dashboard sẽ hiển thị tất cả Applications
  kubectl get applications -n argocd
  ```
  > Từ đây, mọi thay đổi config = Git commit → Argo CD auto-deploy.
  > KHÔNG cần chạy `helm install` thủ công cho bất kỳ component nào nữa.

---

## PHASE 1: Storage + TLS Foundation

> Mọi PVC và TLS cert phụ thuộc vào 2 component này. Phải cài TRƯỚC mọi thứ khác.
> ✅ **cert-manager** đã được cài qua Helmfile bootstrap (Phase 0.5).
> ✅ **local-path-provisioner** đã được cài qua kubectl (Phase 0.6).

- [ ] **1.1 — local-path-provisioner (Rancher)**
  - Install:
    ```bash
    kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-provisioner.yaml
    ```
  - Set default StorageClass:
    ```bash
    kubectl patch storageclass local-path -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'
    ```
  - Verify:
    ```bash
    kubectl get storageclass           # local-path (default)
    kubectl get pods -n local-path-storage
    ```
  - Test PVC binding:
    ```bash
    # Tạo PVC test → verify Bound → xóa
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
    kubectl get pvc test-pvc           # STATUS: Bound
    kubectl delete pvc test-pvc
    ```

- [ ] **1.2 — cert-manager**
  > ✅ **ĐÃ CÀI QUA HELMFILE** — xem `code/infra/helmfile/values/cert-manager.yaml`
  > Không cần `helm install` thủ công. Chỉ cần verify + tạo ClusterIssuer.
  - Verify:
    ```bash
    kubectl get pods -n cert-manager   # 3 pods: controller, webhook, cainjector
    kubectl get crds | grep cert-manager
    ```
  - Tạo ClusterIssuer (Let's Encrypt staging trước → production sau):
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
  - Verify: `kubectl get clusterissuer` → Ready = True

---

## PHASE 2: Networking & Exposure

> Traefik làm Ingress Controller, cloudflared tạo tunnel ra internet.
> Luồng: Internet → Cloudflare CDN → cloudflared Pod → Traefik → K8s Service → App Pod
> ✅ **Traefik** đã được cài qua Helmfile bootstrap (Phase 0.5).
> ✅ **cloudflared** đã được cài qua kubectl (Phase 0.6).

- [ ] **2.1 — Traefik Ingress Controller**
  > ✅ **ĐÃ CÀI QUA HELMFILE** — xem `code/infra/helmfile/values/traefik.yaml`
  - Verify:
    ```bash
    kubectl get pods -n traefik
    kubectl get svc -n traefik
    kubectl get crds | grep traefik   # IngressRoute, Middleware, etc.
    ```
  - Test IngressRoute CRD:
    ```yaml
    apiVersion: traefik.io/v1alpha1
    kind: IngressRoute
    metadata:
      name: traefik-dashboard
      namespace: traefik
    spec:
      entryPoints: [web]
      routes:
        - match: Host(`traefik.local`)
          kind: Rule
          services:
            - name: api@internal
              kind: TraefikService
    ```

- [ ] **2.2 — cloudflared (Cloudflare Tunnel)**
  - Tạo tunnel trên Cloudflare dashboard hoặc CLI:
    ```bash
    cloudflared tunnel create thesis-tunnel
    cloudflared tunnel route dns thesis-tunnel "*.kythuat.vn"
    ```
  - Tạo K8s Secret chứa tunnel credentials:
    ```bash
    kubectl create secret generic cloudflared-credentials \
      --namespace cloudflare \
      --from-file=credentials.json=$HOME/.cloudflared/<tunnel-id>.json
    ```
  - Deploy cloudflared:
    ```yaml
    # ConfigMap + Deployment trong namespace cloudflare
    # ingress rules → route tới traefik.traefik.svc.cluster.local:8000
    ```
  - Verify:
    ```bash
    kubectl get pods -n cloudflare     # Running
    kubectl logs -n cloudflare -l app=cloudflared
    curl -I https://demo.kythuat.vn   # từ internet
    ```

- [ ] **2.3 — DNS records trên Cloudflare**
  - `demo.kythuat.vn` → tunnel
  - `harbor.kythuat.vn` → tunnel
  - `grafana.kythuat.vn` → tunnel
  - `argocd.kythuat.vn` → tunnel
  - `tekton.kythuat.vn` → tunnel (nếu cần dashboard)

---

## PHASE 3: Secrets Management

> ✅ **Sealed Secrets** đã được cài qua Helmfile bootstrap (Phase 0.5).

- [ ] **3.1 — Sealed Secrets (Bitnami)**
  > ✅ **ĐÃ CÀI QUA HELMFILE** — xem `code/infra/helmfile/values/sealed-secrets.yaml`
  - Install CLI:
    ```bash
    # kubeseal CLI
    brew install kubeseal   # hoặc download binary
    ```
  - Verify:
    ```bash
    kubectl get pods -n sealed-secrets
    kubeseal --fetch-cert --controller-namespace sealed-secrets
    ```
  - Test encrypt/decrypt:
    ```bash
    kubectl create secret generic test-secret \
      --from-literal=password=mypassword \
      --dry-run=client -o yaml | \
    kubeseal --controller-namespace sealed-secrets -o yaml > sealed-test.yaml
    kubectl apply -f sealed-test.yaml
    kubectl get secret test-secret     # decrypted by controller
    kubectl delete secret test-secret && rm sealed-test.yaml
    ```

---

## PHASE 4: OCI Registry — Harbor

> Harbor là trung tâm lưu trữ: container images, Cosign signatures, SBOM, provenance attestations.
> ✅ **MANAGED BY ARGO CD** — xem `code/infra/argocd/apps/harbor.yaml`
> Argo CD auto-sync từ Git → không cần `helm install` thủ công.

- [ ] **4.1 — Harbor (self-hosted OCI Registry)**
  > ✅ **MANAGED BY ARGO CD** — config tại `code/infra/argocd/apps/harbor.yaml`
  > Muốn thay đổi config? → Sửa file YAML → commit → Argo CD auto-apply.
  - Verify Argo CD đã sync:
    ```bash
    kubectl get application harbor -n argocd    # Healthy + Synced
    ```
  - Tạo Traefik IngressRoute cho Harbor:
    ```yaml
    apiVersion: traefik.io/v1alpha1
    kind: IngressRoute
    metadata:
      name: harbor
      namespace: harbor
    spec:
      entryPoints: [web]
      routes:
        - match: Host(`harbor.kythuat.vn`)
          kind: Rule
          services:
            - name: harbor-core
              port: 80
    ```
  - Verify:
    ```bash
    kubectl get pods -n harbor         # Tất cả Running (core, registry, portal, redis, db, trivy)
    # Truy cập https://harbor.kythuat.vn
    # Login: admin / <password-from-secret>
    ```
  - Tạo project trên Harbor:
    - `demo` — chứa demo-api, demo-worker images
  - Cấu hình Docker/containerd trust Harbor cert:
    ```bash
    # Trên mỗi node nếu cần pull image từ Harbor
    # Hoặc config containerd để trust Harbor TLS
    ```
  - Test push/pull:
    ```bash
    docker tag alpine:latest harbor.kythuat.vn/demo/test:v1
    docker push harbor.kythuat.vn/demo/test:v1
    docker pull harbor.kythuat.vn/demo/test:v1
    ```

---

## PHASE 5: CI/CD Engine — Tekton + Chains + Cosign (SLSA L3 Core)

> Đây là CORE của toàn bộ SLSA L3 implementation.
> Tekton chạy build → Chains observe → tạo provenance + ký bằng Cosign → push attestation lên Harbor.

- [ ] **5.1 — Tekton Pipelines**
  - Install:
    ```bash
    kubectl apply --filename https://storage.googleapis.com/tekton-releases/pipeline/latest/release.yaml
    ```
  - Verify:
    ```bash
    kubectl get pods -n tekton-pipelines
    kubectl get crds | grep tekton
    # Phải thấy: pipelines, tasks, pipelineruns, taskruns, etc.
    ```

- [ ] **5.2 — Tekton Chains (provenance + signing)**
  - Install:
    ```bash
    kubectl apply --filename https://storage.googleapis.com/tekton-releases/chains/latest/release.yaml
    ```
  - Config Chains cho Cosign signing:
    ```bash
    # Config signing backend
    kubectl patch configmap chains-config -n tekton-chains \
      -p='{"data":{
        "artifacts.taskrun.format": "in-toto",
        "artifacts.taskrun.storage": "oci",
        "artifacts.oci.storage": "oci",
        "transparency.enabled": "true",
        "signers.x509.fulcio.enabled": "true"
      }}'
    ```
  - (Alternative) Key-based signing nếu không dùng keyless:
    ```bash
    cosign generate-key-pair k8s://tekton-chains/signing-secrets
    ````
  - Verify:
    ```bash
    kubectl get pods -n tekton-chains
    kubectl get configmap chains-config -n tekton-chains -o yaml
    ```

- [ ] **5.3 — Cosign CLI (image signing & verification)**
  - Install:
    ```bash
    # https://docs.sigstore.dev/cosign/system_config/installation/
    go install github.com/sigstore/cosign/v2/cmd/cosign@latest
    # hoặc brew install cosign
    ```
  - Verify:
    ```bash
    cosign version
    # Test sign & verify (manual — để hiểu flow trước khi automate)
    cosign sign harbor.kythuat.vn/demo/test:v1
    cosign verify harbor.kythuat.vn/demo/test:v1
    ```

- [ ] **5.4 — Kaniko (rootless image build)**
  - Không cần install riêng — chạy như Tekton Task image:
    ```yaml
    # Trong Tekton Task:
    steps:
      - name: build-and-push
        image: gcr.io/kaniko-project/executor:latest
        args:
          - --dockerfile=$(params.dockerfile)
          - --context=$(workspaces.source.path)
          - --destination=$(params.image):$(params.tag)
          - --digest-file=$(results.IMAGE_DIGEST.path)
    ```
  - Verify: Chạy Tekton PipelineRun → image pushed lên Harbor

- [ ] **5.5 — Tekton Pipeline cho demo-api**
  - Viết Pipeline YAML:
    ```
    Task 1: git-clone         → clone source code
    Task 2: kaniko-build       → build + push image to Harbor
    Task 3: (Chains auto)      → Chains observe TaskRun → sign + provenance
    ```
  - Viết PipelineRun trigger (manual hoặc webhook)
  - Verify: image trên Harbor có signature + attestation
    ```bash
    cosign verify harbor.kythuat.vn/demo/demo-api:latest
    cosign verify-attestation harbor.kythuat.vn/demo/demo-api:latest
    ```

- [ ] **5.6 — Tekton Pipeline cho demo-worker**
  - Tương tự demo-api — pipeline riêng, image riêng
  - Verify: cả 2 images đều có signature + provenance

- [ ] **5.7 — SBOM generation (Syft) + Vulnerability scan (Grype)**
  - Thêm Task vào Pipeline:
    ```yaml
    # Task: syft-sbom
    steps:
      - name: generate-sbom
        image: anchore/syft:latest
        args: ["packages", "$(params.image)", "-o", "spdx-json"]
    
    # Task: grype-scan
    steps:
      - name: scan-vulns
        image: anchore/grype:latest
        args: ["$(params.image)"]
    ```
  - Attach SBOM lên Harbor:
    ```bash
    cosign attach sbom --sbom sbom.spdx.json harbor.kythuat.vn/demo/demo-api:latest
    ```
  - Verify: `cosign verify-attestation --type spdxjson ...`

---

## PHASE 6: Policy Engine — Kyverno (Admission Control)

> Kyverno chặn mọi image không có signature/provenance tại thời điểm deploy.
> Đây là "gate" Zero Trust — deny-by-default.
> ✅ **MANAGED BY ARGO CD** — xem `code/infra/argocd/apps/kyverno.yaml`

- [ ] **6.1 — Kyverno**
  > ✅ **MANAGED BY ARGO CD** — config tại `code/infra/argocd/apps/kyverno.yaml`
  - Verify Argo CD đã sync:
    ```bash
    kubectl get pods -n kyverno
    kubectl get crds | grep kyverno   # ClusterPolicy, Policy, PolicyReport
    ```

- [ ] **6.2 — Policy: Verify image signature (Cosign)**
  ```yaml
  apiVersion: kyverno.io/v1
  kind: ClusterPolicy
  metadata:
    name: verify-image-signature
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
              - "harbor.kythuat.vn/demo/*"
            attestors:
              - entries:
                  - keyless:
                      # Keyless (Sigstore OIDC)
                      issuer: "https://token.actions.githubusercontent.com"  # hoặc issuer tương ứng
                      subject: "..."
                    # Hoặc key-based:
                    # keys:
                    #   publicKeys: |-
                    #     -----BEGIN PUBLIC KEY-----
                    #     ...
                    #     -----END PUBLIC KEY-----
  ```

- [ ] **6.3 — Policy: Verify SLSA provenance**
  ```yaml
  apiVersion: kyverno.io/v1
  kind: ClusterPolicy
  metadata:
    name: verify-slsa-provenance
  spec:
    validationFailureAction: Enforce
    rules:
      - name: check-provenance
        match:
          any:
            - resources:
                kinds: ["Pod"]
                namespaces: ["demo"]
        verifyImages:
          - imageReferences:
              - "harbor.kythuat.vn/demo/*"
            attestations:
              - type: https://slsa.dev/provenance/v1
                conditions:
                  - all:
                      - key: "{{ buildDefinition.buildType }}"
                        operator: Equals
                        value: "https://tekton.dev/chains/v2/slsa"
  ```

- [ ] **6.4 — Test Happy Path**
  ```bash
  # Deploy signed image → PASS
  kubectl apply -f demo-api/k8s/deployment.yaml -n demo
  kubectl get pods -n demo   # Running
  ```

- [ ] **6.5 — Test Attack Scenarios**
  ```bash
  # Scenario 1: Deploy unsigned image → DENIED
  kubectl run evil-pod --image=nginx:latest -n demo
  # Expected: admission webhook denied

  # Scenario 2: Deploy image with tampered tag → DENIED
  # (modify image digest manually)

  # Scenario 3: Deploy image without provenance → DENIED

  # Scenario 4: Deploy image from untrusted builder → DENIED

  # Scenario 5: Deploy image with forged provenance → DENIED
  ```

---

## PHASE 7: GitOps CD — Argo CD

> Argo CD pull-based deployment: Git commit → Argo sync → deploy (chỉ nếu Kyverno cho phép).
> Zero Trust: không ai `kubectl apply` trực tiếp vào cluster.
> ✅ **Argo CD đã được cài qua Helmfile bootstrap** (Phase 0.5).
> ✅ **App-of-Apps đã được kích hoạt** (Phase 0.7).

- [ ] **7.1 — Argo CD**
  > ✅ **ĐÃ CÀI QUA HELMFILE** — xem `code/infra/helmfile/values/argocd.yaml`
  - Lấy admin password:
    ```bash
    kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
    ```
  - Tạo Traefik IngressRoute cho Argo CD dashboard:
    ```yaml
    apiVersion: traefik.io/v1alpha1
    kind: IngressRoute
    metadata:
      name: argocd
      namespace: argocd
    spec:
      entryPoints: [web]
      routes:
        - match: Host(`argocd.kythuat.vn`)
          kind: Rule
          services:
            - name: argocd-server
              port: 80
    ```
  - Verify: Truy cập `https://argocd.kythuat.vn`

- [ ] **7.2 — Argo CD Application cho demo-api**
  ```yaml
  apiVersion: argoproj.io/v1alpha1
  kind: Application
  metadata:
    name: demo-api
    namespace: argocd
  spec:
    project: default
    source:
      repoURL: https://github.com/<your-org>/demo-api.git
      targetRevision: main
      path: k8s
    destination:
      server: https://kubernetes.default.svc
      namespace: demo
    syncPolicy:
      automated:
        prune: true
        selfHeal: true
  ```

- [ ] **7.3 — Argo CD Application cho demo-worker**
  - Tương tự demo-api, path = `k8s/` của demo-worker repo

- [ ] **7.4 — Argo CD Application cho infra/kafka**
  - Quản lý Strimzi CRDs (Kafka cluster, topics) qua GitOps

---

## PHASE 8: Messaging — Kafka via Strimzi Operator

> Kafka cho inter-service messaging: demo-api (producer) → Kafka → demo-worker (consumer).
> Strimzi = K8s-native operator, quản lý Kafka bằng CRDs.
> ✅ **MANAGED BY ARGO CD** — xem `code/infra/argocd/apps/strimzi.yaml` + `kafka-cluster.yaml`

- [ ] **8.1 — Strimzi Operator**
  > ✅ **MANAGED BY ARGO CD** — config tại `code/infra/argocd/apps/strimzi.yaml`
  - Verify Argo CD đã sync:
    ```bash
    kubectl get application strimzi-operator -n argocd   # Healthy + Synced
    ```
  - Verify:
    ```bash
    kubectl get pods -n kafka          # strimzi-cluster-operator Running
    kubectl get crds | grep kafka      # Kafka, KafkaTopic, KafkaUser, etc.
    ```

- [ ] **8.2 — Kafka Cluster (KRaft mode — no ZooKeeper)**
  ```yaml
  apiVersion: kafka.strimzi.io/v1beta2
  kind: Kafka
  metadata:
    name: thesis-kafka
    namespace: kafka
  spec:
    kafka:
      version: 3.8.0
      replicas: 1                      # Single broker cho dev/thesis
      listeners:
        - name: plain
          port: 9092
          type: internal
          tls: false
      config:
        offsets.topic.replication.factor: 1
        transaction.state.log.replication.factor: 1
        transaction.state.log.min.isr: 1
      storage:
        type: persistent-claim
        size: 5Gi
        class: local-path
      resources:
        requests:
          memory: 1Gi
          cpu: 500m
        limits:
          memory: 1.5Gi
    # KRaft mode — NO ZooKeeper
    zookeeper: {}                      # empty = KRaft
    entityOperator:
      topicOperator: {}
      userOperator: {}
  ```
  - Verify:
    ```bash
    kubectl get kafka -n kafka         # thesis-kafka → Ready
    kubectl get pods -n kafka          # thesis-kafka-kafka-0 Running
    ```

- [ ] **8.3 — Kafka Topic**
  ```yaml
  apiVersion: kafka.strimzi.io/v1beta2
  kind: KafkaTopic
  metadata:
    name: demo-events
    namespace: kafka
    labels:
      strimzi.io/cluster: thesis-kafka
  spec:
    partitions: 3
    replicas: 1
  ```
  - Verify: `kubectl get kafkatopic -n kafka`

- [ ] **8.4 — Test Kafka E2E**
  ```bash
  # Producer test
  kubectl run kafka-producer -it --rm \
    --image=quay.io/strimzi/kafka:latest-kafka-3.8.0 \
    --namespace kafka -- \
    bin/kafka-console-producer.sh --broker-list thesis-kafka-kafka-bootstrap:9092 --topic demo-events
  
  # Consumer test (separate terminal)
  kubectl run kafka-consumer -it --rm \
    --image=quay.io/strimzi/kafka:latest-kafka-3.8.0 \
    --namespace kafka -- \
    bin/kafka-console-consumer.sh --bootstrap-server thesis-kafka-kafka-bootstrap:9092 --topic demo-events --from-beginning
  ```

---

## PHASE 9: Observability — Monitoring + Logging

> ✅ **MANAGED BY ARGO CD** — xem `code/infra/argocd/apps/monitoring.yaml` + `logging.yaml`

- [ ] **9.1 — kube-prometheus-stack (Prometheus + Grafana + Alertmanager)**
  > ✅ **MANAGED BY ARGO CD** — config tại `code/infra/argocd/apps/monitoring.yaml`
  > Muốn thay đổi Grafana password, retention, storage? → Sửa file YAML → commit → Argo CD auto-apply.
  - Verify Argo CD đã sync:
    ```bash
    kubectl get application monitoring -n argocd   # Healthy + Synced
    ```
  - Tạo Traefik IngressRoute cho Grafana:
    ```yaml
    apiVersion: traefik.io/v1alpha1
    kind: IngressRoute
    metadata:
      name: grafana
      namespace: monitoring
    spec:
      entryPoints: [web]
      routes:
        - match: Host(`grafana.kythuat.vn`)
          kind: Rule
          services:
            - name: kube-prometheus-grafana
              port: 80
    ```
  - Verify:
    ```bash
    kubectl get pods -n monitoring
    # Truy cập https://grafana.kythuat.vn
    # Login: admin / <password>
    # Kiểm tra built-in dashboards: K8s Cluster Overview, Node Exporter, etc.
    ```

- [ ] **9.2 — Loki + Promtail (Log aggregation)**
  > ✅ **MANAGED BY ARGO CD** — config tại `code/infra/argocd/apps/logging.yaml`
  - Verify Argo CD đã sync:
    ```bash
    kubectl get application logging -n argocd   # Healthy + Synced
    ```
  - Thêm Loki datasource vào Grafana:
    ```bash
    # Thường auto-detected nếu cùng cluster
    # Hoặc thêm thủ công: URL = http://loki.logging.svc.cluster.local:3100
    ```
  - Verify:
    ```bash
    kubectl get pods -n logging        # loki-0, promtail-xxxxx (DaemonSet)
    # Trong Grafana → Explore → chọn Loki datasource → query: {namespace="demo"}
    ```

- [ ] **9.3 — Alert rules cho platform**
  ```yaml
  apiVersion: monitoring.coreos.com/v1
  kind: PrometheusRule
  metadata:
    name: platform-alerts
    namespace: monitoring
  spec:
    groups:
      - name: platform
        rules:
          - alert: PodCrashLooping
            expr: rate(kube_pod_container_status_restarts_total[15m]) > 0
            for: 5m
            labels:
              severity: warning
          - alert: HighMemoryUsage
            expr: >
              (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes)
              / node_memory_MemTotal_bytes > 0.9
            for: 10m
            labels:
              severity: critical
          - alert: KyvernoPolicyViolation
            expr: increase(kyverno_policy_results_total{rule_result="fail"}[1h]) > 0
            labels:
              severity: warning
  ```

- [ ] **9.4 — Grafana dashboards cần import**
  | Dashboard | ID/Source | Mục đích |
  |---|---|---|
  | K8s Cluster Overview | Built-in (kube-prometheus-stack) | Node CPU/RAM, Pod count |
  | Traefik | Traefik Grafana dashboard | Request rate, latency |
  | Argo CD | 14584 | Sync status, app health |
  | Tekton | Custom | Pipeline duration, success rate |
  | Kafka (Strimzi) | 11285 | Broker metrics, topic throughput |

---

## PHASE 10: Demo Application — 2 Microservices

> 2 services chứng minh: mỗi service → build riêng → sign riêng → verify riêng → deploy qua GitOps.

- [ ] **10.1 — demo-api (HTTP API + Kafka Producer)**
  - Repo structure:
    ```
    demo-api/
    ├── Dockerfile
    ├── main.go (hoặc index.js)
    ├── go.mod / package.json
    ├── k8s/
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   ├── ingress.yaml            # Traefik IngressRoute
    │   └── kustomization.yaml
    └── tekton/
        ├── pipeline.yaml
        └── pipelinerun.yaml
    ```
  - Endpoints:
    | Endpoint | Mô tả |
    |---|---|
    | `GET /` | Hello + build info (commit SHA, build time) |
    | `GET /healthz` | Health check (K8s probe) |
    | `GET /info` | Image digest, signature status, provenance link |
    | `POST /event` | Publish message → Kafka topic `demo-events` |
  - Kafka producer config:
    ```
    KAFKA_BROKER=thesis-kafka-kafka-bootstrap.kafka.svc.cluster.local:9092
    KAFKA_TOPIC=demo-events
    ```

- [ ] **10.2 — demo-worker (Kafka Consumer)**
  - Repo structure:
    ```
    demo-worker/
    ├── Dockerfile
    ├── main.go (hoặc index.js)
    ├── go.mod / package.json
    ├── k8s/
    │   ├── deployment.yaml
    │   ├── service.yaml            # ClusterIP only (internal)
    │   └── kustomization.yaml
    └── tekton/
        ├── pipeline.yaml
        └── pipelinerun.yaml
    ```
  - Chức năng: Subscribe Kafka topic → process message → log result
  - Không expose ra internet (internal-only)

- [ ] **10.3 — Build + Deploy E2E flow**
  ```
  1. Developer push code → GitHub repo
  2. Trigger Tekton PipelineRun (webhook hoặc manual)
  3. Tekton: git-clone → kaniko-build → push to Harbor
  4. Tekton Chains: observe TaskRun → sign image + tạo provenance → push attestation lên Harbor
  5. Update image tag/digest trong k8s/ manifest → commit to Git
  6. Argo CD: detect Git change → sync → create Pod
  7. Kyverno: intercept Pod creation → verify signature + provenance → ALLOW
  8. Pod chạy → Traefik route → cloudflared → internet accessible
  ```

- [ ] **10.4 — Expose demo-api qua internet**
  ```yaml
  apiVersion: traefik.io/v1alpha1
  kind: IngressRoute
  metadata:
    name: demo-api
    namespace: demo
  spec:
    entryPoints: [web]
    routes:
      - match: Host(`demo.kythuat.vn`)
        kind: Rule
        services:
          - name: demo-api
            port: 8080
  ```
  - Verify: `curl https://demo.kythuat.vn/healthz`

---

## PHASE 11: Service Mesh — Istio/Linkerd (OPTIONAL)

> Chỉ triển khai nếu còn thời gian + RAM. Ưu tiên Linkerd (nhẹ hơn Istio).

- [ ] **11.1 — Istio hoặc Linkerd**
  - Option A — Linkerd (nhẹ, ~50MB/proxy):
    ```bash
    curl -sL https://run.linkerd.io/install | sh
    linkerd install --crds | kubectl apply -f -
    linkerd install | kubectl apply -f -
    linkerd check
    ```
  - Option B — Istio Ambient Mode (không sidecar):
    ```bash
    istioctl install --set profile=ambient
    ```
  - Enable mesh cho namespace demo:
    ```bash
    kubectl label namespace demo linkerd.io/inject=enabled  # Linkerd
    # hoặc
    kubectl label namespace demo istio.io/dataplane-mode=ambient  # Istio
    ```
  - Verify mTLS: `linkerd viz stat deploy -n demo`

---

## PHASE 12: Validation & Attack Scenarios

> Chứng minh SLSA L3 compliance bằng 5 kịch bản tấn công + happy path.

- [ ] **12.1 — Happy Path**
  - Deploy demo-api (signed + provenance) → `kubectl get pods -n demo` → Running

- [ ] **12.2 — Attack: Unsigned image**
  ```bash
  kubectl run evil --image=nginx:latest -n demo
  # Expected: denied by Kyverno
  ```

- [ ] **12.3 — Attack: Modified image (tag mismatch)**
  ```bash
  # Push tampered image → tag lại → deploy
  # Expected: digest mismatch → denied
  ```

- [ ] **12.4 — Attack: Missing provenance**
  ```bash
  # Build image manually (docker build) → sign nhưng KHÔNG tạo provenance → deploy
  # Expected: denied by provenance policy
  ```

- [ ] **12.5 — Attack: Untrusted builder**
  ```bash
  # Build trên machine khác (không phải Tekton) → sign → deploy
  # Expected: builder identity mismatch → denied
  ```

- [ ] **12.6 — Performance benchmark**
  - Đo thời gian admission verify (có vs không Kyverno)
  - Đo thời gian pipeline (git-clone → build → sign → push → deploy)
  - Ghi log thời gian, screenshot cho báo cáo

---

## TỔNG KẾT — OPTION A COMPONENT COUNT

| Layer | Component | Ưu tiên | CRDs |
|---|---|---|---|
| **L0** | K8s, Flannel, Tailscale, Helm, local-path-provisioner | 🔴 CRITICAL | - |
| **L0** | cert-manager | 🟠 HIGH | Certificate, ClusterIssuer |
| **L5** | Traefik | 🔴 CRITICAL | IngressRoute, Middleware |
| **L5** | cloudflared | 🔴 CRITICAL | - (Deployment) |
| **L2** | Tekton Pipelines + Chains | 🔴 CRITICAL | Pipeline, Task, PipelineRun, TaskRun |
| **L2** | Cosign | 🔴 CRITICAL | - (CLI tool) |
| **L2** | Kaniko | 🔴 CRITICAL | - (runs as Tekton Task) |
| **L2** | Harbor | 🔴 CRITICAL | - (Helm release) |
| **L2** | Kyverno | 🔴 CRITICAL | ClusterPolicy, Policy, PolicyReport |
| **L2** | Argo CD | 🟠 HIGH | Application, AppProject |
| **L2** | Sealed Secrets | 🟠 HIGH | SealedSecret |
| **L2** | Syft + Grype | 🟡 NICE | - (CLI/container) |
| **L1** | Kafka (Strimzi) | 🟠 HIGH | Kafka, KafkaTopic, KafkaUser |
| **Obs** | Prometheus + Grafana + Alertmanager | 🟠 HIGH | PrometheusRule, ServiceMonitor |
| **Obs** | Loki + Promtail | 🟠 HIGH | - (Helm) |
| **L4** | Istio / Linkerd | 🟡 OPTIONAL | VirtualService, etc. |
| **L3** | demo-api + demo-worker | 🔴 CRITICAL | - (Deployments) |

**Tổng: 12 CRITICAL + 7 HIGH + 2 MEDIUM/OPTIONAL = ~21 components**

---

## QUICK REFERENCE — Kiểm tra nhanh toàn bộ platform

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

# === CI/CD ===
kubectl get pods -n tekton-pipelines
kubectl get pods -n tekton-chains
kubectl get pipelineruns --all-namespaces

# === Security ===
kubectl get pods -n kyverno
kubectl get clusterpolicy
kubectl get pods -n sealed-secrets

# === Registry ===
kubectl get pods -n harbor

# === GitOps ===
kubectl get pods -n argocd
kubectl get applications -n argocd

# === Messaging ===
kubectl get pods -n kafka
kubectl get kafka -n kafka
kubectl get kafkatopic -n kafka

# === Observability ===
kubectl get pods -n monitoring
kubectl get pods -n logging

# === Demo ===
kubectl get pods -n demo
curl -s https://demo.kythuat.vn/healthz
```
