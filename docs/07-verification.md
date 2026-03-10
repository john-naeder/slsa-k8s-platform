# 07 — Verification Checklist

> Verify toàn bộ hệ thống sau khi setup xong (hoặc sau khi recreate).

## Phase 0: Infrastructure Foundation

### Tailscale VPN
```bash
tailscale status
# Tất cả nodes hiển thị "active"
# userver-master: 100.95.126.102
# userver-home-worker: 100.94.203.28
```

- [ ] Tất cả nodes online trên tailnet
- [ ] Ping giữa các nodes thành công: `ping 100.95.126.102` từ worker

### K8s Cluster
```bash
kubectl get nodes -o wide
```
- [ ] Tất cả nodes STATUS = `Ready`
- [ ] INTERNAL-IP = Tailscale IP (100.x.x.x)
- [ ] VERSION = v1.32.x

### System Pods
```bash
kubectl get pods -n kube-system
```
- [ ] coredns: 2/2 Running
- [ ] etcd: Running
- [ ] kube-apiserver: Running
- [ ] kube-controller-manager: Running
- [ ] kube-proxy: Running (on each node)
- [ ] kube-scheduler: Running

### Flannel CNI
```bash
kubectl get pods -n kube-flannel
kubectl -n kube-flannel get ds kube-flannel-ds -o jsonpath='{.spec.template.spec.containers[0].args}'
```
- [ ] kube-flannel-ds pods Running on each node
- [ ] Args contain `--iface=tailscale0`

---

## Phase 1: Platform Bootstrap (Helmfile)

```bash
helmfile -f code/infra/helmfile/helmfile-bootstrap.yaml list
```

### cert-manager
```bash
kubectl get pods -n cert-manager
kubectl get crds | grep cert-manager
```
- [ ] 3 pods Running: controller, webhook, cainjector
- [ ] CRDs created: certificates, issuers, clusterissuers, etc.

### Traefik
```bash
kubectl get pods -n traefik
kubectl get svc -n traefik
kubectl get crds | grep traefik
```
- [ ] Traefik pod Running
- [ ] Service type = ClusterIP
- [ ] CRDs: IngressRoute, Middleware, etc.

### Sealed Secrets
```bash
kubectl get pods -n sealed-secrets
```
- [ ] sealed-secrets-controller Running

### ArgoCD
```bash
kubectl get pods -n argocd
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
```
- [ ] 5+ pods Running: server, controller, repo-server, redis, applicationset
- [ ] Admin password retrievable

---

## Phase 2: Post-Bootstrap

### Local Path Provisioner
```bash
kubectl get storageclass
kubectl get pods -n local-path-storage
```
- [ ] `local-path` StorageClass exists (default)
- [ ] Provisioner pod Running

### Cloudflare Tunnel
```bash
kubectl -n cloudflare get pods
kubectl -n cloudflare logs deploy/cloudflared | grep "Connection"
```
- [ ] cloudflared pod Running
- [ ] Logs show "Connection registered" at SIN (or other edge)

### ClusterIssuer
```bash
kubectl get clusterissuer
```
- [ ] letsencrypt-prod: Ready = True
- [ ] letsencrypt-staging: Ready = True

---

## Phase 3: ArgoCD & GitOps

### Repository Connection
```bash
kubectl -n argocd get secret repo-slsa-k8s-platform
```
- [ ] SSH deploy key secret exists
- [ ] ArgoCD UI → Settings → Repositories → Connected ✅

### App-of-Apps
```bash
kubectl get applications -n argocd
```
- [ ] platform-apps: Synced
- [ ] strimzi-operator: Synced (hoặc Progressing)
- [ ] kafka-cluster: Synced
- [ ] kyverno: Synced
- [ ] monitoring: Synced
- [ ] logging: Synced
- [ ] harbor: Synced
- [ ] demo-api: Synced (hoặc Missing nếu chưa có source code)
- [ ] demo-worker: Synced (hoặc Missing nếu chưa có source code)

---

## Phase 4: Networking & Access

### ArgoCD via Tailscale (NodePort)
```bash
curl -sI http://100.94.203.28:30080
```
- [ ] HTTP 200

