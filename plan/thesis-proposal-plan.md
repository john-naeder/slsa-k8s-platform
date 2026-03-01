# KẾ HOẠCH ĐỒ ÁN TỐT NGHIỆP
## Thiết kế và Triển khai Hệ thống Zero Trust Software Supply Chain trên Kubernetes theo chuẩn SLSA Level 3

**Thời gian thực hiện:** 01/03/2026 – 01/06/2026 (12 tuần)

---

## I. TRIẾT LÝ THIẾT KẾ ĐỀ XUẤT

### Nguyên tắc cốt lõi

> **Ưu tiên #1: Giá trị học thuật + Tính thực tiễn doanh nghiệp**
> Đồ án ưu tiên sử dụng **CNCF self-hosted tools** để tối đa hóa effort triển khai,
> chiều sâu kỹ thuật, và tính ứng dụng thực tế cho môi trường enterprise.

- **K8s là CORE duy nhất** — mọi thứ xoay quanh Kubernetes cluster
- **Self-hosted CNCF-first** — ưu tiên tool chạy trên K8s thay vì dùng SaaS → tăng công sức triển khai, tăng giá trị đồ án
- **Cost-effective cho doanh nghiệp** — toàn bộ stack self-hosted = miễn phí license, chỉ tốn compute → phù hợp khi tham chiếu cho doanh nghiệp vừa và nhỏ
- Kiến trúc **theo lớp (layered)** — nếu một lớp thay đổi công cụ thì các lớp khác không bị ảnh hưởng
- Mỗi thành phần đều có **phương án chính (self-hosted) + phương án dự phòng (SaaS)** để đảm bảo "nhiều đường chạy"

### Bảng lựa chọn công nghệ — Self-hosted CNCF First

| Thành phần | Phương án A — PRIMARY (Self-hosted CNCF) | Phương án B — FALLBACK (SaaS/Easy) | Lý do ưu tiên A |
|---|---|---|---|
| **CI/CD Engine** | **Tekton Pipelines + Tekton Chains** | GitHub Actions + slsa-github-generator | K8s-native, CNCF graduated, full control, doanh nghiệp dùng được |
| **Build Image** | **Kaniko** (rootless, daemonless on K8s) | Docker build (GitHub Actions) | Pod-level isolation, phù hợp Zero Trust, không cần Docker daemon |
| **Signing** | **Cosign** (keyless via Sigstore OIDC) | Cosign (key-based fallback) | Identity-based, phù hợp Zero Trust, transparency log qua Rekor |
| **Provenance** | **Tekton Chains** (tự observe & tạo in-toto attestation) | slsa-github-generator | Chạy trên K8s, tách biệt source platform vs build platform |
| **SBOM** | **Syft** (generate) + **Grype** (scan vulnerability) | Trivy (all-in-one) | Syft+Grype = Anchore stack, phổ biến enterprise |
| **Registry** | **Harbor** (self-hosted on K8s) | GHCR (GitHub Container Registry) | Tích hợp Trivy scanning, RBAC riêng, OCI artifact đầy đủ |
| **Policy Engine** | **Kyverno** (K8s-native, CNCF incubating) | Kyverno (không thay đổi) | YAML-native, built-in verifyImages, best-in-class cho image verification |
| **CD/Deploy** | **Argo CD** (GitOps, CNCF graduated) | kubectl apply / Kustomize | Pull-based GitOps = Zero Trust alignment, audit trail = Git history |
| **K8s Cluster** | WSL2 + kubeadm (local) | kind/k3s (nếu kubeadm lỗi) | kubeadm = production-like, giá trị học thuật cao hơn |

### Chiến lược thực hiện — Self-hosted First

```
Tuần 1-2:  Nền tảng — K8s cluster + nghiên cứu lý thuyết
Tuần 3-4:  Core pipeline — Tekton + Chains + Cosign + Kyverno (trên K8s)
Tuần 5-6:  Mở rộng — Harbor + Argo CD + SBOM workflow
Tuần 7-8:  Attack scenarios + Benchmark + GitHub Actions (để so sánh)
Tuần 9-12: Đánh giá, so sánh 2 approaches, viết báo cáo
```

> **Nguyên tắc vàng (CẬP NHẬT):** Ưu tiên triển khai Phương án A (Self-hosted) trước.
> Nếu gặp khó khăn lớn → fallback sang Phương án B (SaaS) cho thành phần đó.
> Nếu cả 2 đều chạy được → **so sánh A vs B** trong báo cáo → tăng giá trị nghiên cứu.

### Tại sao Self-hosted CNCF-first?

| Khía cạnh | Self-hosted CNCF | SaaS (GitHub) |
|---|---|---|
| **Effort triển khai** | Cao → tăng công sức đồ án → tăng điểm | Thấp → ít ấn tượng |
| **Giá trị học thuật** | Cao — phải hiểu sâu K8s, CRDs, networking | Thấp — click & play |
| **Enterprise relevance** | Cao — doanh nghiệp muốn self-hosted (data sovereignty, compliance) | Thấp — phụ thuộc vendor |
| **Chi phí doanh nghiệp** | $0 license (chỉ compute) → cost-effective | Tốn phí GitHub Enterprise |
| **Separation of concerns** | Source (GitHub) ≠ Build (K8s/Tekton) ≠ Registry (Harbor) | Single vendor = single point of failure |
| **Kiến trúc Zero Trust** | Mạnh — nhiều trust boundary riêng biệt | Yếu hơn — trust dồn vào 1 vendor |

---

## I.B. PHÂN TÍCH KHẢ NĂNG ĐẠT SLSA LEVEL 3 CỦA CÁC PHƯƠNG ÁN

### Build Track L3 — Yêu cầu & Đánh giá

SLSA Build L3 yêu cầu 6 điều kiện bắt buộc. Bảng dưới đối chiếu cả 2 phương án:

| # | Yêu cầu SLSA Build L3 | Phương án A (GitHub Actions) | Phương án B (Tekton on K8s) |
|---|---|---|---|
| 1 | **Automated build** — build phải tự động, không thủ công | ✅ Workflow trigger tự động khi push/PR | ✅ Tekton PipelineRun trigger tự động |
| 2 | **Hosted build platform** — chạy trên nền tảng quản lý, không phải máy dev | ✅ GitHub-hosted runners (Microsoft managed) | ✅ Tekton Pod chạy trên K8s cluster |
| 3 | **Signed provenance** — provenance phải được ký bởi build platform | ✅ `slsa-github-generator` ký qua Sigstore OIDC, identity = reusable workflow | ✅ Tekton Chains ký qua Cosign, identity = ServiceAccount |
| 4 | **Isolated builds** — mỗi build chạy độc lập, không cross-contamination | ✅ Mỗi workflow run dùng runner riêng, VM mới | ✅ Mỗi TaskRun chạy trong Pod riêng biệt |
| 5 | **Ephemeral environment** — môi trường dùng xong bị hủy | ✅ GitHub runner VM bị destroy sau khi job kết thúc | ✅ Pod bị delete sau khi TaskRun hoàn thành |
| 6 | **Unforgeable provenance** — build script KHÔNG thể truy cập signing key, KHÔNG thể giả mạo provenance | ✅ Reusable workflow chạy trong context riêng biệt, caller workflow không đụng được OIDC token dùng để ký | ✅ Tekton Chains chạy ở cluster-level controller, signing key nằm trong Chains config, không nằm trong Pod của TaskRun |

**Kết luận Build Track:** ✅ **CẢ 2 PHƯƠNG ÁN ĐỀU ĐẠT BUILD L3.** Không có phương án nào yếu hơn về mặt compliance.

### Source Track L3 — Yêu cầu & Đánh giá (theo draft SLSA v1.2)

| # | Yêu cầu Source Track | L1 | L2 | L3 | L4 | Phương án A & B |
|---|---|---|---|---|---|---|
| 1 | Version controlled | ✅ | ✅ | ✅ | ✅ | Git (GitHub/GitLab) |
| 2 | Immutable revisions (commit SHA) | ✅ | ✅ | ✅ | ✅ | Mặc định với Git |
| 3 | Authenticated identity + history | | ✅ | ✅ | ✅ | GitHub authentication + commit signing (GPG/SSH) |
| 4 | Source provenance (VSA) | | ✅ | ✅ | ✅ | GitHub natively hoặc cấu hình manual |
| 5 | **Block force push** on protected branches | | | ✅ | ✅ | GitHub Branch Protection Rules |
| 6 | **Block branch deletion** | | | ✅ | ✅ | GitHub Branch Protection Rules |
| 7 | **Require status checks** trước merge | | | ✅ | ✅ | GitHub required checks |
| 8 | Technical controls maintained liên tục | | | ✅ | ✅ | Rules applied permanently, audit trail |
| 9 | Two-party review (2 người approve) | | | | ✅ | ⚠️ Không bắt buộc cho L3, chỉ L4 |

**Kết luận Source Track:** ✅ **CẢ 2 PHƯƠNG ÁN ĐỀU ĐẠT SOURCE L3** — chỉ cần cấu hình đúng Branch Protection Rules trên GitHub.
Source L4 (two-party review) nằm NGOÀI phạm vi đồ án — đây là yêu cầu về tổ chức (cần ≥2 người), không phù hợp với đồ án cá nhân.

### ⚠️ Các lưu ý & gap tiềm ẩn

| Vấn đề | Mô tả | Ảnh hưởng đến L3? | Ghi chú |
|---|---|---|---|
| **Single point of trust (Phương án A)** | GitHub vừa là source platform vừa là build platform → nếu GitHub bị compromise thì cả source + build đều mất | Không ảnh hưởng (SLSA chấp nhận trusted platform) | Nhưng nên đề cập trong thesis như limitation |
| **Separation of concerns (Phương án B)** | Source trên GitHub, Build trên K8s/Tekton → 2 platform khác nhau, compromise 1 không ảnh hưởng cái kia | Tốt hơn về mặt kiến trúc | Nên đề cập như ưu điểm của B |
| **Key-based fallback** | Nếu Sigstore public down → dùng `cosign generate-key-pair` | Vẫn đạt L3, provenance vẫn signed | Mất lợi ích transparency log (Rekor) |
| **Admin override Branch Protection** | Admin GitHub có thể tắt branch protection bất cứ lúc nào | Source L3 spec yêu cầu "continuously enforced" | Trong scope đồ án, coi admin = trusted; nên ghi nhận trong limitation |
| **SBOM không phải yêu cầu của SLSA** | SLSA không yêu cầu SBOM để đạt L3 | Không ảnh hưởng | SBOM là bonus, thuộc scope "Zero Trust" rộng hơn |

---

## I.C. SO SÁNH CHI TIẾT LỢI ÍCH CÔNG NGHỆ (NỘI DUNG CHO THESIS — Chương 3)

> *Phần này dùng làm content plan cho việc viết so sánh trong Chương 3 của báo cáo.*

### 1. CI/CD Engine: GitHub Actions vs Tekton Pipelines

| Tiêu chí | GitHub Actions | Tekton Pipelines |
|---|---|---|
| **SLSA L3 compliance** | ✅ Đạt (qua slsa-github-generator) | ✅ Đạt (qua Tekton Chains) |
| **Độ phức tạp cài đặt** | Rất thấp — SaaS, không cần setup infra | Cao — cài CRDs trên K8s, config Chains, RBAC |
| **K8s-native** | ❌ Chạy trên GitHub infra, không liên quan K8s | ✅ Mọi thứ là K8s CRDs (Pipeline, Task, PipelineRun) |
| **Isolation mechanism** | VM-level (mỗi job = 1 VM mới) | Pod-level (mỗi TaskRun = 1 Pod mới) |
| **Provenance generation** | `slsa-github-generator` dùng reusable workflow, proven & well-documented | Tekton Chains observe build events, tự tạo provenance — ít documentation hơn |
| **Ecosystem maturity** | Rất mature, hàng triệu users | Mature nhưng niche, chủ yếu dùng trong enterprise K8s |
| **Cost** | Free cho public repos, 2000 min/month cho private | Free (self-hosted), nhưng tốn resource K8s |
| **Control** | Phụ thuộc GitHub — không kiểm soát runner infrastructure | Full control — build chạy trên K8s cluster của mình |
| **Giá trị học thuật cho đồ án** | Thấp hơn (dùng SaaS có sẵn) | Cao hơn (showcase K8s-native CI/CD, phù hợp đề tài) |
| **Rủi ro triển khai** | Rất thấp | Trung bình-Cao (config Chains, signing, RBAC) |

**Khuyến nghị cho thesis:** Dùng GitHub Actions để chạy được trước, sau đó triển khai thêm Tekton để **so sánh 2 approaches** trong báo cáo → tăng giá trị nghiên cứu. Nếu Tekton fail, GitHub Actions đã đủ.

### 2. Policy Engine: Kyverno vs OPA Gatekeeper (+ Ratify)

| Tiêu chí | Kyverno | OPA Gatekeeper + Ratify |
|---|---|---|
| **SLSA verification** | ✅ Built-in `verifyImages` tích hợp Cosign — verify signature + attestation trong 1 policy | ✅ Cần Ratify (external data provider) để verify signature, OPA viết constraint |
| **Policy language** | YAML thuần túy (K8s-native) | Rego (DSL riêng, learning curve cao) |
| **Dễ trình bày trong báo cáo** | Rất dễ — YAML ai đọc cũng hiểu | Khó — Rego cần giải thích cú pháp |
| **Image verification** | Native: `verifyImages`, `attestations`, `imageReferences` | Cần Ratify plugin hoặc custom Rego logic |
| **Mutating policies** | ✅ Có thể tự động mutate (VD: auto-add digest) | ✅ Có nhưng phức tạp hơn |
| **Community & docs** | Docs tốt, nhiều example policies cho image verification | Docs tốt cho general policy, ít example cho SLSA-specific |
| **Performance** | Nhẹ, single controller | Nặng hơn (Gatekeeper + Ratify = 2 components) |
| **Rủi ro triển khai** | Thấp | Trung bình (cài 2 tool, config webhook chaining) |

**Khuyến nghị cho thesis:** **Kyverno là lựa chọn rõ ràng** cho đồ án — dễ cài, dễ viết policy, dễ trình bày. OPA Gatekeeper chỉ nên đề cập trong phần "công nghệ thay thế" (related work/comparison) chứ không cần triển khai.

### 3. Container Registry: GHCR vs Harbor

| Tiêu chí | GHCR (GitHub Container Registry) | Harbor (self-hosted) |
|---|---|---|
| **OCI artifact support** | ✅ Hỗ trợ Cosign signatures, SBOM, attestations | ✅ Hỗ trợ đầy đủ OCI artifacts |
| **Cài đặt** | Không cần — đã có sẵn với GitHub account | Phức tạp — cần deploy trên K8s (Helm chart), cần storage, DB |
| **Vulnerability scanning** | ❌ Không có built-in | ✅ Tích hợp Trivy scanner |
| **Access control** | GitHub-based (token, OIDC) | Harbor RBAC, LDAP, OIDC |
| **Ảnh hưởng đến SLSA L3** | Không — registry không phải yêu cầu SLSA | Không |
| **Giá trị học thuật** | Thấp (SaaS) | Cao (self-hosted, showcase K8s deployment) |
| **Tài nguyên cần thiết** | 0 (cloud) | ~2GB RAM, cần PV cho storage |
| **Rủi ro triển khai** | Rất thấp | Trung bình (config TLS, storage, ingress) |

**Khuyến nghị cho thesis:** Dùng GHCR trước. Nếu còn thời gian, deploy Harbor và so sánh → nội dung hay cho thesis. Harbor KHÔNG ảnh hưởng đến SLSA L3 nhưng tăng tính "self-hosted" phù hợp đề tài K8s.

### 4. Signing: Keyless (Sigstore OIDC) vs Key-based (cosign generate-key-pair)

