# 08 — Troubleshooting

> Lỗi thường gặp và cách xử lý khi setup hoặc recreate platform.

---

## Ansible / K8s Provisioning

### 1. Ansible "UNREACHABLE" — SSH fail qua Tailscale

**Triệu chứng:**
```
fatal: [userver-master]: UNREACHABLE!
```

**Nguyên nhân:** Node offline trên tailnet, hoặc SSH key chưa copy.

**Fix:**
```bash
# Kiểm tra Tailscale
tailscale status | grep userver-master
# Nếu offline → SSH vào node qua LAN và: sudo tailscale up

# Test SSH thủ công
ssh -i ~/.ssh/id_ed25519 john@100.95.126.102

# Copy lại SSH key nếu cần
ssh-copy-id -i ~/.ssh/id_ed25519.pub john@100.95.126.102
```

### 2. kubeadm init fail — "port already in use"

**Nguyên nhân:** Cluster cũ chưa được reset.

**Fix:**
```bash
cd code/infra/ansible/
make reset     # Reset tất cả nodes
make master    # Re-init master
```

### 3. Flannel pods CrashLoopBackOff

**Nguyên nhân:** Flannel không tìm thấy `tailscale0` interface.

**Fix:**
```bash
# Kiểm tra interface trên node
ssh john@100.95.126.102 "ip link | grep tailscale"

# Kiểm tra Flannel DaemonSet args
kubectl -n kube-flannel get ds kube-flannel-ds -o yaml | grep -A5 containers

# Nếu thiếu --iface=tailscale0, patch thủ công:
kubectl -n kube-flannel patch daemonset kube-flannel-ds --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--iface=tailscale0"}]'
```

### 4. CoreDNS Pending — CNI not ready

**Nguyên nhân:** CNI plugins chưa cài, hoặc Flannel chưa deploy.

**Fix:**
```bash
# Kiểm tra CNI plugins
ssh john@100.95.126.102 "ls /opt/cni/bin/"

# Kiểm tra Flannel
kubectl get pods -n kube-flannel
```

### 5. Worker node NotReady

**Nguyên nhân:** kubelet không advertise đúng IP, hoặc firewall block.

**Fix:**
```bash
# Kiểm tra kubelet trên worker
ssh john@100.94.203.28 "systemctl status kubelet"
ssh john@100.94.203.28 "journalctl -u kubelet --no-pager -n 50"

# Kiểm tra node-ip trong kubelet args
ssh john@100.94.203.28 "cat /var/lib/kubelet/kubeadm-flags.env"
# Phải có: --node-ip=100.94.203.28

# Kiểm tra UFW
ssh john@100.94.203.28 "sudo ufw status"
```

---

## Helmfile / Helm

### 6. helmfile apply — "release already exists"

**Fix:**
```bash
# helmfile apply tự handle (idempotent). Nếu vẫn lỗi:
helmfile -f helmfile-bootstrap.yaml destroy
helmfile -f helmfile-bootstrap.yaml apply
```

### 7. Helm chart timeout — pod pending

**Nguyên nhân:** nodeSelector không match, hoặc insufficient resources.

**Fix:**
```bash
# Kiểm tra pending pods
kubectl get pods -A --field-selector=status.phase=Pending

# Describe pod để xem lý do
kubectl describe pod <pod-name> -n <namespace>

# Kiểm tra node labels
kubectl get nodes --show-labels

# Gán label nếu thiếu
kubectl label node userver-home-worker node-role=worker
kubectl label node userver-home-worker workload-type=heavy
```

---

## Cloudflare Tunnel

### 8. cloudflared pod CrashLoopBackOff

**Nguyên nhân:** Tunnel token sai hoặc hết hạn.

**Fix:**
```bash
# Kiểm tra logs
kubectl -n cloudflare logs deploy/cloudflared

# Nếu token lỗi → tạo lại
kubectl -n cloudflare delete secret cloudflared-token
kubectl -n cloudflare create secret generic cloudflared-token \
  --from-literal=tunnel-token=<NEW_TOKEN>

# Restart
kubectl -n cloudflare rollout restart deploy/cloudflared
```

### 9. setup-route.sh — "Authentication error"

**Nguyên nhân:** API token thiếu permission.