### ArgoCD via Cloudflare Tunnel
```bash
curl -sI https://argocd.kythuat.vn
```
- [ ] HTTP/2 200
- [ ] `server: cloudflare`
- [ ] `cf-ray: xxxxx-SIN`
- [ ] Security headers present (X-Frame-Options, HSTS, etc.)

### Cloudflare Tunnel Route
```bash
dig +short argocd.kythuat.vn
```
- [ ] Returns Cloudflare proxy IPs

### In-cluster routing test (optional)
```bash
kubectl run test-curl --image=curlimages/curl --rm -it -- \
  curl -sI -H "Host: argocd.kythuat.vn" http://traefik.traefik.svc.cluster.local
```
- [ ] HTTP 200 với security headers

### Zero Trust Access (nếu đã cấu hình)
- [ ] Truy cập `https://argocd.kythuat.vn` → hiện trang Cloudflare Access login
- [ ] Nhập email → nhận OTP → verify → forward tới ArgoCD login

---

## Phase 5: Tekton CI Pipeline

### Tekton Controllers
```bash
kubectl get pods -n tekton-pipelines
kubectl get pods -n tekton-chains
```
- [ ] tekton-pipelines-controller: Running
- [ ] tekton-pipelines-webhook: Running
- [ ] tekton-triggers-controller: Running
- [ ] tekton-triggers-webhook: Running
- [ ] tekton-chains-controller: Running

### Pipeline & Tasks
```bash
kubectl get pipeline -n tekton-pipelines
kubectl get task -n tekton-pipelines
```
- [ ] Pipeline `build-and-sign` exists
- [ ] Tasks: `git-clone`, `kaniko-build`, `update-manifest`

### RBAC & Secrets
```bash
kubectl get sa tekton-bot -n tekton-pipelines
kubectl get secret -n tekton-pipelines | grep -E "harbor-credentials|cosign-keys|git-ssh-key"
```
- [ ] ServiceAccount `tekton-bot` exists
- [ ] Secrets: `harbor-credentials`, `cosign-keys`, `git-ssh-key`

### Tekton Chains Config
```bash
kubectl get configmap chains-config -n tekton-chains -o yaml
```
- [ ] `artifacts.taskrun.format: in-toto`
- [ ] `artifacts.taskrun.storage: oci`
- [ ] `artifacts.taskrun.signer: cosign`
- [ ] `transparency.enabled: false`

### Triggers (Webhook)
```bash
kubectl get eventlistener -n tekton-pipelines
kubectl get triggertemplate -n tekton-pipelines
kubectl get triggerbinding -n tekton-pipelines
kubectl get svc -n tekton-pipelines | grep el-
```
- [ ] EventListener `github-listener` Running
- [ ] TriggerTemplate `build-deploy-template` exists
- [ ] TriggerBinding `github-push-binding` exists
- [ ] Service `el-github-listener` created

### Test Manual PipelineRun
```bash
kubectl create -f code/tekton/runs/demo-api-run.yaml
tkn pipelinerun logs -f -n tekton-pipelines
```
- [ ] PipelineRun completes: `git-clone` → `kaniko-build` → `update-manifest`
- [ ] Image pushed to Harbor
- [ ] Chains auto-signs (after ~30s): check `chains.tekton.dev/signed=true` annotation

---

## Phase 6: Harbor Registry

### Harbor Pods
```bash
kubectl get pods -n harbor
```
- [ ] harbor-core: Running
- [ ] harbor-database: Running
- [ ] harbor-jobservice: Running
- [ ] harbor-portal: Running
- [ ] harbor-redis: Running
- [ ] harbor-registry: Running
- [ ] harbor-trivy: Running

### Harbor Access
```bash
curl -sk https://harbor.kythuat.vn/api/v2.0/health
```
- [ ] Response: `{"status":"healthy"}`

### Harbor Project
- [ ] Login tại `https://harbor.kythuat.vn`
- [ ] Project `slsa` exists
- [ ] Cosign artifacts (`.sig`, `.att`) appears alongside image tags

### CA Certificate on Nodes
```bash
# Trên mỗi node:
ls /etc/containerd/certs.d/harbor.kythuat.vn/
# Phải có ca.crt
crictl pull harbor.kythuat.vn/slsa/demo-api:latest 2>&1 | head -5
```
- [ ] CA cert installed on all nodes
- [ ] `crictl pull` thành công (no TLS errors)

