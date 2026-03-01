#!/usr/bin/env bash
# =============================================================================
# setup-access-policy.sh — Cloudflare Zero Trust Access policy for argocd
# =============================================================================
#
# Tạo Cloudflare Access Application + Policy cho argocd.kythuat.vn.
# Users phải auth qua Cloudflare trước khi đến được Argo CD.
#
# Usage:
#   CF_API_TOKEN="xxxxx" bash setup-access-policy.sh
#
# Tùy chọn thêm email:
#   CF_API_TOKEN="xxxxx" CF_ALLOWED_EMAILS="a@b.com,c@d.com" bash setup-access-policy.sh
# =============================================================================
set -euo pipefail

# ─── CONFIG ────────────────────────────────────────────────────────────────────
ACCOUNT_ID="7bcb17f8406016e96db910de9b0c2253"
ZONE_NAME="kythuat.vn"
HOSTNAME="argocd.kythuat.vn"
APP_NAME="Argo CD Platform"
SESSION_DURATION="24h"
# Default allowed emails (comma-separated)
ALLOWED_EMAILS="${CF_ALLOWED_EMAILS:-johnnaeder6537@gmail.com}"
CF_API="https://api.cloudflare.com/client/v4"

# ─── VALIDATE ──────────────────────────────────────────────────────────────────
if [[ -z "${CF_API_TOKEN:-}" ]]; then
  echo "❌ CF_API_TOKEN chưa được set!"
  echo "   export CF_API_TOKEN='your-token-here'"
  exit 1
fi

echo "🔍 Verifying API token..."
TOKEN_CHECK=$(curl -sf -X GET "${CF_API}/user/tokens/verify" \
  -H "Authorization: Bearer ${CF_API_TOKEN}")
if ! echo "$TOKEN_CHECK" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d['success'] else 1)" 2>/dev/null; then
  echo "❌ API Token không hợp lệ!"
  exit 1
fi
echo "✅ API Token hợp lệ"

# Build email list for policy
EMAIL_RULES=$(python3 - << PYEOF
import json
emails = [e.strip() for e in "${ALLOWED_EMAILS}".split(",") if e.strip()]
rules = [{"email": {"email": e}} for e in emails]
print(json.dumps(rules))
PYEOF
)

# ─── DELETE EXISTING ACCESS APP ────────────────────────────────────────────────
echo ""
echo "🔍 Checking for existing Access Application..."
APPS_RESP=$(curl -sf -X GET \
  "${CF_API}/accounts/${ACCOUNT_ID}/access/apps" \
  -H "Authorization: Bearer ${CF_API_TOKEN}")

EXISTING_APP_ID=$(echo "$APPS_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for app in d.get('result', []):
    if app.get('domain') == '${HOSTNAME}':
        print(app['id'])
        break
" 2>/dev/null)

if [[ -n "$EXISTING_APP_ID" ]]; then
  echo "  🗑️  Removing existing Access Application (${EXISTING_APP_ID})..."
  curl -sf -X DELETE \
    "${CF_API}/accounts/${ACCOUNT_ID}/access/apps/${EXISTING_APP_ID}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" > /dev/null
fi

# ─── CREATE ACCESS APPLICATION ──────────────────────────────────────────────────
echo "🛡️  Creating Cloudflare Access Application..."

APP_CONFIG=$(python3 - << PYEOF
import json
config = {
    "name": "${APP_NAME}",
    "domain": "${HOSTNAME}",
    "type": "self_hosted",
    "session_duration": "${SESSION_DURATION}",
    "auto_redirect_to_identity": False,
    "allowed_idps": [],
    "enable_binding_cookie": True,
    "http_only_cookie_attribute": True,
    "same_site_cookie_attribute": "lax",
    "skip_interstitial": False,
    "app_launcher_visible": True,
    "logo_url": "https://raw.githubusercontent.com/argoproj/argo-cd/master/ui/src/assets/images/logo.png",
    "tags": ["devops", "argocd"],
    "policies": [
        {
            "name": "Allow Admin",
            "precedence": 1,
            "decision": "allow",
            "include": ${EMAIL_RULES},
            "require": [],
            "exclude": []
        }
    ]
}
print(json.dumps(config, indent=2))
PYEOF
)

CREATE_RESP=$(curl -sf -X POST \
  "${CF_API}/accounts/${ACCOUNT_ID}/access/apps" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${APP_CONFIG}")

if echo "$CREATE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d['success'] else 1)" 2>/dev/null; then
  APP_ID=$(echo "$CREATE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result']['id'])")
  AUD=$(echo "$CREATE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['result'].get('aud','N/A'))")
  echo "✅ Access Application created!"
  echo "   App ID: ${APP_ID}"
  echo "   AUD:    ${AUD}"
else
  echo "❌ Lỗi tạo Access Application:"
  echo "$CREATE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get('errors',[]), indent=2))" 2>/dev/null
  exit 1
fi

echo ""
echo "✅ ══════════════════════════════════════════════════════"
echo "   Cloudflare Zero Trust Access đã được cấu hình!"
echo ""
echo "   🛡️  Protected URL: https://${HOSTNAME}"
echo "   👥  Allowed users: ${ALLOWED_EMAILS}"
echo "   ⏱️  Session: ${SESSION_DURATION}"
echo ""
echo "   Flow: Browser → Cloudflare Access (email OTP)"
echo "         → Argo CD Login (admin / 6bcmh8VWcP-9CUey)"
echo ""
echo "   5 lớp bảo mật:"
echo "    1. Cloudflare Tunnel (zero inbound ports)"
echo "    2. Cloudflare WAF + DDoS protection"
echo "    3. Cloudflare Access Zero Trust (email auth)"
echo "    4. Traefik security headers middleware"
echo "    5. Argo CD RBAC"
echo "══════════════════════════════════════════════════════════"