| Tiêu chí | Keyless (Fulcio + Rekor) | Key-based (manual key pair) |
|---|---|---|
| **SLSA L3 compliance** | ✅ Đạt | ✅ Đạt (key được quản lý bởi platform, không phải user) |
| **Key management** | Không cần — ephemeral certificates | Cần bảo mật private key (K8s Secret / Vault) |
| **Transparency** | ✅ Ghi log vào Rekor (public ledger, anti-tamper) | ❌ Không có transparency log |
| **Audit trail** | Mạnh — ai ký, khi nào, certificate chain rõ ràng | Yếu hơn — chỉ biết "ai có key" |
| **Internet dependency** | Cần kết nối Fulcio + Rekor | Không cần internet (hoàn toàn offline) |
| **Phù hợp Zero Trust** | Rất phù hợp — identity-based, không shared secret | Kém hơn — key là shared secret |
| **Rủi ro** | Phụ thuộc Sigstore public infra uptime | Key bị leak = compromise toàn bộ |

**Khuyến nghị cho thesis:** Keyless là primary choice (phù hợp Zero Trust narrative). Key-based là fallback. Trong thesis nên phân tích trade-off giữa 2 cách → thể hiện chiều sâu.

### 5. Build Tool: Docker build vs Kaniko vs Buildah

| Tiêu chí | Docker build (GH Actions) | Kaniko (on K8s) | Buildah (on K8s) |
|---|---|---|---|
| **Rootless** | N/A (chạy trên GH runner) | ✅ Rootless by design | ✅ Hỗ trợ rootless |
| **Daemonless** | ❌ Cần Docker daemon | ✅ Không cần daemon | ✅ Không cần daemon |
| **K8s-native** | ❌ | ✅ Chạy trong Pod | ✅ Chạy trong Pod |
| **OCI compliant** | ✅ | ✅ | ✅ |
| **Cache support** | ✅ Layer cache, BuildKit | ✅ Registry cache | ✅ Overlay cache |
| **Ảnh hưởng SLSA L3** | Không — build tool không ảnh hưởng, provenance do platform tạo | Không | Không |
| **Độ phức tạp** | Rất thấp | Trung bình (config credentials, cache) | Trung bình |

**Khuyến nghị cho thesis:** Docker build trên GH Actions cho Easy Path. Kaniko cho Tekton path (phổ biến nhất trong K8s CI). Buildah là alternative, chỉ cần đề cập.

### 6. CD/Deploy: kubectl/Kustomize vs Argo CD

| Tiêu chí | kubectl apply / Kustomize | Argo CD (GitOps) |
|---|---|---|
| **Mô hình** | Imperative / Semi-declarative | Declarative GitOps (pull-based) |
| **Ảnh hưởng SLSA L3** | Không — CD tool không ảnh hưởng SLSA compliance | Không |
| **Zero Trust alignment** | Yếu — ai có kubeconfig đều deploy được | Mạnh — chỉ Argo CD pull từ Git, không ai push trực tiếp |
| **Audit trail** | Yếu — phụ thuộc K8s audit log | Mạnh — Git history = deployment history |
| **Cài đặt** | Không cần cài thêm | Cài Argo CD trên K8s |
| **Giá trị học thuật** | Thấp | Cao — GitOps là xu hướng DevSecOps |
| **Rủi ro** | Rất thấp | Thấp-Trung bình |

**Khuyến nghị cho thesis:** kubectl cho quick demo. Argo CD nếu có thời gian — phù hợp narrative "Zero Trust" (no human push to cluster). Nhưng Argo CD KHÔNG ảnh hưởng SLSA score nên priority thấp.

### Tổng kết: Bản đồ ưu tiên công nghệ (CẬP NHẬT — Full Platform)

```
MUST-HAVE (bắt buộc — platform không chạy nếu thiếu):
├── K8s cluster (kubeadm, bare metal) ← production-like
├── Flannel CNI (pod networking qua tailscale0)
├── Tailscale VPN (inter-node communication)
├── Helm (deploy mọi thứ)
├── local-path-provisioner (dynamic PVC cho bare metal)
├── Traefik (Ingress Controller, reverse proxy)
├── cloudflared (Cloudflare Tunnel — expose ra internet)
├── Tekton Pipelines + Tekton Chains (CI/CD + provenance) ← SLSA
├── Kaniko (rootless build on K8s) ← SLSA
├── Cosign keyless (signing via Sigstore OIDC) ← SLSA
├── Kyverno (policy engine verify tại deploy) ← SLSA
└── Harbor (self-hosted OCI registry on K8s) ← SLSA

SHOULD-HAVE (production-like, tăng chiều sâu):
├── cert-manager (TLS tự động, Let's Encrypt)
├── Argo CD (GitOps CD) ← Zero Trust alignment
├── Sealed Secrets (encrypt secrets trong Git)
├── Prometheus + Grafana (monitoring & dashboards)
├── Alertmanager (alert routing)
├── Loki + Promtail (log aggregation — lightweight, tích hợp Grafana)
└── Kafka via Strimzi Operator (inter-service messaging, K8s-native CRD)

NICE-TO-HAVE (bonus nếu còn thời gian):
├── MetalLB (bare metal LoadBalancer — KHÔNG CẦN nếu dùng cloudflared + hostNetwork)
├── Istio hoặc Linkerd (service mesh, mTLS)
├── SBOM workflow (Syft + Grype + Kyverno verify)
├── GitHub Actions + slsa-github-generator (so sánh)
└── OPA Gatekeeper + Ratify (compare với Kyverno)

DEFER (cài khi có service cụ thể cần):
├── MongoDB / PostgreSQL (database)
├── MinIO (S3 object storage)
└── Redis (cache)
```

> **Xem chi tiết tại mục I.F — Platform Commitment**

---

## I.D. BẢNG TỔNG HỢP CÔNG NGHỆ CẦN HỌC

> *Bảng short-form mapping: Công nghệ → Vai trò trong hệ thống → Chương/Phần trong báo cáo → Mức ưu tiên học*

| # | Công nghệ | Vai trò / Module | Chương báo cáo | Mức ưu tiên | Ghi chú |
|---|---|---|---|---|---|
| | **── CORE PLATFORM ──** | | | | |
| 1 | **Kubernetes (kubeadm)** | Core platform — chạy toàn bộ hệ thống | Ch2§2.4, Ch3§3.1, Ch4§4.1 | 🔴 CRITICAL | Phải hiểu sâu — xem phần I.E |
| 2 | **Helm** | Package manager — deploy mọi thứ qua chart | Ch4§4.1 | 🔴 CRITICAL | values.yaml customization, upgrade, rollback |
| 3 | **local-path-provisioner** | Storage — dynamic PVC cho bare metal | Ch4§4.1 | 🔴 CRITICAL | Rancher project, StorageClass default |
| | **── NETWORKING & INGRESS ──** | | | | |
| 4 | **Traefik** | Ingress Controller — reverse proxy, routing, middlewares | Ch3§3.1, Ch4§4.1 | 🔴 CRITICAL | IngressRoute CRD, TLS termination, rate-limit |
| 5 | **cloudflared** | Tunnel — expose K8s services ra internet không cần public IP | Ch3§3.1, Ch4§4.1 | 🔴 CRITICAL | Deployment, outbound-only, Cloudflare dashboard |
| 6 | ~~MetalLB~~ | ~~LoadBalancer~~ — **KHÔNG CẦN** khi dùng cloudflared + Traefik ClusterIP | Ch4§4.1 | 🟢 LOW | Chỉ cần nếu muốn `type: LoadBalancer`; combo cloudflared→Traefik(ClusterIP) bypass hoàn toàn |
| 7 | **cert-manager** | TLS — auto-issue cert từ Let's Encrypt hoặc self-signed | Ch4§4.1 | 🟠 HIGH | ClusterIssuer, Certificate CRD |
| | **── CI/CD & SLSA ──** | | | | |
| 8 | **Tekton Pipelines** | CI/CD engine — build pipeline trên K8s | Ch2§2.5, Ch3§3.3, Ch4§4.2 | 🔴 CRITICAL | CRDs: Pipeline, Task, PipelineRun, Workspace |
| 9 | **Tekton Chains** | Provenance — tự tạo in-toto attestation sau build | Ch2§2.5, Ch3§3.3.2, Ch4§4.2 | 🔴 CRITICAL | Config signing backend, observe TaskRun results |
| 10 | **Cosign** | Signing — ký image + verify signature | Ch2§2.5.1, Ch3§3.3.4, Ch4§4.2 | 🔴 CRITICAL | Keyless (OIDC), cosign sign/verify, attach attestation |
| 11 | **Kyverno** | Policy Engine — admission control trên K8s | Ch2§2.5.3, Ch3§3.4, Ch4§4.3 | 🔴 CRITICAL | ClusterPolicy, verifyImages, attestations |
| 12 | **Kaniko** | Build tool — build OCI image rootless trên K8s | Ch3§3.3.1, Ch4§4.2 | 🟠 HIGH | Chạy trong Tekton Task, push to Harbor |
| 13 | **Harbor** | Registry — OCI artifact storage self-hosted | Ch3§3.1, Ch4§4.1 | 🟠 HIGH | Helm install, TLS, PV, Trivy scanner tích hợp |
| 14 | **Argo CD** | CD — GitOps pull-based deployment | Ch3§3.4, Ch4§4.2 | 🟠 HIGH | Application CRD, sync policy, RBAC |
| | **── OBSERVABILITY ──** | | | | |
| 15 | **Prometheus** | Metrics — scrape, store, PromQL query | Ch3§3.1, Ch4§4.4 | 🟠 HIGH | kube-prometheus-stack Helm chart |
| 16 | **Grafana** | Dashboards — visualize metrics, logs | Ch4§4.4 | 🟠 HIGH | Pre-built K8s dashboards, custom panels |
| 17 | **Alertmanager** | Alerting — route alerts từ Prometheus | Ch4§4.4 | 🟡 MEDIUM | Webhook / email receivers |
| 18 | **Loki + Promtail** | Logging — log aggregation (lightweight, thay ELK) | Ch4§4.4 | 🟠 HIGH | LogQL, tích hợp Grafana; ELK quá nặng cho bare metal (~4-6GB RAM vs ~512MB) |
| | **── MESSAGING ──** | | | | |
| 18b | **Kafka (Strimzi Operator)** | Event streaming — giao tiếp giữa microservices | Ch3§3.1, Ch4§4.1 | 🟠 HIGH | CRD-based (Kafka, KafkaTopic); KRaft mode (no ZooKeeper); ~1-1.5GB RAM |
| | **── SECURITY ──** | | | | |
| 19 | **Sealed Secrets** | Secret management — encrypt secrets lưu trong Git | Ch4§4.1 | 🟠 HIGH | kubeseal CLI, SealedSecret CRD |
| | **── SLSA THEORY & COMPARISON ──** | | | | |
| 20 | **SLSA Framework** | Tiêu chuẩn — Build Track L3 + Source Track L3 | Ch2§2.3, Ch3§3.3, Ch4§4.6 | 🟡 MEDIUM | Spec reading, threat model, provenance schema |
| 21 | **in-toto** | Attestation format — provenance JSON schema | Ch2§2.3, Ch3§3.3.2 | 🟡 MEDIUM | Statement, predicate, subject format |
| 22 | **Sigstore (Fulcio + Rekor)** | PKI + Transparency — certificate authority + public ledger | Ch2§2.5.1 | 🟡 MEDIUM | Hiểu workflow, không cần self-host |
| 23 | **Syft** | SBOM generation — tạo Software Bill of Materials | Ch2§2.5.2, Ch3§3.3.3, Ch4§4.2 | 🟡 MEDIUM | Output SPDX/CycloneDX, attach to OCI |
| 24 | **Grype** | Vulnerability scan — quét CVE từ SBOM | Ch4§4.2 | 🟡 MEDIUM | Scan SBOM hoặc image trực tiếp |
| 25 | **GitHub Actions** | CI/CD SaaS — pipeline so sánh với Tekton | Ch3§3.3, Ch4§4.2 | 🟢 LOW | Chỉ dùng để so sánh, không phải primary |
| 26 | **slsa-github-generator** | Provenance SaaS — SLSA L3 trên GitHub | Ch4§4.2 | 🟢 LOW | Reusable workflow, so sánh với Chains |
| | **── OPTIONAL / FUTURE ──** | | | | |
| 27 | **Istio / Linkerd** | Service mesh — mTLS, traffic management | Ch3§3.1 | 🟢 LOW | Resource-heavy, chỉ nếu còn thời gian |
| 28 | **OPA Gatekeeper + Ratify** | Policy Engine thay thế — so sánh với Kyverno | Ch3§3.4 | 🟢 LOW | Chỉ mention trong related work |
| 29 | **LaTeX** | Viết báo cáo | Toàn bộ | 🟡 MEDIUM | Template đã có, chỉ cần viết content |

**Chú thích mức ưu tiên:**
- 🔴 **CRITICAL** — Phải thành thạo, là core của đồ án. Dành 50% thời gian học.
- 🟠 **HIGH** — Cần triển khai được, tăng chiều sâu đáng kể. Dành 30% thời gian.
- 🟡 **MEDIUM** — Cần hiểu concept, không cần expert. Dành 15% thời gian.
- 🟢 **LOW** — Chỉ dùng để so sánh hoặc bonus. Dành 5% thời gian.

> **Xem chi tiết bảng đầy đủ kèm resource estimate tại I.F — Platform Commitment §6**

### Learning Path đề xuất (theo thứ tự)

```
── PHASE 1: Foundation (tuần 1-2) ──────────────────────────
Bước 01: K8s fundamentals         → kubeadm, Pods, Services, RBAC, Admission Controllers
Bước 02: Helm                     → chart install, values.yaml, upgrade, rollback
Bước 03: local-path-provisioner   → StorageClass, PVC binding, dynamic provisioning

── PHASE 2: Networking & Exposure (tuần 3-4) ──────────────
Bước 04: Traefik                  → IngressRoute CRD, middlewares, TLS, hostNetwork
Bước 05: cloudflared              → Cloudflare Tunnel, DNS routing, zero-trust access
Bước 06: cert-manager             → ClusterIssuer, Let's Encrypt (hoặc self-signed)

── PHASE 3: CI/CD + SLSA Core (tuần 5-8) ──────────────────
Bước 07: Tekton trên K8s          → CRDs, Pipeline, Task, Workspace, PipelineRun
Bước 08: Tekton Chains + Cosign   → signing config, provenance generation, verify
Bước 09: Kaniko build trên Tekton → Dockerfile, Tekton Task với Kaniko executor
Bước 10: Harbor trên K8s          → Helm install, TLS, storage, push/pull
Bước 11: Kyverno policies         → ClusterPolicy, verifyImages, deny unsigned

── PHASE 4: GitOps + Secrets (tuần 9-10) ──────────────────
Bước 12: Sealed Secrets           → kubeseal CLI, SealedSecret CRD, encrypt/decrypt
Bước 13: Argo CD                  → GitOps Application, sync, RBAC, auto-deploy

── PHASE 5: Messaging + Observability (tuần 11-12) ────────
Bước 14: Kafka (Strimzi)          → Kafka CRD, KafkaTopic, producer/consumer demo
Bước 15: Prometheus + Grafana     → kube-prometheus-stack, PromQL, dashboards
Bước 16: Loki + Promtail          → log aggregation, LogQL, Grafana datasource
Bước 17: Alertmanager             → alert rules, receivers, silences

── PHASE 6: Polish & Compare (tuần 13+) ──────────────────
Bước 18: SBOM (Syft + Grype)      → generate, attach, verify via Kyverno
Bước 19: GitHub Actions           → slsa-github-generator (để so sánh)
Bước 20: Istio / Linkerd          → service mesh (bonus nếu còn thời gian)
```

---

## I.E. KUBERNETES DEEP-DIVE — CẦN NGHIÊN CỨU KỸ PHẦN NÀO?

> *K8s là nền tảng core của toàn bộ đồ án. Phần này giải thích CỤ THỂ những khía cạnh nào
> của K8s cần nghiên cứu sâu để triển khai tối đa giá trị đồ án.*

### 1. Admission Controllers (MỨC ĐỘ: ★★★★★ — Quan trọng nhất)

**Tại sao?** Đây là trái tim của Zero Trust enforcement trên K8s. Mọi request tạo/update Pod
đều đi qua Admission Controller → đây là nơi Kyverno chặn unsigned image.