---

## Phase 7: Kyverno Policies

### Kyverno Controller
```bash
kubectl get pods -n kyverno
```
- [ ] kyverno-admission-controller: Running
- [ ] kyverno-background-controller: Running
- [ ] kyverno-cleanup-controller: Running
- [ ] kyverno-reports-controller: Running

### Policies
```bash
kubectl get clusterpolicy
```
- [ ] `verify-image-signature`: Ready
- [ ] `verify-slsa-provenance`: Ready

### Test — Valid Image (PASS)
```bash
# Deploy image đã được sign
kubectl run test-valid \
  --image=harbor.kythuat.vn/slsa/demo-api@sha256:<SIGNED_DIGEST> \
  --dry-run=server
```
- [ ] Admission allowed

### Test — Unsigned Image (FAIL)
```bash
kubectl run test-unsigned \
  --image=docker.io/nginx:latest \
  --dry-run=server
```
- [ ] Admission denied: signature verification failed

### Policy Reports
```bash
kubectl get policyreport -A
kubectl get clusterpolicyreport
```
- [ ] Reports generated, showing pass/fail/warn counts

---

## Phase 8: Kafka (Strimzi)

### Strimzi Operator
```bash
kubectl get pods -n strimzi
```
- [ ] strimzi-cluster-operator: Running

### Kafka Cluster
```bash
kubectl get kafka -n kafka
kubectl get kafkanodepool -n kafka
kubectl get pods -n kafka
```
- [ ] Kafka `demo-cluster`: Ready
- [ ] KafkaNodePool `combined`: Ready (1 replica)
- [ ] `demo-cluster-combined-0` pod: Running

### Kafka Topic
```bash
kubectl get kafkatopic -n kafka
```
- [ ] `demo-events` topic: Ready, partitions=3, replicas=1

### Produce/Consume Test
```bash
# Producer
kubectl run kafka-producer -it --rm --image=quay.io/strimzi/kafka:0.44.0-kafka-3.8.1 -- \
  bin/kafka-console-producer.sh \
  --bootstrap-server demo-cluster-kafka-bootstrap.kafka.svc:9092 \
  --topic demo-events

# Consumer (tab khác)
kubectl run kafka-consumer -it --rm --image=quay.io/strimzi/kafka:0.44.0-kafka-3.8.1 -- \
  bin/kafka-console-consumer.sh \
  --bootstrap-server demo-cluster-kafka-bootstrap.kafka.svc:9092 \
  --topic demo-events --from-beginning
```
- [ ] Producer gửi message → Consumer nhận message

---

## Phase 9: Demo Applications

### demo-api
```bash
kubectl get pods -n demo
kubectl get svc -n demo | grep demo-api
```
- [ ] demo-api pod Running
- [ ] Service demo-api port 8080

### demo-worker
```bash
kubectl get pods -n demo
kubectl get logs deploy/demo-worker -n demo | tail -5
```
- [ ] demo-worker pod Running
- [ ] Logs: "Consumer started" / processing messages

### Health Endpoints
```bash
curl -s https://demo.kythuat.vn/healthz
curl -s https://demo.kythuat.vn/metrics | head -5
```
- [ ] `/healthz` → `OK`
- [ ] `/metrics` → Prometheus format

### E2E Event Flow
```bash
# Gửi event qua demo-api
curl -s https://demo.kythuat.vn/event -d '{"msg":"test-verification"}'

# Kiểm logs demo-worker
kubectl logs deploy/demo-worker -n demo --tail=5
```
- [ ] Response `{"status":"queued"}`
- [ ] demo-worker logs: received message "test-verification"

---

## Phase 10: SLSA L3 — End-to-End Verification

### Cosign Signature Verification
```bash
COSIGN_REPOSITORY=harbor.kythuat.vn/slsa/demo-api \
cosign verify \
  --key k8s://tekton-pipelines/cosign-keys \
  harbor.kythuat.vn/slsa/demo-api:latest
```
- [ ] Verification thành công: `Verified OK`
- [ ] Output chứa Cosign payload JSON

