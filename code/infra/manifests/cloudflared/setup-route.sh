#!/usr/bin/env bash
# =============================================================================
# setup-route.sh — Configure Cloudflare Tunnel route for argocd.kythuat.vn
# =============================================================================
#
# Tự động cấu hình:
#   1. Thêm Public Hostname argocd.kythuat.vn → traefik (Cloudflare Tunnel)
#   2. Xóa A record cũ + tạo CNAME record cho tunnel
#
# Cần:
#   export CF_API_TOKEN="<your-cloudflare-api-token>"
#   (Token cần có quyền: Zone:DNS:Edit + Account:Cloudflare Tunnel:Edit)
#
# Tạo API Token tại: https://dash.cloudflare.com/profile/api-tokens
#   → Use template "Edit zone DNS" và tự thêm "Cloudflare Tunnel" scope
#
# Usage:
#   CF_API_TOKEN="xxxxx" bash setup-route.sh
# =============================================================================
set -euo pipefail

# ─── CONFIG ────────────────────────────────────────────────────────────────────
TUNNEL_ID="3d402a26-0f5f-48af-a110-690ceb1c0302"
ACCOUNT_ID="7bcb17f8406016e96db910de9b0c2253"
ZONE_NAME="kythuat.vn"
SUBDOMAIN="argocd"
HOSTNAME="${SUBDOMAIN}.${ZONE_NAME}"
# Service URL: Traefik ClusterIP service (only reachable from cloudflared pod)
SERVICE_URL="http://traefik.traefik.svc.cluster.local:80"
CF_API="https://api.cloudflare.com/client/v4"

# ─── VALIDATE ──────────────────────────────────────────────────────────────────
if [[ -z "${CF_API_TOKEN:-}" ]]; then
  echo "❌ CF_API_TOKEN chưa được set!"
  echo "   export CF_API_TOKEN='your-token-here'"
  echo "   Tạo tại: https://dash.cloudflare.com/profile/api-tokens"
  exit 1
fi

echo "🔍 Verifying API token..."
TOKEN_CHECK=$(curl -sf -X GET "${CF_API}/user/tokens/verify" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json")
if ! echo "$TOKEN_CHECK" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d['success'] else 1)" 2>/dev/null; then
  echo "❌ API Token không hợp lệ!"
  exit 1
fi
echo "✅ API Token hợp lệ"

# ─── GET ZONE ID ───────────────────────────────────────────────────────────────
echo "🔍 Getting Zone ID for ${ZONE_NAME}..."
ZONE_RESP=$(curl -sf -X GET "${CF_API}/zones?name=${ZONE_NAME}" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json")
ZONE_ID=$(echo "$ZONE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result'][0]['id'])" 2>/dev/null)
if [[ -z "$ZONE_ID" ]]; then
  echo "❌ Không tìm thấy Zone ID cho ${ZONE_NAME}!"
  exit 1
fi
echo "✅ Zone ID: ${ZONE_ID}"

# ─── CONFIGURE TUNNEL INGRESS ROUTE ────────────────────────────────────────────
echo ""
echo "📡 Configuring tunnel ingress route for ${HOSTNAME}..."

# Get current tunnel config
TUNNEL_CONFIG=$(curl -sf -X GET \
  "${CF_API}/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json")

# Build new ingress config (add argocd route + catch-all)
NEW_CONFIG=$(python3 - << PYEOF
import json, sys

data = json.loads('''${TUNNEL_CONFIG}''')
existing = data.get('result', {}).get('config', {}).get('ingress', [])

# Remove existing argocd entry and catch-all
filtered = [r for r in existing if r.get('hostname') != '${HOSTNAME}' and r.get('hostname') != '']

# New argocd route
argocd_route = {
    "hostname": "${HOSTNAME}",
    "service": "${SERVICE_URL}",
    "originRequest": {
        "noTLSVerify": True,
        "httpHostHeader": "${HOSTNAME}",
        "connectTimeout": "30s",
        "tlsTimeout": "30s",
        "tcpKeepAlive": "30s"
    }
}

# Catch-all must be last
catch_all = {"service": "http_status:404"}

new_ingress = [argocd_route] + filtered + [catch_all]
print(json.dumps({"config": {"ingress": new_ingress}}, indent=2))
PYEOF
)

UPDATE_RESP=$(curl -sf -X PUT \
  "${CF_API}/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${NEW_CONFIG}")

if echo "$UPDATE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d['success'] else 1)" 2>/dev/null; then
  echo "✅ Tunnel ingress route configured: ${HOSTNAME} → ${SERVICE_URL}"
else
  echo "❌ Lỗi cấu hình tunnel config:"
  echo "$UPDATE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get('errors',[]), indent=2))" 2>/dev/null
  exit 1
fi

# ─── UPDATE DNS RECORD ──────────────────────────────────────────────────────────
echo ""
echo "🌐 Updating DNS record for ${HOSTNAME}..."
TUNNEL_CNAME="${TUNNEL_ID}.cfargotunnel.com"

# Check existing DNS records for argocd.kythuat.vn
DNS_LIST=$(curl -sf -X GET \
  "${CF_API}/zones/${ZONE_ID}/dns_records?name=${HOSTNAME}" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json")

EXISTING_IDS=$(echo "$DNS_LIST" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for r in d.get('result', []):
    print(r['id'] + '|' + r['type'])
" 2>/dev/null)

# Delete existing A records (replace with CNAME for tunnel)
while IFS='|' read -r rec_id rec_type; do
  if [[ -n "$rec_id" ]]; then
    echo "  🗑️  Deleting existing ${rec_type} record (${rec_id})..."
    curl -sf -X DELETE \
      "${CF_API}/zones/${ZONE_ID}/dns_records/${rec_id}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" > /dev/null
  fi
done <<< "$EXISTING_IDS"

# Create new CNAME → tunnel
CREATE_RESP=$(curl -sf -X POST \
  "${CF_API}/zones/${ZONE_ID}/dns_records" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{
    \"type\": \"CNAME\",
    \"name\": \"${SUBDOMAIN}\",
    \"content\": \"${TUNNEL_CNAME}\",
    \"proxied\": true,
    \"comment\": \"Cloudflare Tunnel → Traefik → Argo CD\"
  }")

if echo "$CREATE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d['success'] else 1)" 2>/dev/null; then
  echo "✅ DNS CNAME created: ${HOSTNAME} → ${TUNNEL_CNAME} (proxied)"
else
  echo "❌ Lỗi tạo DNS record:"
  echo "$CREATE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get('errors',[]), indent=2))" 2>/dev/null
  exit 1
fi

# ─── VERIFY ────────────────────────────────────────────────────────────────────
echo ""
echo "⏳ Waiting 10s for DNS propagation..."
sleep 10

echo "🔍 Verifying DNS..."
dig +short "${HOSTNAME}" 2>/dev/null || nslookup "${HOSTNAME}" 2>/dev/null | tail -5

echo ""
echo "✅ ══════════════════════════════════════════════════════"
echo "   Setup hoàn tất! Argo CD UI qua Cloudflare Tunnel:"
echo ""
echo "   🌐 https://${HOSTNAME}"
echo ""
echo "   Lưu ý: Nếu bạn chưa cấu hình Cloudflare Access policy,"
echo "   bất kỳ ai có link cũng có thể truy cập Argo CD login."
echo ""
echo "   Để thêm bảo mật Zero Trust, chạy:"
echo "   bash setup-access-policy.sh"
echo "══════════════════════════════════════════════════════════"