**Cần học:**
- **ValidatingWebhookConfiguration** — cách K8s gọi webhook khi có API request
- **MutatingWebhookConfiguration** — cách Kyverno auto-mutate (VD: thêm image digest)
- **Admission flow:** API Request → Authentication → Authorization → Mutating Admission → Object Schema Validation → Validating Admission → Persist to etcd
- **Tại sao Kyverno hoạt động:** Kyverno đăng ký webhook → K8s API server gửi mọi Pod creation request đến Kyverno → Kyverno check policy → Allow/Deny
- **Failure mode:** Nếu Kyverno down → `failurePolicy: Fail` (deny all) vs `Ignore` (allow all) → trade-off availability vs security

**Giá trị cho thesis:** Mô tả flow admission control = **chứng minh bạn hiểu cách K8s enforce policy ở tầng hạ tầng**, không chỉ "cài Kyverno rồi chạy".

### 2. Custom Resource Definitions — CRDs (MỨC ĐỘ: ★★★★★)

**Tại sao?** Tekton, Kyverno, Argo CD — tất cả đều hoạt động bằng CRDs. Hiểu CRD = hiểu cách mọi tool CNCF mở rộng K8s.

**Cần học:**
- **CRD là gì:** Cách mở rộng K8s API bằng custom objects (VD: `Pipeline`, `Task`, `ClusterPolicy`, `Application`)
- **Controller pattern:** CRD + Controller = Operator. Controller watch CRD changes → reconcile state
- **Tekton CRDs:**
  - `Pipeline` — định nghĩa chuỗi tasks
  - `Task` — 1 unit of work (VD: build, sign, push)
  - `PipelineRun` / `TaskRun` — instance thực thi
  - `Workspace` — shared storage giữa các tasks
- **Kyverno CRDs:**
  - `ClusterPolicy` / `Policy` — rules áp dụng cluster-wide hoặc namespace-scoped
  - `PolicyReport` — kết quả violations
- **Argo CD CRDs:**
  - `Application` — đại diện 1 deployed app
  - `AppProject` — RBAC cho nhóm applications

**Giá trị cho thesis:** Giải thích CRD pattern = **thể hiện hiểu biết kiến trúc**, không chỉ "cài Helm rồi apply YAML".

### 3. RBAC — Role-Based Access Control (MỨC ĐỘ: ★★★★☆)

**Tại sao?** Tekton Chains cần ServiceAccount với quyền cụ thể để ký provenance. Kyverno cần quyền read Secrets (chứa public key). Mỗi component cần least-privilege.

**Cần học:**
- **ServiceAccount** — identity của Pod/controller trong K8s
- **Role / ClusterRole** — tập hợp permissions (verbs + resources)
- **RoleBinding / ClusterRoleBinding** — gán Role cho ServiceAccount
- **Least-privilege cho từng component:**
  - Tekton Chains SA: cần `get/patch` trên `TaskRun`, cần access `Secret` (signing key)
  - Kyverno SA: cần `get` trên `Secret` (cosign public key), webhook permissions
  - Argo CD SA: cần `create/update/delete` trên K8s resources trong target namespace
  - Kaniko SA: cần `imagePullSecrets` để push image lên Harbor

**Giá trị cho thesis:** Demo least-privilege RBAC = **Zero Trust principle "never trust, always verify"** áp dụng ngay ở infrastructure level.

### 4. Pod Lifecycle & Ephemeral Workloads (MỨC ĐỘ: ★★★★☆)

**Tại sao?** SLSA L3 yêu cầu **ephemeral build environment**. Tekton tạo Pod per TaskRun → Pod chạy → Pod bị xóa. Cần hiểu lifecycle này để chứng minh compliance.

**Cần học:**
- **Pod phases:** Pending → Running → Succeeded/Failed
- **Init containers** — Tekton dùng init containers để setup workspace
- **Ephemeral storage** — emptyDir volumes bị xóa khi Pod terminate
- **Resource limits** — CPU/memory limits cho build Pod → chứng minh isolation
- **Pod Security Context** — `runAsNonRoot: true`, `readOnlyRootFilesystem` → defense in depth
- **Pod Security Standards** — Restricted profile cho build Pods

**Giá trị cho thesis:** Phân tích Pod lifecycle = **chứng minh SLSA L3 requirement "ephemeral environment"** bằng cơ chế K8s native, không phải lý thuyết suông.

### 5. Networking & Service Exposure (MỨC ĐỘ: ★★★☆☆)

**Tại sao?** Harbor cần expose HTTPS (Ingress + TLS). Tekton Dashboard cần access. Kyverno webhook cần stable endpoint.

**Cần học:**
- **Service types:** ClusterIP (internal), NodePort (expose ra ngoài), LoadBalancer
- **Ingress / IngressClass** — route HTTP(S) traffic vào Harbor UI/API
- **TLS certificates** — cert-manager hoặc self-signed cho Harbor
- **NetworkPolicy** — isolate namespaces (VD: build namespace không reach management namespace)

**Giá trị cho thesis:** NetworkPolicy = **Zero Trust micro-segmentation** ở network layer.

### 6. Persistent Storage (MỨC ĐỘ: ★★★☆☆)

**Tại sao?** Harbor cần PersistentVolume để lưu container images, SBOM, signatures. Tekton cần Workspace cho build artifacts.

**Cần học:**
- **PersistentVolume (PV) / PersistentVolumeClaim (PVC)** — dynamic provisioning
- **StorageClass** — local-path (WSL2) hoặc hostPath
- **Tekton Workspaces** — dùng PVC hoặc emptyDir cho shared data giữa Tasks
- **Harbor storage backend** — filesystem (PV) hoặc S3-compatible

### 7. Helm & Package Management (MỨC ĐỘ: ★★★☆☆)

**Tại sao?** Tekton, Kyverno, Harbor, Argo CD — tất cả deploy qua Helm chart. Cần biết customize values.

**Cần học:**
- **helm install / upgrade / rollback**
- **values.yaml overrides** — customize config cho từng chart
- **helm repo add** — thêm chart repositories (tektoncd, kyverno, harbor, argoproj)
- **Dependency management** — chart dependencies, sub-charts

### Tổng kết: K8s Knowledge Map cho đồ án

```
                    ┌─────────────────────────────────────────┐
                    │           K8s API Server                 │
                    │  (Authentication → Authorization →      │
                    │   Admission Control → Persist)          │
                    └─────┬──────────┬──────────┬─────────────┘
                          │          │          │
              ┌───────────▼──┐  ┌────▼─────┐  ┌▼──────────────┐
              │ Admission    │  │  CRDs    │  │    RBAC       │
              │ Controllers  │  │          │  │               │
              │ ★★★★★        │  │ ★★★★★    │  │  ★★★★☆        │
              │              │  │          │  │               │
              │ • Kyverno    │  │ • Tekton │  │ • SA per tool │
              │   webhooks   │  │ • Kyverno│  │ • Least-priv  │
              │ • Deny       │  │ • ArgoCD │  │ • Secrets     │
              │   unsigned   │  │          │  │   access      │
              └──────────────┘  └──────────┘  └───────────────┘
                          │          │          │
              ┌───────────▼──┐  ┌────▼─────┐  ┌▼──────────────┐
              │ Pod Security │  │ Storage  │  │  Networking   │
              │ & Lifecycle  │  │          │  │               │
              │ ★★★★☆        │  │ ★★★☆☆    │  │  ★★★☆☆        │
              │              │  │          │  │               │
              │ • Ephemeral  │  │ • PV/PVC │  │ • Ingress     │
              │   builds     │  │ • Harbor │  │ • TLS/cert    │
              │ • PSS        │  │   storage│  │ • NetPolicy   │
              │ • Resource   │  │ • Tekton │  │               │
              │   limits     │  │   WS     │  │               │
              └──────────────┘  └──────────┘  └───────────────┘
```

---

## I.F. PLATFORM COMMITMENT — TOÀN BỘ TECH STACK CHO MICROSERVICES TRÊN K8S

> *Phần này mở rộng từ stack SLSA-specific (I.D) sang TOÀN BỘ hạ tầng cần có để
> vận hành microservices production-grade trên bare metal K8s qua Tailscale.*
>
> **Bối cảnh:** Hiện chưa có service cụ thể nào cần deploy — tương lai có thể là
> .NET, React, Spring Boot, MongoDB, MinIO, Kafka, v.v. Hiện tại chỉ cần
> **1 demo web app nhỏ** để chứng minh toàn bộ pipeline hoạt động end-to-end.