**Fix:**
- Vào [dash.cloudflare.com/profile/api-tokens](https://dash.cloudflare.com/profile/api-tokens)
- Edit token → thêm permissions cần thiết:
  - Zone → DNS → Edit
  - Account → Cloudflare Tunnel → Edit
  - Account → Access: Apps and Policies → Edit (cho Zero Trust)

### 10. curl https://argocd.kythuat.vn — timeout

**Debug workflow:**
```bash
# 1. DNS resolve?
dig +short argocd.kythuat.vn
# Phải trả về Cloudflare IPs

# 2. Cloudflared pod running?
kubectl -n cloudflare get pods

# 3. Tunnel connections?
kubectl -n cloudflare logs deploy/cloudflared | grep "Connection"

# 4. Tunnel config đúng?
curl -s "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
  -H "Authorization: Bearer $CF_API_TOKEN" | python3 -m json.tool

# 5. Traefik routing OK? (test từ trong cluster)
kubectl run test --image=curlimages/curl --rm -it -- \
  curl -sI -H "Host: argocd.kythuat.vn" http://traefik.traefik.svc.cluster.local

# 6. ArgoCD pod running?
kubectl get pods -n argocd
```

### 11. setup-route.sh — "Duplicate catch-all entries"

**Nguyên nhân:** Bug trong filter logic (đã fix).

**Fix:** Dùng version mới nhất của script. Filter logic phải check `r.get('hostname')`:
```python
filtered = [r for r in existing if r.get('hostname') and r.get('hostname') != hostname]
```

---

## ArgoCD

### 12. ArgoCD Application stuck "Progressing"

**Nguyên nhân:** CRDs chưa có (ví dụ: Kafka CRDs cần Strimzi operator trước).

**Fix:**
```bash
# Check ArgoCD app status
kubectl get application <app-name> -n argocd -o yaml | grep -A10 status

# Manual sync
kubectl -n argocd patch application <app-name> --type=merge \
  -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{}}}'

# Hoặc dùng ArgoCD CLI
argocd app sync <app-name>
```

### 13. ArgoCD "ComparisonError" — repository not accessible

**Nguyên nhân:** SSH deploy key chưa setup hoặc revoked.

**Fix:**
```bash
# Kiểm tra secret
kubectl -n argocd get secret repo-slsa-k8s-platform

# Tạo lại nếu cần
ssh-keygen -t ed25519 -C "argocd-deploy-key" -f /tmp/argocd-deploy-key -N ""
# → Thêm public key lên GitHub Settings → Deploy keys
kubectl -n argocd delete secret repo-slsa-k8s-platform
kubectl -n argocd create secret generic repo-slsa-k8s-platform \
  --from-file=sshPrivateKey=/tmp/argocd-deploy-key \
  --from-literal=type=git \
  --from-literal=url=git@github.com:john-naeder/slsa-k8s-platform.git
kubectl -n argocd label secret repo-slsa-k8s-platform argocd.argoproj.io/secret-type=repository
```

### 14. Quên ArgoCD admin password

```bash
# Lấy initial password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d

# Nếu secret đã bị xóa → reset password
# Cách 1: Dùng argocd CLI
argocd account update-password --account admin --new-password <new-pass>

# Cách 2: Patch secret thủ công
NEW_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'new-password', bcrypt.gensalt()).decode())")
kubectl -n argocd patch secret argocd-secret -p "{\"stringData\":{\"admin.password\":\"${NEW_HASH}\"}}"
```

---

## Tekton CI Pipeline

### 15. PipelineRun stuck Pending / Running mãi

**Triệu chứng:** PipelineRun ở trạng thái Running nhưng không có TaskRun nào được tạo.

**Nguyên nhân:** ServiceAccount không có đủ RBAC hoặc thiếu secrets.

**Fix:**
```bash
# Check PipelineRun status
tkn pipelinerun describe <run-name> -n tekton-pipelines

# Check events
kubectl get events -n tekton-pipelines --sort-by=.lastTimestamp | tail -20

# Verify ServiceAccount secrets
kubectl get sa tekton-bot -n tekton-pipelines -o yaml
# Phải có: harbor-credentials, cosign-keys, git-ssh-key
```

### 16. Kaniko build fail — "unauthorized" push to Harbor

**Triệu chứng:** TaskRun `kaniko-build` fail với `UNAUTHORIZED` hoặc `401`.

**Fix:**
```bash
# Kiểm tra Harbor credentials secret
kubectl get secret harbor-credentials -n tekton-pipelines -o jsonpath='{.data.config\.json}' | base64 -d
# Phải chứa {"auths":{"harbor.kythuat.vn":{"auth":"..."}}}

# Tạo lại nếu sai
kubectl delete secret harbor-credentials -n tekton-pipelines
kubectl create secret docker-registry harbor-credentials \
  -n tekton-pipelines \
  --docker-server=harbor.kythuat.vn \
  --docker-username=admin \
  --docker-password=<HARBOR_PASSWORD>
```

### 17. Tekton Chains không sign — annotation `chains.tekton.dev/signed` missing

**Triệu chứng:** TaskRun/PipelineRun hoàn thành nhưng không có annotation `chains.tekton.dev/signed=true`.

**Fix:**
```bash
# Check Chains controller logs
kubectl logs deploy/tekton-chains-controller -n tekton-chains --tail=50

# Verify Chains config
kubectl get configmap chains-config -n tekton-chains -o yaml
# Kiểm tra: artifacts.taskrun.format, signer, storage

# Kiểm tra Cosign key secret
kubectl get secret cosign-keys -n tekton-pipelines -o yaml | head -5

# Restart Chains controller
kubectl -n tekton-chains rollout restart deploy/tekton-chains-controller

# Đợi ~60s rồi check lại annotation
kubectl get taskrun <name> -n tekton-pipelines \
  -o jsonpath='{.metadata.annotations.chains\.tekton\.dev/signed}'
```

### 18. EventListener không nhận webhook từ GitHub

**Triệu chứng:** Push code lên GitHub nhưng không có PipelineRun mới.

**Fix:**
```bash
# Check EventListener pod
kubectl get pods -n tekton-pipelines | grep el-github-listener

# Check EventListener logs
kubectl logs -l eventlistener=github-listener -n tekton-pipelines --tail=30

# Kiểm tra Service
kubectl get svc el-github-listener -n tekton-pipelines

# Kiểm tra IngressRoute (nếu expose qua Traefik/Cloudflare)
kubectl get ingressroute -n tekton-pipelines

# Test webhook thủ công
curl -X POST https://tekton.kythuat.vn \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: push" \
  -d '{"ref":"refs/heads/main","repository":{"clone_url":"https://github.com/john-naeder/slsa-k8s-platform.git"},"head_commit":{"id":"test123"}}'
```

### 19. update-manifest task fail — git push permission denied

**Triệu chứng:** Task `update-manifest` fail khi push image digest lại repo.

**Fix:**
```bash
# Kiểm tra git SSH key
kubectl get secret git-ssh-key -n tekton-pipelines
# Secret phải chứa ssh-privatekey

# Test SSH key
kubectl run git-test --rm -it --image=alpine/git \
  --overrides='{"spec":{"serviceAccountName":"tekton-bot"}}' -- \
  ssh -T git@github.com
# Phải thấy: "Hi john-naeder! You've successfully authenticated..."

# Kiểm tra known_hosts config trong Task
# Task phải có step setup SSH known_hosts trước khi git push
```

---

## Harbor Registry

### 20. ImagePullBackOff — x509 certificate signed by unknown authority

**Triệu chứng:** Pod dùng Harbor image bị `ImagePullBackOff`, describe thấy `x509: certificate signed by unknown authority`.

**Nguyên nhân:** Node chưa cài CA cert của Harbor.

**Fix:**
```bash
# Lấy Harbor CA cert
kubectl get secret harbor-harbor-nginx -n harbor \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/harbor-ca.crt

# Copy lên mỗi node
for NODE_IP in 100.95.126.102 100.94.203.28; do
  ssh john@$NODE_IP "sudo mkdir -p /etc/containerd/certs.d/harbor.kythuat.vn"
  scp /tmp/harbor-ca.crt john@$NODE_IP:/tmp/
  ssh john@$NODE_IP "sudo cp /tmp/harbor-ca.crt /etc/containerd/certs.d/harbor.kythuat.vn/ca.crt"
  ssh john@$NODE_IP "sudo systemctl restart containerd"
done

# Verify
ssh john@100.94.203.28 "sudo crictl pull harbor.kythuat.vn/slsa/demo-api:latest"
```

### 21. Harbor pod CrashLoopBackOff — database connection refused

**Nguyên nhân:** Harbor database PVC chưa sẵn sàng hoặc StorageClass lỗi.

**Fix:**
```bash
# Kiểm tra PVC
kubectl get pvc -n harbor

# Kiểm tra logs database pod
kubectl logs harbor-harbor-database-0 -n harbor --tail=20

# Kiểm tra StorageClass default
kubectl get storageclass

# Nếu PVC stuck Pending → check local-path-provisioner
kubectl get pods -n local-path-storage
kubectl logs deploy/local-path-provisioner -n local-path-storage --tail=20
```

### 22. Harbor TLS certificate renewal

**Nguyên nhân:** Harbor tự sinh TLS — nếu cần renew hoặc đổi domain.

**Fix:**
```bash
# Option 1: Xóa secret → Harbor Helm chart tái tạo
kubectl delete secret harbor-harbor-nginx -n harbor
# ArgoCD sẽ auto-sync lại

# Option 2: Force ArgoCD sync
argocd app sync harbor --force

# Sau khi cert mới → cần cập nhật CA trên nodes (xem #20)
```

---

## Kyverno Policies

### 23. Kyverno deny image đã sign hợp lệ — false positive

**Triệu chứng:** Deploy image đã sign nhưng bị Kyverno reject.

**Fix:**
```bash
# Check Kyverno admission controller logs
kubectl logs deploy/kyverno-admission-controller -n kyverno --tail=50

# Verify image signature thủ công
COSIGN_REPOSITORY=harbor.kythuat.vn/slsa/demo-api \
cosign verify --key k8s://tekton-pipelines/cosign-keys \
  harbor.kythuat.vn/slsa/demo-api@sha256:<DIGEST>

# Kiểm tra policy rule
kubectl get clusterpolicy verify-image-signature -o yaml | grep -A30 rules

# Common issues:
# 1. Image reference dùng tag thay vì digest
# 2. Cosign public key sai
# 3. COSIGN_REPOSITORY env không match
# 4. Policy pattern *.kythuat.vn/* không match image path
```

### 24. Kyverno — registryClient TLS error khi verify image từ Harbor

**Triệu chứng:** Logs Kyverno: `x509: certificate signed by unknown authority`.

**Nguyên nhân:** Kyverno không trust Harbor CA cert.

**Fix:**
```bash
# Cách 1: Mount Harbor CA vào Kyverno admission controller
# Thêm vào Helm values (ArgoCD apps/kyverno.yaml):
#   admissionController:
#     container:
#       extraVolumes:
#         - name: harbor-ca
#           secret:
#             secretName: harbor-ca-cert
#       extraVolumeMounts:
#         - name: harbor-ca
#           mountPath: /etc/ssl/certs/harbor-ca.crt
#           subPath: ca.crt

# Cách 2: Tạo Kyverno global context (v3+)
kubectl apply -f - <<EOF
apiVersion: kyverno.io/v2alpha1
kind: GlobalContextEntry
metadata:
  name: harbor-registry
spec:
  apiCall:
    urlPath: /api/v1/namespaces/harbor/secrets/harbor-harbor-nginx
    jmesPath: "data.\"ca.crt\" | base64_decode(@)"
EOF

# Cách 3: Copy Harbor CA vào system trust trên mỗi node
# (xem #20) — Kyverno chạy trên node nên nó sẽ kế thừa system CA
```

### 25. Kyverno webhook timeout — pod deploy chậm

**Triệu chứng:** Deploy resource timeout, logs: `context deadline exceeded`.

**Fix:**
```bash
# Check webhook configuration
kubectl get validatingwebhookconfiguration | grep kyverno

# Tăng timeout
kubectl patch validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg \
  --type=json \
  -p='[{"op":"replace","path":"/webhooks/0/timeoutSeconds","value":30}]'

# Hoặc restart Kyverno
kubectl -n kyverno rollout restart deploy/kyverno-admission-controller
```

---

## Kafka / Strimzi

### 26. Kafka broker pod CrashLoopBackOff

**Nguyên nhân:** Thường do storage hoặc memory.

**Fix:**
```bash
# Check logs
kubectl logs demo-cluster-combined-0 -n kafka --tail=30

# Kiểm tra PVC
kubectl get pvc -n kafka

# Kiểm tra resources requested
kubectl get pod demo-cluster-combined-0 -n kafka -o yaml | grep -A10 resources

# Nếu memory issue → giảm heap size trong Kafka CR
# KAFKA_HEAP_OPTS: "-Xms256m -Xmx512m"

# Nếu storage issue → kiểm tra StorageClass
kubectl get storageclass
kubectl describe pvc data-demo-cluster-combined-0 -n kafka
```

### 27. KafkaTopic not Ready

**Nguyên nhân:** Topic operator chưa sẵn sàng hoặc Kafka cluster chưa Ready.

**Fix:**
```bash
# Check Kafka cluster status trước
kubectl get kafka demo-cluster -n kafka -o jsonpath='{.status.conditions[*].type}'
# Phải có: Ready

# Check topic operator (sidecar trong Kafka pod)
kubectl logs demo-cluster-combined-0 -n kafka -c topic-operator --tail=20

# Kiểm tra topic
kubectl get kafkatopic demo-events -n kafka -o yaml

# Nếu topic stuck → delete + recreate
kubectl delete kafkatopic demo-events -n kafka
kubectl apply -f code/infra/k8s/manifests/kafka/kafka-cluster.yaml
```

### 28. Demo-worker không consume messages — consumer group lag

**Triệu chứng:** demo-api gửi events OK, nhưng demo-worker không nhận.

**Fix:**
```bash
# Check demo-worker logs
kubectl logs deploy/demo-worker -n demo --tail=20

# Check consumer group offset
kubectl run kafka-tools -it --rm --image=quay.io/strimzi/kafka:0.44.0-kafka-3.8.1 -- \
  bin/kafka-consumer-groups.sh \
  --bootstrap-server demo-cluster-kafka-bootstrap.kafka.svc:9092 \
  --describe --group demo-worker-group

# Check topic có messages không
kubectl run kafka-tools -it --rm --image=quay.io/strimzi/kafka:0.44.0-kafka-3.8.1 -- \
  bin/kafka-topics.sh \
  --bootstrap-server demo-cluster-kafka-bootstrap.kafka.svc:9092 \
  --topic demo-events --describe

# Thử restart demo-worker
kubectl -n demo rollout restart deploy/demo-worker
```

---

## Demo Applications

### 29. demo-api — service unreachable qua Cloudflare

**Triệu chứng:** `curl https://demo.kythuat.vn/healthz` trả về 502/504.

**Fix:**
```bash
# Check demo-api pod
kubectl get pods -n demo | grep demo-api

# Check service
kubectl get svc demo-api -n demo

# Check IngressRoute
kubectl get ingressroute -n demo

# Test in-cluster
kubectl run curl-test --rm -it --image=curlimages/curl -- \
  curl -s http://demo-api.demo.svc:8080/healthz

# Check Cloudflare tunnel route
kubectl -n cloudflare logs deploy/cloudflared | grep demo
```

### 30. demo-api/demo-worker image digest mismatch

**Triệu chứng:** ArgoCD sync nhưng pod vẫn dùng image cũ.

**Nguyên nhân:** Tekton `update-manifest` task ghi digest vào k8s/deployment.yaml, nhưng ArgoCD chưa detect thay đổi.

**Fix:**
```bash
# Force ArgoCD sync
argocd app sync demo-api --force

# Hoặc hard refresh
argocd app get demo-api --hard-refresh

# Kiểm tra digest trong deployment
kubectl get deploy demo-api -n demo -o jsonpath='{.spec.template.spec.containers[0].image}'
# Phải là: harbor.kythuat.vn/slsa/demo-api@sha256:...
```

---

## General Tips

### Xem tất cả non-Running pods
```bash
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

### Xem events gần nhất
```bash
kubectl get events -A --sort-by=.lastTimestamp | tail -20
```

### Restart một deployment
```bash
kubectl -n <namespace> rollout restart deploy/<name>
```

### Full cluster reset + recreate
```bash
cd code/infra/ansible/
make reset

# Re-provision
make setup

# Re-bootstrap platform
cd ../helmfile/
kubectl label node userver-home-worker node-role=worker workload-type=heavy
helmfile -f helmfile-bootstrap.yaml apply

# Post-bootstrap (xem 04-post-bootstrap.md)
# ArgoCD setup (xem 05-argocd-gitops.md)
# Cloudflare (xem 06-cloudflare-networking.md)

# Sau khi ArgoCD sync xong:
# Harbor CA cert → copy lên nodes (xem 10-harbor-registry.md#4)
# Tekton secrets → tạo lại (xem 09-tekton-ci-pipeline.md#2)
# Kyverno policies → verify (xem 11-kyverno-policies.md#3)
# Test E2E flow (xem 07-verification.md#phase-10)
```