### SLSA Provenance Verification
```bash
COSIGN_REPOSITORY=harbor.kythuat.vn/slsa/demo-api \
cosign verify-attestation \
  --key k8s://tekton-pipelines/cosign-keys \
  --type slsaprovenance \
  harbor.kythuat.vn/slsa/demo-api:latest
```
- [ ] Attestation verified
- [ ] Payload chứa in-toto SLSA v0.2 provenance

### Provenance Content Check
```bash
COSIGN_REPOSITORY=harbor.kythuat.vn/slsa/demo-api \
cosign verify-attestation \
  --key k8s://tekton-pipelines/cosign-keys \
  --type slsaprovenance \
  harbor.kythuat.vn/slsa/demo-api:latest \
  | jq -r '.payload' | base64 -d | jq '.predicate'
```
- [ ] `predicate.buildType` present
- [ ] `predicate.builder.id` present
- [ ] `predicate.invocation` present
- [ ] `predicate.materials` present (source repo + digest)

### Kyverno Enforcement Test
```bash
# Image đã sign + có provenance → deploy thành công
kubectl set image deploy/demo-api demo-api=harbor.kythuat.vn/slsa/demo-api@sha256:<SIGNED> -n demo
# → Admission allowed

# Image random (không sign) → bị reject
kubectl run test-reject --image=docker.io/nginx:latest --dry-run=server
# → Admission denied
```
- [ ] Signed image: deploy success
- [ ] Unsigned image: rejected by Kyverno

### SLSA L3 Requirements Checklist
- [ ] **Source**: Code from version-controlled repo (GitHub)
- [ ] **Build**: Automated CI (Tekton) — no manual intervention
- [ ] **Provenance**: Auto-generated by Tekton Chains (in-toto format)
- [ ] **Signing**: Cosign key-pair signing (non-forgeable)
- [ ] **Verification**: Kyverno enforces signature + provenance at admission
- [ ] **Non-falsifiable**: Chains generates provenance from observed build (tamper-evident)

---

## Quick Health Check Script

```bash
#!/bin/bash
set -euo pipefail

echo "=== Nodes ==="
kubectl get nodes -o wide

echo ""
echo "=== Helmfile Releases ==="
cd code/infra/helmfile && helmfile -f helmfile-bootstrap.yaml list 2>/dev/null || echo "helmfile not available"

echo ""
echo "=== ArgoCD Applications ==="
kubectl get applications -n argocd 2>/dev/null || echo "ArgoCD not installed"

echo ""
echo "=== Tekton ==="
kubectl get pods -n tekton-pipelines 2>/dev/null || echo "Tekton not installed"
kubectl get pods -n tekton-chains 2>/dev/null || echo "Chains not installed"

echo ""
echo "=== Harbor ==="
kubectl get pods -n harbor 2>/dev/null || echo "Harbor not installed"

echo ""
echo "=== Kyverno ==="
kubectl get clusterpolicy 2>/dev/null || echo "Kyverno not installed"

echo ""
echo "=== Kafka (Strimzi) ==="
kubectl get kafka -n kafka 2>/dev/null || echo "Kafka not deployed"
kubectl get kafkatopic -n kafka 2>/dev/null || echo "No topics"

echo ""
echo "=== Demo Apps ==="
kubectl get pods -n demo 2>/dev/null || echo "Demo apps not deployed"

echo ""
echo "=== All Pods (non-Running) ==="
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null

echo ""
echo "=== Storage ==="
kubectl get storageclass

echo ""
echo "=== Cloudflare Tunnel ==="
kubectl -n cloudflare get pods 2>/dev/null || echo "cloudflared not deployed"

echo ""
echo "=== External Access ==="
curl -so /dev/null -w "ArgoCD Tailscale  : HTTP %{http_code}\n" http://100.94.203.28:30080 2>/dev/null
curl -so /dev/null -w "ArgoCD Cloudflare : HTTP %{http_code}\n" https://argocd.kythuat.vn 2>/dev/null
curl -so /dev/null -w "Harbor            : HTTP %{http_code}\n" https://harbor.kythuat.vn 2>/dev/null
curl -so /dev/null -w "Demo API          : HTTP %{http_code}\n" https://demo.kythuat.vn/healthz 2>/dev/null
```
