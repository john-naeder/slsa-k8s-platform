# 06 — Cloudflare Networking

> Cấu hình Cloudflare Tunnel route, DNS, và Zero Trust Access policy.
> Cho phép truy cập ArgoCD UI (và các service khác) qua domain `kythuat.vn`.

## Kiến trúc

```
  ┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
  │   Browser    │     │  Cloudflare  │     │  cloudflared │     │   Traefik    │
  │              │────▶│  CDN + WAF   │────▶│  Pod (K8s)   │────▶│  Ingress     │────▶ App
  │              │     │  Zero Trust  │     │  Tunnel      │     │  Controller  │
  └──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘
                       argocd.kythuat.vn     Outbound only        IngressRoute
                       CNAME → tunnel        No open ports        Host matching
```

## Thông tin hiện tại

| Setting | Giá trị |
|---------|---------|
| Domain | kythuat.vn |
| Zone ID | `5b5f5899efaa46ec15c1790063d062c2` |
| Account ID | `7bcb17f8406016e96db910de9b0c2253` |
| Tunnel ID | `3d402a26-0f5f-48af-a110-690ceb1c0302` |
| Tunnel CNAME | `3d402a26-0f5f-48af-a110-690ceb1c0302.cfargotunnel.com` |
| Tunnel protocol | http2 |
| Edge locations | SIN (Singapore) |

## 6.1 — Cấu hình Tunnel Route (Tự động)

Script `setup-route.sh` tự động cấu hình:
1. Tunnel ingress rule: `argocd.kythuat.vn` → `http://traefik.traefik.svc.cluster.local:80`
2. DNS CNAME record: `argocd.kythuat.vn` → tunnel CNAME (proxied)

```bash
cd code/infra/manifests/cloudflared/

# Set API token (cần Zone:DNS:Edit + Account:Tunnel:Edit)
export CF_API_TOKEN="your-cloudflare-api-token"

# Chạy
bash setup-route.sh
```

### Script flow:
1. Verify API token
2. Lấy Zone ID cho `kythuat.vn`
3. GET tunnel config hiện tại
4. Build new ingress rules (Python): giữ rules cũ + thêm/update rule mới + catch-all 404
5. PUT tunnel config
6. Xóa DNS records cũ cho hostname
7. Tạo CNAME mới (proxied)
8. Wait 10s + verify DNS

### Thêm service mới

Để expose thêm service (ví dụ: `harbor.kythuat.vn`), sửa các biến trong script:

```bash
SUBDOMAIN="harbor"
SERVICE_URL="http://harbor-portal.harbor.svc.cluster.local:80"
```

Hoặc tạo script tương tự. Ingress rules được merge — không xóa rules cũ.

## 6.2 — Cấu hình Tunnel Route (Thủ công)

Nếu không dùng script, cấu hình trên Cloudflare Dashboard:

1. [Zero Trust Dashboard](https://one.dash.cloudflare.com/) → Networks → Tunnels
2. Click tunnel → **Public Hostname** tab
3. **Add a public hostname:**
   - Subdomain: `argocd`
   - Domain: `kythuat.vn`
   - Type: HTTP
   - URL: `traefik.traefik.svc.cluster.local:80`
   - HTTP Host Header: `argocd.kythuat.vn`
   - No TLS Verify: ✅ (TLS terminated at Cloudflare, not inside cluster)

## 6.3 — Zero Trust Access Policy

Thêm lớp authentication trước khi vào ArgoCD (email OTP).

### Cách 1: Script tự động

```bash
# Cần token có thêm permission: Account → Access: Apps and Policies → Edit
export CF_API_TOKEN="your-token-with-access-scope"

# Optional: custom email list
export CF_ALLOWED_EMAILS="email1@gmail.com,email2@gmail.com"

bash setup-access-policy.sh
```

### Cách 2: Cloudflare Dashboard (thủ công)

1. [Zero Trust Dashboard](https://one.dash.cloudflare.com/) → Access → **Applications**
2. **Add an application** → Self-hosted
3. Application Configuration:
   - Name: `Argo CD Platform`
   - Session Duration: 24h
   - Application domain: `argocd.kythuat.vn`
4. Add Policy:
   - Policy name: `Allow Admin`
   - Action: Allow
   - Include: Emails — `johnnaeder6537@gmail.com`
5. Save

### Khi truy cập

Truy cập `https://argocd.kythuat.vn` → sẽ thấy:
1. **Cloudflare Access login** — nhập email → nhận OTP code
2. Verify OTP → forward tới ArgoCD
3. **ArgoCD login** — nhập admin/password

## 6.4 — DNS Records

| Record | Type | Name | Content | Proxied |
|--------|------|------|---------|---------|
| ArgoCD | CNAME | argocd | `3d402a26-...cfargotunnel.com` | ✅ (orange cloud) |

> Thêm record cho service khác (harbor, grafana...) bằng cách chạy `setup-route.sh` với SUBDOMAIN khác.

## Verify

```bash
# DNS resolution
dig +short argocd.kythuat.vn
# Trả về Cloudflare proxy IPs (104.x.x.x / 172.x.x.x)

# End-to-end test
curl -sI https://argocd.kythuat.vn
# HTTP/2 200
# server: cloudflare
# cf-ray: xxxxx-SIN
# x-frame-options: DENY
# x-content-type-options: nosniff
# strict-transport-security: max-age=31536000; includeSubDomains; preload
```

## Security Headers (from Traefik Middleware)

| Header | Giá trị |
|--------|---------|
| X-Frame-Options | DENY |
| X-Content-Type-Options | nosniff |
| X-XSS-Protection | 1; mode=block |
| Strict-Transport-Security | max-age=31536000; includeSubDomains; preload |
| Referrer-Policy | strict-origin-when-cross-origin |
| X-Robots-Tag | noindex, nofollow |

## Files liên quan

| File | Mô tả |
|------|-------|
| `manifests/cloudflared/setup-route.sh` | Tunnel route + DNS automation |
| `manifests/cloudflared/setup-access-policy.sh` | Zero Trust Access automation |
| `manifests/cloudflared/deployment.yaml` | cloudflared K8s Deployment |
| `manifests/argocd/ingressroute.yaml` | Traefik IngressRoute + security headers |