### Kiến trúc tổng thể — Platform Layers

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         INTERNET                                            │
│                            │                                                │
│                    ┌───────▼───────┐                                        │
│                    │  Cloudflare   │  DNS + CDN + DDoS protection            │
│                    │   Tunnel      │  (cloudflared trên K8s)                 │
│                    └───────┬───────┘                                        │
│                            │                                                │
├────────────────────────────┼────────────────────────────────────────────────┤
│  Layer 5: INGRESS          │                                                │
│                    ┌───────▼───────┐                                        │
│                    │   Traefik     │  Ingress Controller                     │
│                    │   (+ cert-    │  Routing, TLS termination,              │
│                    │    manager)   │  middleware (rate-limit, auth)          │
│                    └───────┬───────┘                                        │
│                            │                                                │
├────────────────────────────┼────────────────────────────────────────────────┤
│  Layer 4: SERVICE MESH     │                                                │
│                    ┌───────▼───────┐                                        │
│                    │    Istio      │  mTLS, traffic management,              │
│                    │  (sidecar /   │  observability, canary deploy           │
│                    │   ambient)    │                                         │
│                    └───────┬───────┘                                        │
│                            │                                                │
├────────────────────────────┼────────────────────────────────────────────────┤
│  Layer 3: APP WORKLOADS    │                                                │
│              ┌─────────────┼──────────────┐                                 │
│              │             │              │                                  │
│         ┌────▼───┐   ┌────▼───┐   ┌──────▼─────┐                           │
│         │ Demo   │   │ Future │   │  Future    │                            │
│         │ App    │   │ API    │   │  Frontend  │                            │
│         │(Go/    │   │(Spring/│   │  (React/   │                            │
│         │ Node)  │   │ .NET)  │   │   Next)    │                            │
│         └────────┘   └────────┘   └────────────┘                            │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│  Layer 2: PLATFORM SERVICES                                                 │
│                                                                             │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────────┐ ┌────────────────┐  │
│  │ Harbor   │ │ Tekton   │ │ Argo CD  │ │ Kyverno    │ │ Sealed Secrets │  │
│  │(Registry)│ │(CI/CD)   │ │(GitOps)  │ │(Policy)    │ │ (Secret Mgmt)  │  │
│  └──────────┘ └──────────┘ └──────────┘ └────────────┘ └────────────────┘  │
│                                                                             │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────────┐                     │
│  │Prometheus│ │ Grafana  │ │  Loki    │ │Alertmanager│                     │
│  │(Metrics) │ │(Dashboard│ │(Logging) │ │(Alerts)    │                     │
│  └──────────┘ └──────────┘ └──────────┘ └────────────┘                     │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│  Layer 1: MESSAGING & DATA SERVICES                                        │
│                                                                             │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────────┐                     │
│  │  Kafka  │ │ MongoDB  │ │  MinIO   │ │   Redis    │                     │
│  │(Strimzi)│ │  (DB)    │ │(S3 store)│ │  (Cache)   │                     │
│  │ SHOULD  │ │  DEFER   │ │  DEFER   │ │   DEFER    │                     │
│  └──────────┘ └──────────┘ └──────────┘ └────────────┘                     │
│                                                                             │
├─────────────────────────────────────────────────────────────────────────────┤
│  Layer 0: INFRASTRUCTURE                                                    │
│                                                                             │
│  ┌──────────┐ ┌──────────┐ ┌───────────────┐ ┌───────────────────────────┐ │
│  │ K8s      │ │ Flannel  │ │ local-path-   │ │ cert-manager              │ │
│  │(kubeadm) │ │  (CNI)   │ │ provisioner   │ │ (TLS certs)               │ │
│  └──────────┘ └──────────┘ └───────────────┘ └───────────────────────────┘ │
│                                                                             │
│  ┌──────────┐ ┌──────────┐                                               │
│  │Tailscale │ │  Helm    │                                               │
│  │  (VPN)   │ │(Pkg Mgr) │                                               │
│  └──────────┘ └──────────┘                                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1. FULL PLATFORM COMMITMENT — Danh sách component bắt buộc

> Chia theo mức ưu tiên: 🔴 MUST (không có = không chạy được) → 🟠 SHOULD (cần cho production-like) → 🟡 NICE (tăng giá trị đồ án)

#### Layer 0: Infrastructure — Nền tảng hạ tầng

| # | Component | Vai trò | Cài đặt | Ưu tiên | Ghi chú |
|---|---|---|---|---|---|
| 0.1 | **Kubernetes (kubeadm)** | Container orchestration platform | Ansible (đã có) | 🔴 MUST | v1.32, bare metal Ubuntu 24.04 |
| 0.2 | **Flannel** | Pod networking (CNI) | Ansible role `cni_flannel` | 🔴 MUST | `--iface=tailscale0` cho cross-node |
| 0.3 | **Tailscale** | VPN overlay — inter-node communication | Thủ công + bootstrap scripts | 🔴 MUST | Đã setup, nodes giao tiếp qua 100.x.x.x |
| 0.4 | **Helm** | Package manager cho K8s | `curl \| bash` hoặc `apt` | 🔴 MUST | Deploy mọi thứ từ Layer 1 trở lên |
| 0.5 | **local-path-provisioner** | Dynamic PV provisioning cho bare metal | `kubectl apply` (Rancher) | 🔴 MUST | Harbor, MongoDB, Loki, v.v. đều cần PVC |
| 0.6 | ~~MetalLB~~ | ~~LoadBalancer cho bare metal~~ | Helm | 🟢 LOW | **KHÔNG CẦN** khi dùng Traefik (ClusterIP/hostNetwork) + cloudflared. Chỉ cần nếu muốn `type: LoadBalancer` |
| 0.7 | **cert-manager** | Tự động cấp & renew TLS certificates | Helm | 🟠 SHOULD | Let's Encrypt + ClusterIssuer; hoặc self-signed cho internal |

#### Layer 2: Platform Services — Core CI/CD & Security (SLSA stack — đã có trong plan)

| # | Component | Vai trò | Ưu tiên | Ghi chú |
|---|---|---|---|---|
| 2.1 | **Tekton Pipelines + Chains** | CI/CD engine + provenance generation | 🔴 MUST | SLSA L3 core |
| 2.2 | **Cosign** | Image signing (keyless OIDC) | 🔴 MUST | SLSA L3 core |
| 2.3 | **Kyverno** | Admission policy engine | 🔴 MUST | Verify signature + provenance tại deploy |
| 2.4 | **Harbor** | OCI registry (self-hosted) | 🔴 MUST | Chứa images, signatures, SBOM, attestations |
| 2.5 | **Argo CD** | GitOps CD (pull-based deploy) | 🟠 SHOULD | Zero Trust alignment — no human push to cluster |
| 2.6 | **Kaniko** | Rootless image build trong Tekton | 🔴 MUST | Daemonless, Pod-level isolation |
| 2.7 | **Syft + Grype** | SBOM generation + vuln scan | 🟡 NICE | SBOM không bắt buộc cho SLSA L3 |

#### Layer 2 (mới): Observability — Monitoring, Logging, Alerting

| # | Component | Vai trò | Cài đặt | Ưu tiên | Ghi chú |
|---|---|---|---|---|---|
| 2.8 | **Prometheus** | Metrics collection & storage | Helm (`kube-prometheus-stack`) | 🟠 SHOULD | Scrape metrics từ tất cả components |
| 2.9 | **Grafana** | Metrics visualization & dashboards | Helm (bundled với kube-prometheus-stack) | 🟠 SHOULD | Pre-built dashboards cho K8s, Traefik, Istio |
| 2.10 | **Alertmanager** | Alert routing (Slack, email, webhook) | Helm (bundled) | 🟡 NICE | Route alerts khi Pod crash, high CPU, etc. |
| 2.11 | **Loki** | Log aggregation (thay thế ELK cho bare metal) | Helm (`loki-stack`) | 🟠 SHOULD | LogQL query, tích hợp Grafana |
| 2.12 | **Promtail** | Log collector (ship logs → Loki) | Helm (bundled với loki-stack) | 🟠 SHOULD | DaemonSet thu thập logs mỗi node |

> **Tại sao `kube-prometheus-stack` thay vì cài riêng?**
> Chart `kube-prometheus-stack` (Prometheus Community) bundle Prometheus + Grafana + Alertmanager + node-exporter + kube-state-metrics + nhiều dashboards mặc định. Cài 1 lần = có đủ monitoring cho toàn bộ cluster.

> **Tại sao Loki+Promtail thay vì ELK Stack (Elasticsearch + Logstash + Kibana)?**
>
> | Tiêu chí | Loki + Promtail | ELK Stack |
> |---|---|---|
> | **RAM** | ~200-512MB | ~4-6GB (ES JVM heap: 2-4GB) |
> | **Tích hợp Grafana** | Native — cùng dashboard với Prometheus | Cần Kibana riêng |
> | **Query** | LogQL (giống PromQL) | KQL / Lucene |
> | **Index** | Label-based (nhẹ, nhanh) | Full-text index (mạnh nhưng nặng) |
> | **Vận hành** | Đơn giản | Phức tạp (shard tuning, JVM, index lifecycle) |
> | **Bare metal khả thi?** | ✅ Rất tốt | ❌ Không — ăn hết RAM cluster |
>
> **Kết luận:** Loki+Promtail là lựa chọn duy nhất hợp lý cho bare metal cluster 8-12GB RAM.
> Grafana đã có sẵn (kube-prometheus-stack) → **single pane of glass** cho cả metrics + logs.

#### Layer 2 (mới): Secret Management

| # | Component | Vai trò | Cài đặt | Ưu tiên | Ghi chú |
|---|---|---|---|---|---|
| 2.13 | **Sealed Secrets** (Bitnami) | Encrypt Secrets trong Git (GitOps-safe) | Helm | 🟠 SHOULD | Giải quyết bài toán "Secret trong Git"; `kubeseal` CLI encrypt → chỉ cluster decrypt được |

> **Tại sao Sealed Secrets thay vì HashiCorp Vault?**
> Vault quá nặng và phức tạp cho scovaultpe đồ án. Sealed Secrets đủ dùng: encrypt Secret → commit vào Git → Argo CD sync → cluster auto-decrypt. Phù hợp GitOps workflow.

#### Layer 5: Ingress — Expose services ra internet

| # | Component | Vai trò | Cài đặt | Ưu tiên | Ghi chú |
|---|---|---|---|---|---|
| 5.1 | **Traefik** | Ingress Controller / Reverse Proxy | Helm | 🔴 MUST | Routing, TLS termination, middleware, dashboard |
| 5.2 | **cloudflared** | Cloudflare Tunnel — expose to internet | K8s Deployment + Secret | 🔴 MUST | Không cần mở port, không cần public IP; tunnel từ cluster → Cloudflare edge |

> **Luồng traffic:**
> ```
> User → Cloudflare CDN (*.yourdomain.com)
>       → Cloudflare Tunnel (encrypted)
>       → cloudflared Pod (trong K8s)
>       → Traefik Ingress
>       → K8s Service
>       → App Pod
> ```
>
> **Tại sao Traefik thay vì Nginx Ingress?**
> - Traefik có **native Kubernetes Ingress support** + CRD riêng (`IngressRoute`) linh hoạt hơn
> - Dashboard monitoring built-in
> - Middleware hệ thống (rate-limiting, basic auth, redirect, strip-prefix, circuit-breaker) khai báo bằng CRD
> - Auto-discovery services
> - Nhẹ hơn Nginx trong cluster nhỏ
>
> **Tại sao Cloudflare Tunnel thay vì port-forward / NodePort?**
> - Bare metal nodes sau Tailscale VPN = **KHÔNG có public IP**
> - Cloudflare Tunnel tạo outbound connection từ cluster → Cloudflare edge → serve traffic
> - Miễn phí, bao gồm DDoS protection, CDN cache, DNS management
> - Không cần mở bất kỳ port nào trên firewall → **Zero Trust network**

#### Layer 4: Service Mesh (optional nhưng tăng giá trị đồ án lớn)

| # | Component | Vai trò | Cài đặt | Ưu tiên | Ghi chú |
|---|---|---|---|---|---|
| 4.1 | **Istio** | Service mesh — mTLS, traffic management, observability | `istioctl` hoặc Helm | 🟡 NICE | Nặng (~2GB RAM); cân nhắc **Istio Ambient Mode** (không sidecar, nhẹ hơn) |

> **Cân nhắc về Istio:**
> - **Pro:** mTLS giữa services (Zero Trust network), traffic splitting (canary), detailed telemetry, retry/timeout policies
> - **Con:** Rất nặng (istiod + envoy sidecars), phức tạp debug, tốn RAM trên bare metal
> - **Khuyến nghị:** Chỉ triển khai Istio **SAU KHI** mọi thứ khác đã chạy ổn. Nếu cluster có ít RAM → bỏ qua, dùng Kyverno NetworkPolicy thay thế.
> - **Alternative nhẹ hơn:** Linkerd (CNCF graduated, ~50MB RAM mỗi proxy, đơn giản hơn rất nhiều). Nếu thời gian hạn chế → Linkerd > Istio.
>
> **Khi nào CẦN service mesh?**
> - Khi có ≥3 microservices giao tiếp với nhau
> - Khi cần mTLS giữa services (zero trust internal network)
> - Với 2 demo services + Kafka → service mesh **có giá trị** nhưng vẫn optional
> - Ưu tiên: Linkerd (nhẹ, đơn giản) > Istio (nặng, phức tạp) cho scope đồ án

#### Layer 1: Data & Messaging Services

| # | Component | Vai trò | Cài đặt | Ưu tiên | Ghi chú |
|---|---|---|---|---|---|
| 1.0 | **Kafka (Strimzi Operator)** | Event streaming / inter-service messaging | Helm (`strimzi-kafka-operator`) + Kafka CRD | 🟠 SHOULD | **CRD-based** (Kafka, KafkaTopic, KafkaUser). KRaft mode (no ZooKeeper). ~1-1.5GB RAM |
| 1.1 | **MongoDB** | NoSQL database | Helm (`bitnami/mongodb`) | ⚪ DEFER | Khi có service cần DB |
| 1.2 | **MinIO** | S3-compatible object storage | Helm (`minio/minio`) | ⚪ DEFER | Khi cần lưu file/artifact, hoặc Harbor backend |
| 1.3 | **Redis** | In-memory cache / session store | Helm (`bitnami/redis`) | ⚪ DEFER | Khi cần caching layer |
| 1.4 | **PostgreSQL** | Relational database | Helm (`bitnami/postgresql`) | ⚪ DEFER | Harbor đã có internal Postgres; thêm nếu service cần |

> **Tại sao Kafka được nâng từ DEFER lên SHOULD?**
>
> - Demo app với **2 microservices** (producer → Kafka → consumer) chứng minh pipeline SLSA
>   hoạt động với **nhiều images**, không chỉ 1 app đơn lẻ
> - **Strimzi = K8s-native:** Kafka cluster quản lý bằng CRD, phù hợp với narrative
>   "toàn bộ stack dùng CRD" (Tekton, Kyverno, Argo CD, Traefik, Strimzi)
> - **KRaft mode** (Kafka without ZooKeeper) = giảm complexity + giảm RAM
> - Giá trị học thuật: event-driven architecture + supply chain security = thesis mạnh hơn
>
> **Tại sao không NATS hoặc RabbitMQ?**
> - NATS nhẹ hơn (~30MB RAM) nhưng Kafka là industry standard, nhiều enterprise dùng
> - Strimzi Operator (CNCF incubating) có ecosystem mạnh, documentation tốt
> - Kafka hỗ trợ replay, partitioning, consumer groups — giá trị học thuật cao hơn
>
> **Chiến lược Data Services (non-Kafka):** Không cài trước. Khi có service cụ thể cần DB/cache → `helm install` ngay lúc đó.
> Platform chỉ cần đảm bảo `local-path-provisioner` chạy sẵn để cấp PVC tự động.

### 2. DEMO APP — Ứng dụng chứng minh toàn bộ pipeline

> **Mục tiêu:** 2 microservices giao tiếp qua Kafka, ĐỦ để demo toàn bộ luồng:
> Source → Build (Tekton) → Sign (Cosign) → Attest (Chains) → Push (Harbor) → Policy check (Kyverno) → Deploy (Argo CD) → Expose (Traefik + Cloudflare)
>
> **Tại sao 2 services thay vì 1?**
> - Chứng minh pipeline SLSA hoạt động với **nhiều images** (mỗi service = 1 image riêng)
> - Chứng minh **event-driven microservices** thực sự (producer → Kafka → consumer)
> - Kyverno verify **cả 2 images** trước khi deploy → SLSA enforcement ở scale

#### Kiến trúc demo: Producer + Consumer qua Kafka

```
                    ┌──────────────────────────────────────────────┐
                    │            Tekton Pipeline                    │
                    │  (build + sign + attest MỖI service riêng)   │
                    └──────────┬───────────────┬───────────────────┘
                               │               │
                    ┌──────────▼──┐    ┌───────▼──────┐
                    │ demo-api    │    │ demo-worker  │
                    │ (producer)  │    │ (consumer)   │
                    │             │    │              │
                    │ Go/Node.js  │    │ Go/Node.js   │
                    │ HTTP API    │    │ Kafka consumer│
                    └──────┬──────┘    └───────▲──────┘
                           │                   │
                           │    ┌──────────┐   │
                           └───►│  Kafka   │───┘
                                │ (Strimzi)│
                                │ KRaft    │
                                └──────────┘
```

#### Cấu trúc repo

```
demo-api/                          # Service 1: HTTP API (producer)
├── Dockerfile
├── main.go (hoặc index.js)
├── go.mod / package.json
├── k8s/
│   ├── deployment.yaml
│   ├── ingress.yaml               # Traefik IngressRoute → expose ra internet
│   └── kustomization.yaml
└── tekton/
    ├── pipeline.yaml
    └── pipelinerun.yaml

demo-worker/                       # Service 2: Kafka consumer (worker)
├── Dockerfile
├── main.go (hoặc index.js)
├── go.mod / package.json
├── k8s/
│   ├── deployment.yaml
│   └── kustomization.yaml         # Không cần ingress — internal only
└── tekton/
    ├── pipeline.yaml
    └── pipelinerun.yaml

infra/kafka/                       # Strimzi CRDs
├── kafka-cluster.yaml             # Kafka CRD (KRaft, 1 broker)
├── kafka-topic.yaml               # KafkaTopic CRD
└── kustomization.yaml
```

**Chức năng demo-api (producer):**
| Endpoint | Mô tả | Chứng minh gì |
|----------|--------|----------------|
| `GET /` | Hello page + build info (commit SHA, build time) | App chạy được trên K8s |
| `GET /healthz` | Health check | K8s liveness/readiness probe |
| `GET /info` | Image digest, Cosign signature status, SLSA provenance link | Supply chain metadata visible tại runtime |
| `POST /event` | Publish message vào Kafka topic | Event-driven microservices, Kafka integration |
| `GET /events` | List recent events (từ consumer qua shared API hoặc DB) | End-to-end flow hoạt động |

**Chức năng demo-worker (consumer):**
- Subscribe Kafka topic → process message → log result
- Health check endpoint cho K8s probe
- Không cần expose ra internet (internal-only service)

**Tại sao Go?**
- Image cực nhỏ (~10MB scratch-based) → build nhanh, pull nhanh
- Không cần runtime (compiled binary) → giảm attack surface
- Health check built-in dễ viết
- Nếu không quen Go → Node.js (Alpine image ~50MB) cũng ok

### 3. THỨ TỰ CÀI ĐẶT — Installation Order (Critical Path)

> Một số component phụ thuộc component khác. Thứ tự sai = lỗi cascade.

```
PHASE 0: Infrastructure (đã có)
  ✅ K8s cluster (kubeadm + Flannel + Tailscale) — via Ansible
  ✅ Helm CLI trên local

PHASE 1: Storage + Networking Foundation
  ┌─────────────────────────────────────────────┐
  │ 1. local-path-provisioner                    │  Mọi PVC phụ thuộc vào đây
  │ 2. cert-manager + ClusterIssuer              │  Harbor, Traefik cần TLS certs
  └─────────────────────────────────────────────┘

PHASE 2: Core Platform
  ┌─────────────────────────────────────────────┐
  │ 3. Traefik (Ingress, hostNetwork/ClusterIP)  │  Route traffic tới services
  │ 4. cloudflared (Cloudflare Tunnel)           │  Expose cluster ra internet
  │ 5. Sealed Secrets                            │  Encrypt secrets cho GitOps
  │ 6. Harbor                                    │  Registry (cần PVC + TLS)
  └─────────────────────────────────────────────┘

PHASE 3: CI/CD + Security (SLSA stack)
  ┌─────────────────────────────────────────────┐
  │ 7. Tekton Pipelines                          │  CI/CD engine
  │ 8. Tekton Chains + Cosign                    │  Signing + provenance
  │ 9. Kyverno                                   │  Admission policy
  │ 10. Argo CD                                  │  GitOps CD
  └─────────────────────────────────────────────┘

PHASE 4: Messaging + Observability
  ┌─────────────────────────────────────────────┐
  │ 11. Strimzi Operator + Kafka (KRaft)         │  Inter-service messaging
  │ 12. kube-prometheus-stack                    │  Prometheus + Grafana + Alertmanager
  │ 13. Loki + Promtail                          │  Log aggregation
  └─────────────────────────────────────────────┘

PHASE 5: Service Mesh (nếu có thời gian + RAM)
  ┌─────────────────────────────────────────────┐
  │ 14. Istio / Linkerd                          │  mTLS, traffic management
  └─────────────────────────────────────────────┘

PHASE 6: Demo & Validation
  ┌─────────────────────────────────────────────┐
  │ 15. Deploy demo-api + demo-worker (2 images) │  E2E proof — 2 services + Kafka
  │ 16. Attack scenarios                         │  SLSA verification
  │ 17. Access qua https://demo.yourdomain.com   │  Internet exposure proof
  └─────────────────────────────────────────────┘
```

### 4. NAMESPACE ORGANIZATION — Quản lý tách biệt

```yaml
# Infrastructure
kube-system:           # K8s core (CoreDNS, kube-proxy, Flannel)
cert-manager:          # cert-manager

# Ingress
traefik:               # Traefik Ingress Controller
cloudflare:            # cloudflared Tunnel

# CI/CD & Security
tekton-pipelines:      # Tekton Pipelines + Chains
argocd:                # Argo CD
kyverno:               # Kyverno Policy Engine
harbor:                # Harbor Registry
sealed-secrets:        # Sealed Secrets controller

# Messaging
kafka:                 # Strimzi Operator + Kafka cluster (KRaft)

# Observability
monitoring:            # Prometheus + Grafana + Alertmanager
logging:               # Loki + Promtail

# Service Mesh (nếu dùng)
istio-system:          # Istio control plane

# Application workloads
demo:                  # Demo app
# staging:             # Future: staging environment
# production:          # Future: production environment
```

### 5. RESOURCE ESTIMATION — Ước tính tài nguyên

> Quan trọng cho bare metal — cần biết cluster có đủ RAM/CPU không.

| Component | CPU Request | Memory Request | PVC | Ghi chú |
|---|---|---|---|---|
| K8s system (kubelet, kube-proxy, CoreDNS, etcd) | 1 core | ~1.5 GB | - | Trên master node |
| Flannel | 100m | 128 MB | - | DaemonSet |
| local-path-provisioner | 50m | 64 MB | - | Nhẹ |
| cert-manager | 100m | 128 MB | - | 3 pods (controller, webhook, cainjector) |
| **Traefik** | 200m | 256 MB | - | Ingress Controller (hostNetwork) |
| **cloudflared** | 100m | 128 MB | - | 1 pod, rất nhẹ |
| **Harbor** | 500m | **1.5 GB** | **10 GB** | Nặng nhất (redis, postgres, core, registry, trivy) |
| **Tekton Pipelines** | 200m | 256 MB | - | Controller + webhook |
| **Tekton Chains** | 100m | 128 MB | - | Controller |
| **Kyverno** | 200m | 256 MB | - | admission controller + reports controller |
| **Argo CD** | 300m | 512 MB | - | server + repo-server + app-controller |
| **Sealed Secrets** | 50m | 64 MB | - | Rất nhẹ |
| **Kafka (Strimzi)** | 500m | **1-1.5 GB** | **5 GB** | Strimzi operator + KRaft broker (single-node) |
| **Prometheus + Grafana** | 500m | **1 GB** | **5 GB** | kube-prometheus-stack |
| **Loki + Promtail** | 200m | 512 MB | **5 GB** | Log storage |
| **Istio** | 500m | **1-2 GB** | - | istiod + envoy sidecars |
| **Demo apps (2 services)** | 100m | 128 MB | - | demo-api + demo-worker |
| **TỔNG (không Istio)** | **~3.5 cores** | **~8 GB** | **~25 GB** | |
| **TỔNG (có Istio)** | **~4 cores** | **~10 GB** | **~25 GB** | |

> **Kết luận:** Cần tối thiểu **10 GB RAM** cho worker node(s) nếu không chạy Istio,
> **12-14 GB RAM** nếu có Istio. Nếu chỉ có 1 worker node → có thể cần giảm replicas hoặc bỏ một số component optional.

### 6. BẢNG TỔNG HỢP CÔNG NGHỆ CẬP NHẬT (thay thế bảng I.D)

> Bổ sung các component mới vào bảng gốc, đánh số lại.

| # | Công nghệ | Vai trò / Module | Ưu tiên | Layer |
|---|---|---|---|---|
| 1 | **Kubernetes (kubeadm)** | Container orchestration | 🔴 CRITICAL | L0 |
| 2 | **Flannel** | Pod networking CNI | 🔴 CRITICAL | L0 |
| 3 | **Tailscale** | VPN inter-node | 🔴 CRITICAL | L0 |
| 4 | **Helm** | Package manager | 🔴 CRITICAL | L0 |
| 5 | **local-path-provisioner** | Dynamic PV provisioning | 🔴 CRITICAL | L0 |
| 6 | **cert-manager** | TLS certificate automation | 🟠 HIGH | L0 |
| 7 | ~~MetalLB~~ | ~~Bare metal LoadBalancer~~ — **KHÔNG CẦN** | 🟢 LOW | L0 |
| 8 | **Traefik** | Ingress Controller + reverse proxy | 🔴 CRITICAL | L5 |
| 9 | **cloudflared** | Cloudflare Tunnel (internet exposure) | 🔴 CRITICAL | L5 |
| 10 | **Tekton Pipelines** | CI/CD engine (K8s-native) | 🔴 CRITICAL | L2 |
| 11 | **Tekton Chains** | SLSA provenance generation | 🔴 CRITICAL | L2 |
| 12 | **Cosign** | Image signing (keyless Sigstore) | 🔴 CRITICAL | L2 |
| 13 | **Kyverno** | Admission policy (verify images) | 🔴 CRITICAL | L2 |
| 14 | **Harbor** | OCI registry (self-hosted) | 🔴 CRITICAL | L2 |
| 15 | **Kaniko** | Rootless container build | 🔴 CRITICAL | L2 |
| 16 | **Argo CD** | GitOps CD (pull-based) | 🟠 HIGH | L2 |
| 17 | **Sealed Secrets** | Encrypt secrets cho GitOps | 🟠 HIGH | L2 |
| 18 | **Prometheus** | Metrics collection | 🟠 HIGH | L2 |
| 19 | **Grafana** | Metrics visualization | 🟠 HIGH | L2 |
| 20 | **Alertmanager** | Alert routing | 🟡 MEDIUM | L2 |
| 21 | **Loki + Promtail** | Log aggregation (thay ELK) | 🟠 HIGH | L2 |
| 22 | **Kafka (Strimzi)** | Event streaming, inter-service messaging | 🟠 HIGH | L1 |
| 23 | **Syft + Grype** | SBOM + vulnerability scan | 🟡 MEDIUM | L2 |
| 23 | **Istio** (hoặc Linkerd) | Service mesh (mTLS, traffic mgmt) | 🟡 MEDIUM | L4 |
| 24 | **Sigstore (Fulcio + Rekor)** | PKI + transparency log | 🟡 MEDIUM | external |
| 25 | **SLSA Framework** | Tiêu chuẩn compliance | 🟡 MEDIUM | framework |
| 26 | **GitHub Actions** | CI/CD SaaS (so sánh với Tekton) | 🟢 LOW | external |
| — | *MongoDB, MinIO, Redis, PostgreSQL* | *Data services — deploy khi có service cần* | ⚪ DEFER | L1 |

**Chú thích:**
- 🔴 **CRITICAL** — Không có = platform không hoạt động. 12 components.
- 🟠 **HIGH** — Production-like, tăng chiều sâu rõ rệt. 8 components.
- 🟡 **MEDIUM** — Bonus / so sánh. 4 components.
- 🟢 **LOW** — Chỉ mention hoặc không cần. 2 components.
- ⚪ **DEFER** — Cài khi cần, platform chỉ cần ready nhận chúng.

### 7. LEARNING PATH CẬP NHẬT — Thứ tự học

```
Bước 1:  K8s fundamentals        → Pods, Services, Ingress, RBAC, Admission Controllers
Bước 2:  Helm                    → install/upgrade/values, chart repos
Bước 3:  Storage + cert-manager   → local-path-provisioner, ClusterIssuer, TLS
Bước 4:  Traefik                 → IngressRoute CRD, middleware, hostNetwork
Bước 5:  Cloudflare Tunnel       → cloudflared deployment, DNS routing
Bước 6:  Harbor                  → Helm install, TLS, push/pull, Trivy
Bước 7:  Tekton                  → Pipeline, Task, Workspace, PipelineRun
Bước 8:  Tekton Chains + Cosign  → signing, provenance generation
Bước 9:  Kyverno                 → ClusterPolicy, verifyImages, deny unsigned
Bước 10: Argo CD                 → Application CRD, sync, RBAC, Sealed Secrets
Bước 11: Kafka (Strimzi)         → Strimzi Operator, Kafka CRD, KRaft, KafkaTopic
Bước 12: Prometheus + Grafana    → kube-prometheus-stack, dashboards
Bước 13: Loki + Promtail         → log aggregation, LogQL, Grafana datasource
Bước 14: Demo apps E2E           → demo-api + demo-worker + Kafka, full pipeline proof
Bước 15: Istio (nếu có thời gian) → mTLS, traffic management
Bước 16: GitHub Actions          → slsa-github-generator (so sánh)
```

### 8. TRAEFIK + CLOUDFLARE INTEGRATION DETAIL

> Đây là phần mới hoàn toàn so với plan gốc — cách expose services ra internet từ bare metal cluster.

#### Kiến trúc chi tiết

```
Internet User
     │
     ▼
┌─────────────┐
│ Cloudflare  │  DNS: *.thesis.example.com → Cloudflare proxy
│ Edge (CDN)  │  DDoS protection, WAF, caching
└──────┬──────┘
       │ Encrypted tunnel (QUIC/HTTP2)
       ▼
┌─────────────┐
│ cloudflared │  Pod trong K8s namespace `cloudflare`
│ (tunnel)    │  Outbound connection → Cloudflare edge
└──────┬──────┘
       │ Route to Traefik Service (ClusterIP)
       ▼
┌─────────────┐
│  Traefik    │  Ingress Controller
│  (proxy)    │  Routing rules:
│             │    demo.thesis.example.com → demo-app Service
│             │    harbor.thesis.example.com → Harbor Service
│             │    grafana.thesis.example.com → Grafana Service
│             │    argocd.thesis.example.com → Argo CD Service
└──────┬──────┘
       │ K8s Service routing
       ▼
┌─────────────┐
│  App Pods   │
└─────────────┘
```

#### Cloudflare Tunnel config
```yaml
# cloudflared ConfigMap sẽ map:
tunnel: <tunnel-id>
credentials-file: /etc/cloudflared/credentials.json
ingress:
  - hostname: demo.thesis.example.com
    service: http://traefik.traefik.svc.cluster.local:80
  - hostname: harbor.thesis.example.com
    service: http://traefik.traefik.svc.cluster.local:80
  - hostname: grafana.thesis.example.com
    service: http://traefik.traefik.svc.cluster.local:80
  - hostname: argocd.thesis.example.com
    service: http://traefik.traefik.svc.cluster.local:80
  - service: http_status:404  # catch-all
```

#### Traefik IngressRoute CRD (ví dụ cho demo app)
```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: demo-app
  namespace: demo
spec:
  entryPoints:
    - web
  routes:
    - match: Host(`demo.thesis.example.com`)
      kind: Rule
      services:
        - name: demo-app
          port: 8080
      middlewares:
        - name: rate-limit
```

> **Lợi ích mô hình này cho Zero Trust:**
> 1. **Không mở port nào trên bare metal nodes** — cloudflared tự tạo outbound tunnel
> 2. **TLS end-to-end** — Cloudflare edge → tunnel (encrypted) → Traefik → Pod
> 3. **Centralized routing** — Traefik là single entry point, dễ audit
> 4. **Tách biệt exposure** — chỉ services có IngressRoute mới accessible từ internet

### 9. PROMETHEUS + GRAFANA — Monitoring cho platform

#### Dashboards cần thiết

| Dashboard | Source | Giám sát gì |
|---|---|---|
| K8s Cluster Overview | kube-prometheus-stack (built-in) | Node CPU/RAM, Pod count, API server health |
| K8s Namespace Resources | kube-prometheus-stack (built-in) | Resources per namespace |
| Traefik Dashboard | Traefik Helm chart (built-in) | Request rate, latency, errors per route |
| Harbor Metrics | Harbor exporter | Registry storage, pull/push rate |
| Tekton Metrics | Tekton config | Pipeline duration, success/failure rate |
| Argo CD Metrics | Argo CD built-in | Sync status, app health |
| Istio Mesh | Istio Grafana addon | Service-to-service traffic, mTLS status |

#### Alert rules quan trọng
```yaml
# Ví dụ PrometheusRule
groups:
  - name: platform-alerts
    rules:
      - alert: PodCrashLooping
        expr: rate(kube_pod_container_status_restarts_total[15m]) > 0
        for: 5m
      - alert: HighMemoryUsage
        expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes > 0.9
        for: 10m
      - alert: KyvernoPolicyViolation
        expr: increase(kyverno_policy_results_total{rule_result="fail"}[1h]) > 0
```

---

## II. NỘI DUNG THỰC HIỆN THEO TỪNG MẢN

### Mảng 1: Nghiên cứu lý thuyết (Chương 1 + 2 trong báo cáo)

1. **Software Supply Chain Security**
   - Định nghĩa chuỗi cung ứng phần mềm
   - Các cuộc tấn công tiêu biểu: SolarWinds (2020), Codecov (2021), Log4Shell (2021), xz-utils (2024)
   - Các vector tấn công: Source tampering, build compromise, dependency confusion, registry poisoning

2. **Zero Trust Architecture**
   - Mô hình "Never trust, always verify"
   - Áp dụng Zero Trust vào SDLC: không tin commit, không tin build runner, không tin image
   - NIST SP 800-207 Zero Trust Architecture

3. **SLSA Framework (v1.0 → v1.2)**
   - Mô hình trưởng thành (maturity model) với Build Track + Source Track
   - SLSA L3 requirements: isolated build, unforgeable provenance, ephemeral environment
   - Threat model theo SLSA: source threats, build threats, packaging threats
   - In-toto attestation format, provenance schema

4. **Kubernetes & Container Security**
   - K8s architecture (control plane, worker nodes, API server)
   - Admission Controllers: Validating & Mutating webhooks
   - OCI image format, image digest vs. tag
   - Pod Security Standards

5. **Hệ sinh thái công cụ**
   - Sigstore ecosystem: Cosign, Fulcio, Rekor
   - SBOM standards: SPDX, CycloneDX
   - Policy engines: Kyverno, OPA Gatekeeper

### Mảng 2: Phân tích & Thiết kế hệ thống (Chương 3)

1. **Kiến trúc tổng thể** (tool-agnostic)
   ```
   Developer → Source Control → CI/CD Build → Sign & Attest → Registry → Policy Gate → K8s Runtime
   ```

2. **Thiết kế giai đoạn Source**
   - Branch protection rules
   - Commit signing (GPG/SSH)
   - SAST scanning, secret scanning
   - Code review enforcement

3. **Thiết kế giai đoạn Build (SLSA L3)**
   - Ephemeral & isolated build environment
   - Provenance generation (in-toto format)
   - SBOM generation
   - Digital signing (keyless via OIDC)

4. **Thiết kế giai đoạn Deploy (Zero Trust on K8s)**
   - Admission Controller architecture
   - Policy rules: verify signature, verify provenance, check SBOM
   - Deny-by-default policy model

5. **Thiết kế kịch bản tấn công mô phỏng**
   - Kịch bản 1: Deploy unsigned image → bị chặn
   - Kịch bản 2: Modify image after build (tag mismatch) → bị chặn
   - Kịch bản 3: Deploy image without provenance → bị chặn
   - Kịch bản 4: Deploy image from untrusted builder → bị chặn
   - Kịch bản 5: Happy path - signed image with valid provenance → cho phép

### Mảng 3: Triển khai & Demo (Chương 4)

1. **Setup K8s cluster** (đã có script trong code/infra/k8s/setup/)
2. **Implement CI/CD pipeline**
3. **Cấu hình signing & attestation**
4. **Deploy policy engine trên K8s**
5. **Demo attack scenarios**
6. **Đo lường performance overhead** (thời gian verify khi deploy)

### Mảng 4: Viết báo cáo (xuyên suốt)

- Viết song song với quá trình triển khai
- LaTeX format theo template trường

---

## III. KẾ HOẠCH 12 TUẦN CHI TIẾT (CẬP NHẬT — Self-hosted CNCF First)

### GIAI ĐOẠN 1: NỀN TẢNG + CORE PIPELINE (Tuần 1–4)

#### Tuần 1 (01/03 – 07/03): Nghiên cứu lý thuyết + K8s deep-dive
- [ ] Đọc SLSA spec v1.0 (slsa.dev) — Build Track + Source Track
- [ ] Đọc NIST SP 800-207 (Zero Trust)
- [ ] Nghiên cứu K8s Admission Controllers, CRD pattern, RBAC model
- [ ] Tổng hợp case study tấn công supply chain (SolarWinds, Codecov, xz-utils)
- **Output:** Bản nháp Chương 1 + phần 2.1-2.4 (lý thuyết)

#### Tuần 2 (08/03 – 14/03): Setup K8s + Tekton + Cài tool
- [ ] Setup K8s cluster (kubeadm trên WSL2 — đã có script)
- [ ] Cài Tekton Pipelines trên K8s (kubectl apply hoặc Helm)
- [ ] Cài Tekton Chains trên K8s, config signing backend (Cosign)
- [ ] Test cài đặt cosign, syft, grype trên local
- [ ] Nghiên cứu Tekton CRDs: Task, Pipeline, PipelineRun, Workspace
- **Output:** K8s cluster + Tekton chạy được

#### Tuần 3 (15/03 – 21/03): Tekton pipeline + Kaniko build + Sign
- [ ] Viết sample app đơn giản (Go hoặc Python web app)
- [ ] Viết Tekton Task: clone repo → build image bằng Kaniko → push to registry
- [ ] Config Tekton Chains: auto-sign TaskRun results, tạo in-toto provenance
- [ ] Test cosign verify trên image đã build → provenance check
- **Output:** Pipeline Tekton e2e chạy được, image signed + provenance attached

#### Tuần 4 (22/03 – 28/03): Kyverno Policy Engine + End-to-End verify
- [ ] Cài Kyverno trên K8s (Helm)
- [ ] Viết ClusterPolicy: verify-image-signature (cosign)
- [ ] Viết ClusterPolicy: verify-slsa-provenance (attestation)
- [ ] Test happy path: deploy signed image → pass
- [ ] Test negative: deploy unsigned image → denied
- [ ] Config RBAC least-privilege cho Tekton SA, Kyverno SA
- **Output:** 🎯 **Core pipeline hoàn chỉnh!** Tekton → Kaniko → Cosign → Kyverno

### GIAI ĐOẠN 2: MỞ RỘNG + SO SÁNH (Tuần 5–8)

#### Tuần 5 (29/03 – 04/04): Harbor + Argo CD
- [ ] Deploy Harbor trên K8s (Helm chart) — config TLS, PV storage
- [ ] Migrate pipeline push target từ temp registry sang Harbor
- [ ] Cài Argo CD trên K8s, config Application CRD
- [ ] Setup GitOps flow: Git commit → Argo CD sync → deploy (chỉ signed images)
- **Output:** Full self-hosted stack: Tekton → Harbor → Argo CD → Kyverno

#### Tuần 6 (05/04 – 11/04): Attack Scenarios + SBOM
- [ ] Thiết kế và test 5 kịch bản tấn công mô phỏng
- [ ] Thêm SBOM generation vào Tekton pipeline (Syft)
- [ ] Attach SBOM vào Harbor (cosign attach)
- [ ] Viết Kyverno policy verify SBOM
- [ ] Quét vulnerability từ SBOM (Grype)
- [ ] Ghi screenshots, logs cho từng kịch bản
- **Output:** Tất cả attack scenarios tested + SBOM workflow

#### Tuần 7 (12/04 – 18/04): GitHub Actions pipeline (để so sánh)
- [ ] Setup GitHub Actions workflow: build → sign → push to GHCR
- [ ] Tích hợp slsa-github-generator (SLSA L3 provenance trên GH)
- [ ] Viết Kyverno policy verify cả 2 sources (Tekton provenance + GH provenance)
- [ ] Bắt đầu viết Chương 3 (thiết kế), tập trung phần so sánh 2 approaches
- **Output:** Pipeline so sánh chạy được + bản nháp Ch3

#### Tuần 8 (19/04 – 25/04): Performance benchmarking
- [ ] Đo thời gian admission verify (có vs không có Kyverno)
- [ ] Đo thời gian pipeline Tekton (build + sign + push + provenance)
- [ ] Đo thời gian pipeline GitHub Actions (tương tự)
- [ ] Đo tài nguyên K8s (CPU/RAM) khi chạy full stack
- [ ] So sánh overhead: self-hosted vs SaaS
- **Output:** Bảng số liệu benchmark Tekton vs GH Actions

### GIAI ĐOẠN 3: ĐÁNH GIÁ + VIẾT BÁO CÁO (Tuần 9–12)

#### Tuần 9 (26/04 – 02/05): Đánh giá & đối chiếu SLSA
- [ ] Lập bảng đối chiếu: hệ thống đạt/không đạt từng requirement của SLSA L3
- [ ] Phân tích ưu/nhược điểm giải pháp
- [ ] Phân tích so sánh với các nghiên cứu liên quan (related work)
- **Output:** Bản nháp Chương 4 (Triển khai & Đánh giá)

#### Tuần 10 (03/05 – 09/05): Viết báo cáo chính
- [ ] Hoàn thiện Chương 1: Tổng quan
- [ ] Hoàn thiện Chương 2: Cơ sở lý thuyết
- [ ] Hoàn thiện Chương 3: Phân tích & Thiết kế
- [ ] Hoàn thiện Chương 4: Triển khai & Đánh giá
- **Output:** Draft đầy đủ 4 chương

#### Tuần 11 (10/05 – 16/05): Viết báo cáo + Demo
- [ ] Viết Chương 5: Kết luận & Hướng phát triển
- [ ] Viết Tóm tắt (Abstract) tiếng Việt + Anh
- [ ] Chuẩn bị demo video/live
- [ ] Review lại toàn bộ tài liệu tham khảo
- **Output:** Báo cáo hoàn chỉnh draft 1

#### Tuần 12 (17/05 – 01/06): Chỉnh sửa + Nộp
- [ ] Review format, chính tả, tài liệu tham khảo
- [ ] In ấn, đóng bìa
- [ ] Chuẩn bị slide thuyết trình
- [ ] Tập thuyết trình + demo
- **Output:** Nộp đồ án + sẵn sàng bảo vệ

---

## IV. DELIVERABLES (SẢN PHẨM BÀN GIAO)

| # | Sản phẩm | Mô tả |
|---|---|---|
| 1 | **Báo cáo đồ án** | LaTeX, 5 chương, ~60-80 trang |
| 2 | **Source code** | Sample app + CI/CD pipeline configs + K8s manifests + Kyverno policies |
| 3 | **K8s cluster config** | Scripts setup cluster + deploy |
| 4 | **Demo** | Video/live demo 5 kịch bản tấn công |
| 5 | **Slide thuyết trình** | 15-20 slides |

---

## V. RỦI RO VÀ PHƯƠNG ÁN XỬ LÝ (CẬP NHẬT)

| Rủi ro | Xác suất | Phương án xử lý |
|---|---|---|
| Tekton quá phức tạp, không setup được trong tuần 2-3 | Trung bình | Dùng GitHub Actions (Fallback B) → vẫn đạt SLSA L3 |
| Harbor cài phức tạp trên local K8s | Trung bình | Dùng GHCR miễn phí → migrate Harbor sau |
| K8s cluster local không ổn định (kubeadm on WSL2) | Trung bình | Chuyển sang kind/k3s — script sẵn |
| Tekton Chains config signing thất bại | Trung bình | Dùng cosign sign thủ công trong pipeline → vẫn đạt L3 |
| Kyverno lỗi verify provenance format | Thấp | Chuyển sang Sigstore Policy Controller |
| Không đủ thời gian cho cả Tekton + GitHub Actions pipeline | Trung bình | Giữ Tekton (primary), bỏ GH Actions comparison |
| Không đủ thời gian viết báo cáo | Trung bình | Viết song song từ tuần 1, không để dồn cuối |
| Sigstore public instance down | Rất thấp | Dùng key-based signing (cosign generate-key-pair) |
| RAM/CPU local không đủ chạy full stack | Thấp | Tắt Harbor, dùng GHCR; hoặc giảm resource limits |

---

## VI. CẤU TRÚC BÁO CÁO ĐỒ ÁN (DỰ KIẾN)

```
Phần mở đầu
├── Trang bìa
├── Lời cam đoan
├── Lời cảm ơn  
├── Tóm tắt (Tiếng Việt + English)
├── Mục lục
├── Danh mục hình ảnh
├── Danh mục bảng biểu
└── Danh mục từ viết tắt

Chương 1: Tổng quan đề tài
├── 1.1 Bối cảnh và lý do chọn đề tài
├── 1.2 Mục tiêu nghiên cứu
├── 1.3 Đối tượng và phạm vi nghiên cứu
└── 1.4 Bố cục đồ án

Chương 2: Cơ sở lý thuyết
├── 2.1 Software Supply Chain & Rủi ro bảo mật
├── 2.2 Mô hình bảo mật Zero Trust
├── 2.3 Khung tiêu chuẩn SLSA
│   ├── 2.3.1 Tổng quan SLSA
│   ├── 2.3.2 Build Track (L1 → L3)
│   ├── 2.3.3 Source Track
│   └── 2.3.4 Threat Model
├── 2.4 Kubernetes & Container Security  
│   ├── 2.4.1 Kiến trúc Kubernetes
│   └── 2.4.2 Admission Controllers
└── 2.5 Hệ sinh thái công cụ liên quan
    ├── 2.5.1 Sigstore (Cosign, Fulcio, Rekor)
    ├── 2.5.2 SBOM (SPDX, CycloneDX)
    └── 2.5.3 Policy Engines

Chương 3: Phân tích và Thiết kế hệ thống
├── 3.1 Kiến trúc tổng thể
├── 3.2 Thiết kế giai đoạn Source (SCM Security)
├── 3.3 Thiết kế giai đoạn Build (SLSA L3)
│   ├── 3.3.1 Ephemeral & Isolated Build Environment
│   ├── 3.3.2 Provenance Generation
│   ├── 3.3.3 SBOM Generation
│   └── 3.3.4 Digital Signing
├── 3.4 Thiết kế giai đoạn Deploy (Zero Trust on K8s)
│   ├── 3.4.1 Admission Controller Architecture
│   └── 3.4.2 Policy Rules Design
└── 3.5 Thiết kế kịch bản kiểm thử & tấn công mô phỏng

Chương 4: Triển khai và Đánh giá
├── 4.1 Môi trường triển khai
├── 4.2 Triển khai Pipeline CI/CD
├── 4.3 Triển khai Policy Engine trên K8s
├── 4.4 Kết quả kiểm thử các kịch bản
│   ├── 4.4.1 Happy Path
│   └── 4.4.2 Attack Scenarios
├── 4.5 Đánh giá hiệu năng (Performance Overhead)
└── 4.6 Đối chiếu với tiêu chuẩn SLSA Level 3

Chương 5: Kết luận và Hướng phát triển
├── 5.1 Kết luận
├── 5.2 Khó khăn gặp phải
└── 5.3 Hướng phát triển tương lai

Tài liệu tham khảo
Phụ lục
├── A. Source code pipeline
├── B. Kyverno Policy YAML
├── C. Provenance JSON mẫu
└── D. Hướng dẫn tái tạo hệ thống
```

---

## VII. GHI CHÚ QUAN TRỌNG

1. **Self-hosted CNCF là ưu tiên số 1** — Tekton, Harbor, Argo CD trước; GitHub Actions chỉ để so sánh
2. **Viết báo cáo SONG SONG với triển khai** — mỗi tuần dành ít nhất 2-3 giờ viết
3. **Commit thường xuyên** — mỗi bước nhỏ đều commit để có history rõ ràng
4. **Screenshot mọi thứ** — kết quả test, logs, terminal output → dùng cho báo cáo
5. **Fallback strategy rõ ràng** — Nếu tool self-hosted fail → dùng SaaS thay → KHÔNG dừng lại
6. **Sample app nên đơn giản** — Focus vào pipeline & security, không phải viết app phức tạp
7. **So sánh 2 approaches = tăng giá trị** — Nếu chạy được cả Tekton + GH Actions → so sánh = ấn tượng hội đồng

---

## VIII. TIẾN ĐỘ THỰC HIỆN — Implementation Progress Log

> *Phần này theo dõi những gì đã hoàn thành và trạng thái hiện tại của toàn bộ đồ án.*

### 1. Tổng quan trạng thái

```
GIAI ĐOẠN                        TRẠNG THÁI      GHI CHÚ
─────────────────────────────────────────────────────────────────────
OS/Node Provisioning (Ansible)   ✅ HOÀN THÀNH    8 roles, 4 playbooks
Bootstrap Bridge Scripts         ✅ HOÀN THÀNH    nodes.env, sync-inventory, register-node
K8s Platform Bootstrap (Helmfile)✅ HOÀN THÀNH    helmfile-bootstrap + helmfile-option-b + values
Argo CD App-of-Apps Manifests    ✅ HOÀN THÀNH    root App + 8 Application CRDs
Deployment Checklists            ✅ HOÀN THÀNH    Option A (Full CNCF) + Option B (SaaS)
IaC Methodology Document         ✅ HOÀN THÀNH    infra-deployment-methodology.md
Architecture Decisions           ✅ HOÀN THÀNH    MetalLB removed, Loki>ELK, Kafka promoted
Thesis Plan (document này)       ✅ HOÀN THÀNH    Sections I–VII + VIII–XII (phần này)
──────────────────────────────────────────────────────────────────
K8s Cluster Provisioning (Live)  🔲 CHƯA BẮT ĐẦU  Chạy Ansible trên bare metal thực tế
Helmfile Bootstrap (Live)        🔲 CHƯA BẮT ĐẦU  helmfile apply trên cluster thực tế
Argo CD Deploy (Live)            🔲 CHƯA BẮT ĐẦU  kubectl apply -f app-of-apps.yaml
Tekton Pipeline Development      🔲 CHƯA BẮT ĐẦU  Viết Pipeline/Task cho demo apps
Demo Apps Development            🔲 CHƯA BẮT ĐẦU  demo-api + demo-worker (Go/Node)
Attack Scenarios Testing         🔲 CHƯA BẮT ĐẦU  5 kịch bản tấn công mô phỏng
Performance Benchmarking         🔲 CHƯA BẮT ĐẦU  Tekton vs GH Actions, Kyverno overhead
Thesis Writing                   🔲 CHƯA BẮT ĐẦU  LaTeX, 5 chương
```

### 2. Chi tiết — Ansible Automation (8 Roles, 4 Playbooks)

**File location:** `code/infra/ansible/`

| Role | Mô tả | Trạng thái |
|---|---|---|
| `common` | Cập nhật OS, cài packages cơ bản, tắt swap, load kernel modules | ✅ |
| `containerd` | Cài containerd 2.2.x từ Docker repo, fix CRI socket, cấu hình SystemdCgroup | ✅ |
| `kubernetes` | Cài kubeadm/kubelet/kubectl v1.32, hold versions, configure kubelet | ✅ |
| `cni_flannel` | Deploy Flannel CNI với `--iface=tailscale0` | ✅ |
| `cni_plugins` | Cài CNI plugins binary | ✅ |
| `master_init` | kubeadm init, copy kubeconfig, advertise qua Tailscale IP | ✅ |
| `worker_join` | kubeadm join qua Tailscale IP | ✅ |
| `tailscale` | Verify Tailscale đang chạy + IP đúng (verify-only, không cài) | ✅ |
| `firewall` | Mở ports cần thiết cho K8s + Tailscale | ✅ |

**Playbooks:**

| Playbook | Target | Mô tả |
|---|---|---|
| `site.yaml` | All | Chạy toàn bộ setup end-to-end |
| `setup-master.yaml` | Master | Cài K8s + init cluster |
| `setup-worker.yaml` | Workers | Cài K8s + join cluster |
| `reset.yaml` | All | `kubeadm reset` + cleanup |

**Inventory:** Sử dụng Tailscale IPs (`100.95.126.102` cho master, `100.94.203.28` cho worker).

### 3. Chi tiết — Bootstrap Bridge Scripts

**File location:** `code/infra/bootstrap/`

| File | Mô tả |
|---|---|
| `nodes.env` | Centralized node registry (IP, role, hostname, status) |
| `bootstrap.env.example` | Template biến môi trường cho cluster config |
| `sync-inventory.sh` | Sync `nodes.env` → Ansible inventory tự động |
| `register-node.sh` | Script đăng ký node mới vào `nodes.env` |

### 4. Chi tiết — Helmfile Bootstrap

**File location:** `code/infra/helmfile/`

| File | Mô tả |
|---|---|
| `helmfile-bootstrap.yaml` | Option A: 4 releases với `needs:` ordering (cert-manager → Traefik → Sealed Secrets → Argo CD) |
| `helmfile-option-b.yaml` | Option B: 3 releases (cert-manager → Traefik → Kyverno) |
| `values/cert-manager.yaml` | CRDs enabled, resource limits cho bare metal |
| `values/traefik.yaml` | ClusterIP mode, JSON logging, cross-namespace, Prometheus metrics |
| `values/sealed-secrets.yaml` | Minimal config với resource limits |
| `values/argocd.yaml` | Insecure mode (TLS tại Traefik), Dex disabled, ApplicationSet enabled |
| `values/kyverno.yaml` | Single replica, all controllers enabled, resource limits |
| `README.md` | Hướng dẫn sử dụng cho cả 2 options |

### 5. Chi tiết — Argo CD App-of-Apps (Option A)

**File location:** `code/infra/argocd/`

| File | Mô tả | Ghi chú |
|---|---|---|
| `app-of-apps.yaml` | Root Application, auto-sync + prune + selfHeal | Trỏ tới thư mục `apps/` |
| `apps/harbor.yaml` | Harbor Registry | Trivy enabled, 10Gi registry + 2Gi DB PVC |
| `apps/kyverno.yaml` | Kyverno Policy Engine | ServerSideApply cho large CRDs |
| `apps/strimzi.yaml` | Strimzi Kafka Operator | CRD install |
| `apps/kafka-cluster.yaml` | Kafka Cluster (KRaft) | Sync wave "1" (chờ Strimzi), retry backoff |
| `apps/monitoring.yaml` | kube-prometheus-stack | 5Gi Prometheus + 1Gi Alertmanager PVC |
| `apps/logging.yaml` | Loki-stack | 5Gi persistence |
| `apps/demo-api.yaml` | Demo API service | Trỏ tới demo-api repo `/k8s` path |
| `apps/demo-worker.yaml` | Demo Worker service | Trỏ tới demo-worker repo `/k8s` path |

### 6. Chi tiết — Deployment Checklists

**File location:** `plan/`

| File | Mô tả | Dung lượng |
|---|---|---|
| `checklist-option-a-full-cncf.md` | Full CNCF self-hosted — 12 phases, 21 components | ~1000 dòng |
| `checklist-option-b-saas-lightweight.md` | SaaS lightweight — 8 phases, ~14 components | ~770 dòng |
| `infra-deployment-methodology.md` | Phân tích tại sao dùng Helmfile + Argo CD thay vì raw `helm install` | ~300 dòng |

> **Cả 2 checklist đã được cập nhật** để loại bỏ toàn bộ `helm install` CLI trực tiếp,
> thay bằng tham chiếu đến Helmfile bootstrap hoặc Argo CD App-of-Apps.

### 7. IaC Pipeline — Tổng quan phương pháp triển khai

> **Xem chi tiết:** `plan/infra-deployment-methodology.md`

```
┌─────────────────────────┐    ┌────────────────────────────┐    ┌──────────────────────────┐
│  ANSIBLE                │    │  HELMFILE                  │    │  ARGO CD                 │
│  (OS / Node-level)      │ →  │  (K8s Bootstrap)           │ →  │  (Steady-state GitOps)   │
│                         │    │                            │    │                          │
│  • K8s install          │    │  • cert-manager            │    │  • Harbor                │
│  • containerd           │    │  • Traefik                 │    │  • Tekton                │
│  • Flannel CNI          │    │  • Sealed Secrets          │    │  • Kyverno               │
│  • Tailscale verify     │    │  • Argo CD                 │    │  • Strimzi + Kafka       │
│  • Firewall             │    │  • (local-path-provisioner)│    │  • Monitoring (Prom+Graf)│
│                         │    │                            │    │  • Logging (Loki)        │
│  Tool: Ansible          │    │  Tool: Helmfile            │    │  • Demo apps             │
│  Run: make setup        │    │  Run: helmfile apply       │    │  Tool: Argo CD auto-sync │
│  Audit: Git + logs      │    │  Audit: Git (YAML)         │    │  Audit: Git + Argo UI    │
└─────────────────────────┘    └────────────────────────────┘    └──────────────────────────┘
```

**Nguyên tắc:**
- **Separation of concerns:** Mỗi tool chỉ quản lý đúng phạm vi của nó
- **Idempotency:** Mọi lệnh đều có thể chạy lại an toàn
- **Git = Single source of truth:** Mọi config đều nằm trong Git
- **No raw CLI commands:** Không bao giờ dùng `helm install` trực tiếp

---

## IX. KHÓ KHĂN GẶP PHẢI VÀ GIẢI PHÁP

> *Phần này ghi nhận mọi khó khăn kỹ thuật gặp phải trong quá trình chuẩn bị và triển khai,
> cùng giải pháp đã áp dụng. Dùng làm nội dung cho Chương 5§5.2 "Khó khăn gặp phải" trong báo cáo.*

### KK-1: Fedora Server → Ubuntu Server (Chuyển đổi hệ điều hành)

| | |
|---|---|
| **Vấn đề** | Ban đầu chọn Fedora Server vì tương thích tốt với Podman/CRI-O và SELinux. Tuy nhiên, SELinux ở chế độ `Enforcing` tạo ra xung đột nghiêm trọng với nhiều component CNCF: Harbor bị `CrashLoopBackOff` do SELinux chặn ghi PV, Tekton Workspace bị chặn, Kaniko không thể mount layers, kube-proxy bị SELinux chặn iptables routing qua interfaces ảo (tailscale0, flannel.1). |
| **Phân tích** | SELinux quản lý container theo label `container_t` / `container_file_t`. Mọi Pod muốn ghi data phải có đúng SELinux context → tăng gấp đôi thời gian debug cho mỗi component. Trong giới hạn 12 tuần, việc vừa học CNCF stack vừa debug SELinux là không khả thi. |
| **Giải pháp** | Chuyển toàn bộ sang **Ubuntu Server 24.04 LTS**. Ubuntu dùng AppArmor (mặc định permissive hơn), không gây xung đột với K8s/CNCF tools. Đã viết lại toàn bộ Ansible roles cho Ubuntu (apt thay dnf, systemd config khác). |
| **Hệ quả** | Mất ~1 tuần viết lại scripts, nhưng TIẾT KIỆM nhiều tuần debug SELinux. Trade-off hợp lý cho scope đồ án. |
| **Ghi nhận cho báo cáo** | Đề cập trong Ch4§4.1 (Môi trường triển khai) và Ch5§5.2 (Khó khăn). SELinux analysis vẫn có giá trị — có thể đưa vào Phụ lục hoặc "Hướng phát triển" (deploy trên RHEL/Fedora + SELinux Enforcing). |

### KK-2: containerd CRI Socket không sẵn sàng sau restart

| | |
|---|---|
| **Vấn đề** | Sau khi cài containerd 2.2.x từ Docker repo và restart service, `kubeadm init` thất bại vì CRI socket (`/run/containerd/containerd.sock`) chưa ready. |
| **Nguyên nhân** | containerd cần vài giây để khởi tạo CRI plugin sau restart, nhưng Ansible chạy task tiếp ngay lập tức. |
| **Giải pháp** | Thêm pattern `restart → sleep 5s → verify CRI socket` trong Ansible role `containerd`. Handler restart containerd rồi đợi socket sẵn sàng trước khi tiếp tục. |
| **Giá trị báo cáo** | Minh họa bài toán sequencing trong Infrastructure as Code — timing matters, không chỉ config đúng. |

### KK-3: WSL Worker Node — Giới hạn không thể vượt qua

| | |
|---|---|
| **Vấn đề** | Ban đầu dự định dùng WSL2 (Windows Subsystem for Linux) làm worker node qua Tailscale. WSL2 không hỗ trợ đầy đủ systemd services, networking bị NAT, không có persistent IP. |
| **Giải pháp** | Loại bỏ hoàn toàn WSL workers. Chuyển sang **bare metal only** — tất cả nodes đều là Ubuntu Server 24.04 chạy native. |
| **Hệ quả** | Cluster nhỏ hơn (ít nodes), nhưng ổn định hơn nhiều. Phù hợp scope đồ án. |

### KK-4: MetalLB — Component không cần thiết

| | |
|---|---|
| **Vấn đề** | Plan ban đầu include MetalLB để cung cấp `type: LoadBalancer` cho bare metal K8s. Sau khi phân tích kỹ luồng traffic, phát hiện MetalLB hoàn toàn KHÔNG CẦN. |
| **Phân tích** | Luồng traffic: Internet → Cloudflare CDN → cloudflared Pod → Traefik (ClusterIP) → App Pod. cloudflared kết nối trực tiếp đến Traefik qua ClusterIP service — không cần external IP. MetalLB chỉ cần nếu muốn expose LoadBalancer IP ra LAN, mà cluster sau Tailscale VPN không cần điều này. |
| **Giải pháp** | Loại bỏ MetalLB khỏi stack. Giảm ~200MB RAM + 1 component cần maintain. |
| **Ghi nhận** | Đây là ví dụ tốt về "right-sizing infrastructure" — chỉ cài những gì thực sự cần. Đề cập trong Ch3§3.1 (Kiến trúc tổng thể) khi giải thích luồng traffic. |

### KK-5: ELK Stack quá nặng cho bare metal

| | |
|---|---|
| **Vấn đề** | ELK Stack (Elasticsearch + Logstash + Kibana) là giải pháp logging phổ biến nhưng Elasticsearch JVM heap cần 2-4GB RAM. Cluster bare metal chỉ có ~10-12GB RAM tổng cho tất cả components. |
| **Phân tích** | ELK chiếm 4-6GB RAM → ăn hết ~50% RAM cluster → không còn đủ cho Harbor, Tekton, Kafka, Prometheus. |
| **Giải pháp** | Chuyển sang **Loki + Promtail** (~200-512MB RAM). Loki dùng label-based indexing (nhẹ), tích hợp native với Grafana (đã có sẵn từ kube-prometheus-stack). LogQL query tương tự PromQL → consistency. |
| **Ghi nhận** | So sánh ELK vs Loki+Promtail là nội dung tốt cho Ch3 (thiết kế) — thể hiện khả năng đánh giá trade-off phù hợp hạ tầng cụ thể. |

### KK-6: Raw `helm install` là anti-pattern

| | |
|---|---|
| **Vấn đề** | Hai deployment checklists ban đầu dùng `helm install ...` CLI trực tiếp → Không có audit trail, không idempotent, không reproducible, không version-controlled. |
| **Giải pháp** | Thiết kế **2-phase IaC pipeline**: Phase A (Helmfile bootstrap) + Phase B (Argo CD App-of-Apps). Xem chi tiết tại `plan/infra-deployment-methodology.md`. |
| **Hệ quả** | Tạo thêm `code/infra/helmfile/` (8 files) + `code/infra/argocd/` (9 files). Cập nhật cả 2 checklists. |
| **Ghi nhận** | Đây là nội dung quan trọng cho Ch4 (triển khai) — thể hiện tư duy devops/IaC production-grade, không phải "cài xong chạy xong là xong". |

### KK-7: Chicken-and-egg Problem (Bootstrap vs Steady-state)

| | |
|---|---|
| **Vấn đề** | Argo CD quản lý mọi thứ trên K8s qua GitOps — nhưng ai cài Argo CD? cert-manager cấp TLS cho services — nhưng ai cài cert-manager? |
| **Giải pháp** | Tách thành 2 phase: Helmfile cài "minimum viable platform" (cert-manager, Traefik, Sealed Secrets, Argo CD), sau đó Argo CD tự quản lý phần còn lại. Bootstrap components được chọn dựa trên dependency graph. |
| **Ghi nhận** | Chicken-and-egg problem là bài toán kinh điển trong platform engineering. Giải thích clear trong Ch4 sẽ tăng giá trị kỹ thuật. |

---

## X. QUYẾT ĐỊNH KIẾN TRÚC (Architecture Decision Records)

> *Mỗi quyết định kiến trúc quan trọng được ghi nhận theo format ADR đơn giản.
> Dùng làm tham chiếu khi viết Ch3 (Phân tích & Thiết kế) và Ch4 (Triển khai).*

### ADR-1: Chuyển từ Fedora Server sang Ubuntu Server 24.04

| | |
|---|---|
| **Ngày** | Giai đoạn chuẩn bị |
| **Trạng thái** | ✅ Đã áp dụng |
| **Bối cảnh** | Fedora mạnh về SELinux + Podman/CRI-O, nhưng SELinux Enforcing xung đột nghiêm trọng với nhiều CNCF tools. Debug SELinux tốn quá nhiều thời gian. |
| **Quyết định** | Dùng Ubuntu Server 24.04 LTS + containerd (Docker repo) thay vì Fedora + CRI-O. |
| **Lý do** | (1) Ubuntu LTS ổn định, community K8s support rộng nhất. (2) AppArmor mặc định permissive hơn SELinux. (3) containerd 2.2.x compatibility tốt. (4) Tiết kiệm thời gian debug → focus vào SLSA pipeline. |
| **Hệ quả** | Mất khả năng demo SELinux enforcement, nhưng đảm bảo tiến độ 12 tuần. SELinux analysis đưa vào Phụ lục hoặc "Hướng phát triển". |

### ADR-2: Loại bỏ MetalLB khỏi stack

| | |
|---|---|
| **Ngày** | Giai đoạn thiết kế |
| **Trạng thái** | ✅ Đã áp dụng |
| **Bối cảnh** | MetalLB cung cấp LoadBalancer IP cho bare metal. Tuy nhiên, luồng traffic đã dùng cloudflared → Traefik (ClusterIP) → không cần external IP. |
| **Quyết định** | Loại MetalLB. Giữ Traefik ở mode ClusterIP. cloudflared route trực tiếp tới Traefik service. |
| **Lý do** | (1) Giảm complexity (-1 component). (2) Tiết kiệm ~200MB RAM. (3) Cloudflare Tunnel + Traefik ClusterIP đủ cho mọi use case của đồ án. |
| **Hệ quả** | Không thể demo `type: LoadBalancer` services. Nếu cần → add lại MetalLB sau. Ghi nhận trong Ch3 khi giải thích traffic flow. |

### ADR-3: Loki + Promtail thay vì ELK Stack

| | |
|---|---|
| **Ngày** | Giai đoạn thiết kế |
| **Trạng thái** | ✅ Đã áp dụng |
| **Bối cảnh** | Cần log aggregation cho cluster. ELK (Elasticsearch + Logstash + Kibana) là standard nhưng Elasticsearch cần 2-4GB JVM heap → quá nặng cho bare metal ~10GB RAM. |
| **Quyết định** | Dùng Loki + Promtail (Grafana stack). |
| **Lý do** | (1) RAM: ~200-512MB vs 4-6GB. (2) Tích hợp native Grafana (đã có từ kube-prometheus-stack). (3) LogQL giống PromQL → consistency. (4) Label-based indexing phù hợp K8s metadata. |
| **Hệ quả** | Mất full-text search capability (Elasticsearch mạnh hơn ở đây). Với scope đồ án, label-based query đủ dùng. So sánh ELK vs Loki đưa vào Ch3. |

### ADR-4: Nâng Kafka (Strimzi) từ DEFER lên SHOULD-HAVE

| | |
|---|---|
| **Ngày** | Giai đoạn thiết kế |
| **Trạng thái** | ✅ Đã áp dụng |
| **Bối cảnh** | Demo app ban đầu chỉ có 1 service đơn giản. Thêm Kafka cho phép demo 2 services giao tiếp event-driven. |
| **Quyết định** | Dùng Strimzi Operator để deploy Kafka (KRaft mode, no ZooKeeper) trên K8s. Demo app gồm 2 services: demo-api (producer) + demo-worker (consumer). |
| **Lý do** | (1) 2 services → pipeline SLSA verify 2 images → chứng minh scalability. (2) Strimzi là CRD-based → phù hợp narrative "mọi thứ là K8s CRD". (3) KRaft mode giảm complexity (không cần ZooKeeper). (4) Event-driven architecture = production-realistic. (5) ~1-1.5GB RAM chấp nhận được. |
| **Hệ quả** | Tăng ~1.5GB RAM usage. Clustẹr cần ≥10GB RAM cho full stack. Nếu RAM không đủ → giảm Kafka replicas hoặc bỏ Kafka, dùng HTTP sync thay. |

### ADR-5: IaC Pipeline — Ansible → Helmfile → Argo CD

| | |
|---|---|
| **Ngày** | Giai đoạn thiết kế |
| **Trạng thái** | ✅ Đã áp dụng |
| **Bối cảnh** | Cần quản lý 3 tầng khác nhau: OS/node, K8s bootstrap, K8s steady-state. Mỗi tầng có tool phù hợp riêng. |
| **Quyết định** | 3-tool pipeline: Ansible (OS) → Helmfile (Bootstrap) → Argo CD (Steady-state). |
| **Lý do** | (1) Separation of concerns — mỗi tool quản lý đúng phạm vi. (2) Ansible mạnh ở OS-level nhưng sai abstraction cho K8s Helm releases. (3) Helmfile purpose-built cho Helm orchestration, có `diff` trước `apply`. (4) Argo CD = GitOps standard, drift detection, auto-reconcile. (5) Giải quyết chicken-and-egg problem. |
| **Hệ quả** | Team cần biết 3 tools (Ansible + Helmfile + Argo CD). Trong scope đồ án 1 người, đây là complexity chấp nhận được và tăng chiều sâu kỹ thuật cho báo cáo. |
| **Document chi tiết** | `plan/infra-deployment-methodology.md` |

---

## XI. PHƯƠNG ÁN TỐI ƯU VÀ CHIẾN LƯỢC ƯU TIÊN

> *Phần này đề xuất các phương án tối ưu khi gặp giới hạn về thời gian, RAM, hoặc độ phức tạp.*

### 1. Tối ưu tài nguyên (RAM / CPU) cho bare metal

#### Nếu cluster chỉ có 8GB RAM (thay vì 10-12GB)

```
Ưu tiên      Component                    RAM ước tính    Hành động
──────────────────────────────────────────────────────────────────────
🔴 KEEP      K8s system (kubelet, etcd)    ~1.5 GB         Không giảm được
🔴 KEEP      Flannel + local-path          ~200 MB         Rất nhẹ
🔴 KEEP      Traefik + cloudflared         ~400 MB         Core networking
🔴 KEEP      Tekton + Chains               ~400 MB         SLSA core
🔴 KEEP      Cosign + Kyverno              ~300 MB         SLSA verify
🔴 KEEP      Harbor                        ~1.5 GB         Registry — giảm Trivy nếu cần
🟠 REDUCE    Argo CD                       ~512→256 MB     Giảm replicas xuống 1
🟠 REDUCE    Prometheus + Grafana          ~1 GB→512 MB    Giảm retention, tắt some exporters
🟡 DEFER     Loki + Promtail              ~512 MB         Dùng kubectl logs tạm thời
🟡 DEFER     Kafka (Strimzi)              ~1.5 GB         Demo 1 service thay vì 2
❌ SKIP      Istio / Linkerd              ~1-2 GB         Bỏ service mesh
──────────────────────────────────────────────────────────────────────
                                TỔNG:     ~6.3-7 GB       Vừa đủ cho 8GB
```

#### Chiến lược giảm RAM cụ thể

| Component | Cách giảm RAM |
|---|---|
| **Harbor** | Tắt Trivy scanner (`trivy.enabled=false`), giảm registry cache |
| **Argo CD** | `server.replicas=1`, `repoServer.replicas=1` |
| **Prometheus** | Giảm `retention=6h` (thay vì 15d), tắt `nodeExporter` nếu single node |
| **Grafana** | Giảm `resources.limits.memory=128Mi` |
| **Kafka** | `kafka.jvmOptions: -Xms256m -Xmx512m` (thay vì 1GB default) |
| **Kyverno** | Đã set 1 replica, không giảm thêm được |

### 2. Tối ưu thời gian — Nếu chỉ còn ít tuần

#### Priority Matrix — Cái gì LÀM TRƯỚC?

```
                    GIÁ TRỊ HỌC THUẬT CAO
                           │
                           │
    ┌──────────────────────┼──────────────────────┐
    │                      │                      │
    │  Tekton + Chains     │  Argo CD GitOps      │
    │  Kyverno verify      │  Kafka 2-service     │
    │  Attack scenarios    │  Loki logging        │
    │                      │  Prometheus dashboards│
    │  >>> LÀM NGAY <<<   │  >>> LÀM SAU <<<     │
    │                      │                      │
 ÍT ├──────────────────────┼──────────────────────┤ NHIỀU
THỜI│                      │                      │ THỜI
GIAN│  Harbor self-hosted  │  Istio/Linkerd       │ GIAN
    │  SBOM (Syft+Grype)   │  GitHub Actions      │
    │                      │  (để so sánh)        │
    │  >>> CÓ THỂ BỎ <<<  │  >>> BONUS <<<       │
    │  (dùng GHCR thay)    │                      │
    └──────────────────────┼──────────────────────┘
                           │
                    GIÁ TRỊ HỌC THUẬT THẤP
```

#### Minimum Viable Thesis (MVT) — Nếu chỉ còn 6 tuần

Nếu thời gian rất hạn chế, đây là **minimum set** để vẫn có đồ án đạt yêu cầu:

```
1. K8s cluster (Ansible — đã có)                    ✅ Sẵn sàng
2. Tekton Pipeline + Chains + Cosign                 🔴 Core SLSA
3. Kyverno verify images                             🔴 Core Zero Trust
4. GHCR thay Harbor (tiết kiệm ~1.5GB RAM + setup)  🟡 Trade-off
5. 1 demo service (thay vì 2 + Kafka)               🟡 Trade-off
6. 5 attack scenarios                                🔴 Core evaluation
7. kubectl apply thay Argo CD                        🟡 Trade-off

→ Vẫn đạt SLSA L3 + Zero Trust + có demo + có attack scenarios
→ Mất: GitOps narrative, event-driven demo, monitoring dashboards
```

### 3. Chiến lược content nếu một component fail

| Component fail | Fallback | Ảnh hưởng thesis |
|---|---|---|
| Tekton fail | GitHub Actions + slsa-github-generator | Vẫn đạt SLSA L3. Mất narrative "self-hosted" nhưng có so sánh |
| Harbor fail | GHCR (free) | Mất tính self-hosted nhưng pipeline SLSA không bị ảnh hưởng |
| Argo CD fail | `kubectl apply` / Helmfile | Mất GitOps narrative nhưng apps vẫn deploy được |
| Kafka/Strimzi fail | HTTP sync hoặc 1 service only | Mất event-driven demo nhưng SLSA pipeline vẫn ok |
| Kyverno fail | Sigstore Policy Controller | Alternative policy engine, vẫn chặn unsigned image |
| Cosign keyless fail | `cosign generate-key-pair` (key-based) | Vẫn đạt SLSA L3, mất transparency log (Rekor) |
| Loki fail | `kubectl logs` + manual inspection | Mất centralized logging nhưng không ảnh hưởng core pipeline |

### 4. Phương án tối ưu cho thesis — Tăng giá trị báo cáo

| Phương án | Chi tiết | Tác động lên điểm |
|---|---|---|
| **So sánh 2 CI/CD approaches** | Tekton (self-hosted) vs GitHub Actions (SaaS) — benchmark thời gian, overhead, compliance | ⭐⭐⭐ Rất cao — thể hiện chiều sâu nghiên cứu |
| **Attack scenario matrix** | 5 kịch bản rõ ràng, có screenshot, logs | ⭐⭐⭐ Core evaluation — hội đồng muốn thấy |
| **Performance benchmark** | Admission latency có/không Kyverno, pipeline duration | ⭐⭐ Số liệu cụ thể thuyết phục hơn |
| **Architecture decision documentation** | ADRs trong báo cáo → thể hiện tư duy kiến trúc | ⭐⭐ Bonus quality |
| **Grafana dashboards screenshot** | Monitoring dashboards cho K8s, Tekton, Traefik | ⭐⭐ Visual evidence |
| **IaC methodology explanation** | Tại sao Helmfile + Argo CD thay vì raw helm | ⭐⭐ DevOps maturity |
| **SELinux analysis (appendix)** | Phân tích SELinux dù không dùng Fedora cuối cùng | ⭐ Bonus — thể hiện research depth |

---

## XII. CHUẨN BỊ NỘI DUNG VIẾT BÁO CÁO — Thesis Writing Content Map

> *Phần này mapping trực tiếp những gì đã chuẩn bị → từng chương/mục trong báo cáo.
> Giúp viết nhanh hơn vì biết chính xác content lấy từ đâu.*

### Chương 1: Tổng quan đề tài

| Mục | Content nguồn | Trạng thái |
|---|---|---|
| 1.1 Bối cảnh & lý do chọn đề tài | Supply chain attacks (SolarWinds, Codecov, xz-utils), xu hướng Zero Trust | 🔲 Cần viết |
| 1.2 Mục tiêu nghiên cứu | Thiết kế + triển khai hệ thống Zero Trust SCM trên K8s, đạt SLSA L3 | 🔲 Cần viết |
| 1.3 Đối tượng & phạm vi | Build Track L3 + Source Track L3 (không L4); bare metal K8s; 2 microservices demo | 🔲 Cần viết |
| 1.4 Bố cục đồ án | 5 chương — overview | 🔲 Cần viết |

**Nguồn tham khảo:** `plan/thesis-proposal-plan.md` Section II §Mảng 1, các case study.

### Chương 2: Cơ sở lý thuyết

| Mục | Content nguồn | Trạng thái |
|---|---|---|
| 2.1 Software Supply Chain & Rủi ro | Attack case studies + SLSA threat model | 🔲 Cần nghiên cứu thêm |
| 2.2 Mô hình Zero Trust | NIST SP 800-207, áp dụng vào SDLC | 🔲 Cần nghiên cứu thêm |
| 2.3 Khung tiêu chuẩn SLSA | `plan/thesis-proposal-plan.md` Section I.B — **đã có bảng phân tích chi tiết** | ✅ Content sẵn sàng |
| 2.4 Kubernetes & Container Security | Section I.E (K8s deep-dive) — admission controllers, CRDs, RBAC, Pod lifecycle | ✅ Content sẵn sàng |
| 2.5 Hệ sinh thái công cụ | Section I.C (so sánh chi tiết 6 nhóm công nghệ) | ✅ Content sẵn sàng |

### Chương 3: Phân tích và Thiết kế hệ thống

| Mục | Content nguồn | Trạng thái |
|---|---|---|
| 3.1 Kiến trúc tổng thể | Section I.F — Platform Layers diagram, Namespace organization, Resource estimation | ✅ Content sẵn sàng |
| 3.1.1 Traffic flow | Section I.F §8 — Traefik + Cloudflare integration detail | ✅ Content sẵn sàng |
| 3.1.2 IaC methodology | `plan/infra-deployment-methodology.md` — 2-phase approach, comparison table | ✅ Content sẵn sàng |
| 3.2 Thiết kế giai đoạn Source | Branch protection rules, commit signing — cần triển khai | 🔲 Cần triển khai + viết |
| 3.3 Thiết kế giai đoạn Build (SLSA L3) | Section I.C §1 (Tekton vs GH Actions), §4 (keyless vs key-based), §5 (Kaniko vs Docker) | ✅ Content sẵn sàng |
| 3.4 Thiết kế giai đoạn Deploy | Section I.C §2 (Kyverno vs OPA), §6 (Argo CD vs kubectl) | ✅ Content sẵn sàng |
| 3.5 Kịch bản kiểm thử | Section II §Mảng 2 §5 — 5 attack scenarios đã thiết kế | ✅ Design sẵn sàng |
| 3.6 So sánh công nghệ | Section I.C — 6 bảng so sánh chi tiết (CI/CD, Policy, Registry, Signing, Build, CD) | ✅ Content sẵn sàng |

### Chương 4: Triển khai và Đánh giá

| Mục | Content nguồn | Trạng thái |
|---|---|---|
| 4.1 Môi trường triển khai | Ansible roles (8 roles — đã code), network topology (Tailscale IPs), resource table (Section I.F §5) | ✅ Code sẵn sàng, cần screenshots |
| 4.1.1 Cài đặt K8s cluster | `code/infra/ansible/` — toàn bộ automation | ✅ Code sẵn sàng |
| 4.1.2 K8s platform bootstrap | `code/infra/helmfile/` — Helmfile files + values | ✅ Code sẵn sàng |
| 4.1.3 Steady-state GitOps | `code/infra/argocd/` — App-of-Apps manifests | ✅ Code sẵn sàng |
| 4.2 Triển khai Pipeline CI/CD | 🔲 Cần viết Tekton Pipeline/Task YAML, config Chains | 🔲 Cần triển khai |
| 4.3 Triển khai Policy Engine | 🔲 Cần viết ClusterPolicy YAML cho Kyverno | 🔲 Cần triển khai |
| 4.4 Kết quả kiểm thử | 🔲 Cần chạy 5 attack scenarios, capture screenshots/logs | 🔲 Cần triển khai |
| 4.5 Đánh giá hiệu năng | 🔲 Cần benchmark Kyverno admission latency, pipeline duration | 🔲 Cần triển khai |
| 4.6 Đối chiếu SLSA L3 | Section I.B — bảng đối chiếu đã có | ✅ Template sẵn sàng, cần data thực |

### Chương 5: Kết luận và Hướng phát triển

| Mục | Content nguồn | Trạng thái |
|---|---|---|
| 5.1 Kết luận | Tóm tắt những gì đã đạt được — viết sau khi hoàn thành Ch4 | 🔲 Viết cuối |
| 5.2 Khó khăn gặp phải | **Section IX (document này)** — 7 khó khăn đã ghi nhận | ✅ Content sẵn sàng |
| 5.3 Hướng phát triển tương lai | SELinux Enforcing trên RHEL, Istio service mesh, multi-cluster, production hardening | ✅ Ideas sẵn sàng |

### Phụ lục

| Phụ lục | Content nguồn | Trạng thái |
|---|---|---|
| A. Source code pipeline | Tekton Pipeline/Task YAML | 🔲 Cần triển khai |
| B. Kyverno Policy YAML | ClusterPolicy verify images | 🔲 Cần triển khai |
| C. Provenance JSON mẫu | Output từ Tekton Chains | 🔲 Cần capture |
| D. Hướng dẫn tái tạo | Ansible + Helmfile + Argo CD workflow | ✅ Đã có README.md |
| E. SELinux Analysis | `plan/obstacles-and-difficulties.txt` — phân tích SELinux/Fedora | ✅ Content sẵn sàng |
| F. Architecture Decision Records | Section X (document này) — 5 ADRs | ✅ Content sẵn sàng |
| G. Deployment Checklists | `plan/checklist-option-a-full-cncf.md`, `plan/checklist-option-b-saas-lightweight.md` | ✅ Content sẵn sàng |

### Tổng hợp: Content Readiness Scorecard

```
CHƯƠNG           CONTENT SẴN SÀNG    CẦN TRIỂN KHAI    CẦN VIẾT MỚI
────────────────────────────────────────────────────────────────────
Ch1: Tổng quan         20%                -               80%
Ch2: Lý thuyết         70%                -               30%
Ch3: Thiết kế          80%                -               20%
Ch4: Triển khai        40%               50%              10%
Ch5: Kết luận          50%                -               50%
Phụ lục                50%               30%              20%
────────────────────────────────────────────────────────────────────
TRUNG BÌNH             ~52%              ~13%             ~35%
```

> **Nhận xét:** Phần thiết kế (Ch2 + Ch3) đã có ~75% content sẵn sàng từ plan.
> Phần triển khai (Ch4) cần effort lớn nhất — phải chạy thực tế + capture kết quả.
> Phần lý thuyết (Ch1 + Ch2) cần nghiên cứu thêm case studies và standards.

### Checklist: Dữ liệu / Screenshot cần thu thập khi triển khai

- [ ] **K8s cluster status:** `kubectl get nodes`, `kubectl get pods -A`
- [ ] **Helmfile output:** `helmfile diff` + `helmfile apply` terminal output
- [ ] **Argo CD dashboard:** Screenshot sync status toàn bộ apps
- [ ] **Tekton Dashboard:** Screenshot pipeline runs (success + fail)
- [ ] **Harbor UI:** Screenshot repository, image details, Trivy scan results
- [ ] **Cosign verify output:** Terminal output verify signature + attestation
- [ ] **Kyverno logs:** Admission allow/deny logs cho mỗi attack scenario
- [ ] **Grafana dashboards:** K8s overview, Traefik traffic, Tekton metrics
- [ ] **Attack scenario logs:** Full terminal output cho 5 kịch bản
- [ ] **Performance data:** Admission latency numbers, pipeline duration
- [ ] **Resource usage:** `kubectl top nodes`, `kubectl top pods`
- [ ] **Provenance JSON:** Raw in-toto provenance output từ Tekton Chains
- [ ] **Kafka UI/logs:** Producer → Consumer message flow (nếu dùng Kafka)
