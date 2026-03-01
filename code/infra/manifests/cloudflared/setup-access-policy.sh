#!/usr/bin/env bash
# =============================================================================
# setup-access-policy.sh — Cloudflare Zero Trust Access for argocd.kythuat.vn
# =============================================================================
# Usage:  CF_API_TOKEN="xxxxx" bash setup-access-policy.sh
# Optional: CF_ALLOWED_EMAILS="a@b.com,c@d.com" CF_API_TOKEN="..." bash setup-access-policy.sh
# =============================================================================
set -euo pipefail

ACCOUNT_ID="7bcb17f8406016e96db910de9b0c2253"
HOSTNAME="argocd.kythuat.vn"
APP_NAME="Argo CD Platform"
SESSION_DURATION="24h"
ALLOWED_EMAILS="${CF_ALLOWED_EMAILS:-johnnaeder6537@gmail.com}"
CF_API="https://api.cloudflare.com/client/v4"

trap 'rm -f /tmp/cf_access_*.json /tmp/cf_access_*.txt' EXIT

if [[ -z "${CF_API_TOKEN:-}" ]]; then
  echo "❌ CF_API_TOKEN not set"
  exit 1
fi

echo "🔍 Verifying API token..."
TOKEN_RESP=$(curl -s "${CF_API}/user/tokens/verify" -H "Authorization: Bearer ${CF_API_TOKEN}")
echo "$TOKEN_RESP" | python3 -c "import sys,json; exit(0 if json.load(sys.stdin)['success'] else 1)" \
  || { echo "❌ Invalid token"; exit 1; }
echo "✅ API Token valid"

echo ""
echo "🔍 Checking for existing Access Application..."

# List existing apps and delete matching one
APPS_RESP=$(curl -s "${CF_API}/accounts/${ACCOUNT_ID}/access/apps" \
  -H "Authorization: Bearer ${CF_API_TOKEN}")

EXISTING_APP_ID=$(echo "$APPS_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for app in d.get('result', []):
    if app.get('domain') == '${HOSTNAME}':
        print(app['id'])
        break
" 2>/dev/null || true)

if [[ -n "$EXISTING_APP_ID" ]]; then
  echo "  🗑️  Removing existing app (${EXISTING_APP_ID})..."
  curl -s -X DELETE \
    "${CF_API}/accounts/${ACCOUNT_ID}/access/apps/${EXISTING_APP_ID}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" > /dev/null
fi

echo "🛡️  Creating Cloudflare Access Application..."

# Build email include rules
echo "${ALLOWED_EMAILS}" > /tmp/cf_access_emails.txt

python3 << 'PYEOF'
import json

emails_raw = open('/tmp/cf_access_emails.txt').read().strip()
emails = [e.strip() for e in emails_raw.split(',') if e.strip()]
include_rules = [{"email": {"email": e}} for e in emails]

app_config = {
    "name": "Argo CD Platform",
    "domain": "argocd.kythuat.vn",
    "type": "self_hosted",
    "session_duration": "24h",
    "auto_redirect_to_identity": False,
    "allowed_idps": [],
    "enable_binding_cookie": True,
    "http_only_cookie_attribute": True,
    "same_site_cookie_attribute": "lax",
    "skip_interstitial": False,
    "app_launcher_visible": True,
    "policies": [
        {
            "name": "Allow Admin",
            "precedence": 1,
            "decision": "allow",
            "include": include_rules,
            "require": [],
            "exclude": []
        }
    ]
}

with open('/tmp/cf_access_app.json', 'w') as f:
    json.dump(app_config, f, indent=2)
print(f"Access app config built for: {emails}")
PYEOF

CREATE_RESP=$(curl -s -X POST \
  "${CF_API}/accounts/${ACCOUNT_ID}/access/apps" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d @/tmp/cf_access_app.json)

echo "$CREATE_RESP" | python3 -c "import sys,json; exit(0 if json.load(sys.stdin)['success'] else 1)" \
  || { echo "❌ Failed:"; echo "$CREATE_RESP" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('errors',[]), indent=2))"; exit 1; }

APP_ID=$(echo "$CREATE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['id'])")
echo "✅ Access Application created (${APP_ID})"

echo ""
echo "══════════════════════════════════════════════════════"
echo "✅ Cloudflare Zero Trust Access configured!"
echo ""
echo "   🛡️  URL: https://${HOSTNAME}"
echo "   👥  Allowed: ${ALLOWED_EMAILS}"
echo "   ⏱️  Session: ${SESSION_DURATION}"
echo ""
echo "   Flow: Browser → CF Access (email OTP) → Argo CD"
echo ""
echo "   Security layers:"
echo "   1. Cloudflare Tunnel (no inbound ports)"
echo "   2. Cloudflare WAF/DDoS"
echo "   3. Cloudflare Access Zero Trust (email OTP)"
echo "   4. Traefik security headers"
echo "   5. Argo CD RBAC"
echo "══════════════════════════════════════════════════════"
