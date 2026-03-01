#!/usr/bin/env bash
# =============================================================================
# setup-route.sh — Configure Cloudflare Tunnel route for argocd.kythuat.vn
# =============================================================================
#
# Usage:  CF_API_TOKEN="xxxxx" bash setup-route.sh
#
# Token permissions needed:
#   Zone > DNS > Edit  (kythuat.vn)
#   Account > Cloudflare Tunnel > Edit
# =============================================================================
set -euo pipefail

TUNNEL_ID="3d402a26-0f5f-48af-a110-690ceb1c0302"
ACCOUNT_ID="7bcb17f8406016e96db910de9b0c2253"
ZONE_NAME="kythuat.vn"
SUBDOMAIN="argocd"
HOSTNAME="${SUBDOMAIN}.${ZONE_NAME}"
SERVICE_URL="http://traefik.traefik.svc.cluster.local:80"
CF_API="https://api.cloudflare.com/client/v4"

trap 'rm -f /tmp/cf_*.json /tmp/cf_*.txt' EXIT

if [[ -z "${CF_API_TOKEN:-}" ]]; then
  echo "❌ CF_API_TOKEN not set. export CF_API_TOKEN='your-token'"
  exit 1
fi

echo "🔍 Verifying API token..."
TOKEN_RESP=$(curl -s "${CF_API}/user/tokens/verify" -H "Authorization: Bearer ${CF_API_TOKEN}")
echo "$TOKEN_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d['success'] else 1)" \
  || { echo "❌ Invalid token: $TOKEN_RESP"; exit 1; }
echo "✅ API Token valid"

echo "🔍 Getting Zone ID for ${ZONE_NAME}..."
ZONE_RESP=$(curl -s "${CF_API}/zones?name=${ZONE_NAME}" -H "Authorization: Bearer ${CF_API_TOKEN}")
ZONE_ID=$(echo "$ZONE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null)
[[ -z "$ZONE_ID" ]] && { echo "❌ Zone not found"; exit 1; }
echo "✅ Zone ID: ${ZONE_ID}"

echo ""
echo "📡 Configuring tunnel ingress for ${HOSTNAME}..."

# Get existing config (don't fail if empty)
curl -s "${CF_API}/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" -o /tmp/cf_existing.json || echo '{}' > /tmp/cf_existing.json

# Build new config using Python
echo "${HOSTNAME}" > /tmp/cf_hostname.txt
echo "${SERVICE_URL}" > /tmp/cf_service_url.txt

python3 << 'PYEOF'
import json

with open('/tmp/cf_existing.json') as f:
    data = json.load(f)

try:
    existing = data['result']['config']['ingress']
except (KeyError, TypeError):
    existing = []

hostname = open('/tmp/cf_hostname.txt').read().strip()
service_url = open('/tmp/cf_service_url.txt').read().strip()

filtered = [r for r in existing if r.get('hostname') and r.get('hostname') != hostname]

new_ingress = [
    {
        "hostname": hostname,
        "service": service_url,
        "originRequest": {
            "noTLSVerify": True,
            "httpHostHeader": hostname,
        }
    }
] + filtered + [{"service": "http_status:404"}]

with open('/tmp/cf_new_config.json', 'w') as f:
    json.dump({"config": {"ingress": new_ingress}}, f, indent=2)

print(f"Config ready. Routes: {[r.get('hostname','(catch-all)') for r in new_ingress]}")
PYEOF

UPDATE_RESP=$(curl -s -X PUT \
  "${CF_API}/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d @/tmp/cf_new_config.json)

echo "$UPDATE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d['success'] else 1)" \
  || { echo "❌ Tunnel config update failed:"; echo "$UPDATE_RESP" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('errors',[]), indent=2))"; exit 1; }
echo "✅ Tunnel ingress configured: ${HOSTNAME} → ${SERVICE_URL}"

echo ""
echo "🌐 Updating DNS for ${HOSTNAME}..."
TUNNEL_CNAME="${TUNNEL_ID}.cfargotunnel.com"

DNS_RESP=$(curl -s "${CF_API}/zones/${ZONE_ID}/dns_records?name=${HOSTNAME}" \
  -H "Authorization: Bearer ${CF_API_TOKEN}")

EXISTING_IDS=$(echo "$DNS_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for r in d.get('result', []):
    print(r['id'] + '|' + r['type'])
" 2>/dev/null || true)

while IFS='|' read -r rec_id rec_type; do
  [[ -z "$rec_id" ]] && continue
  echo "  🗑️  Deleting ${rec_type} record ${rec_id}..."
  curl -s -X DELETE "${CF_API}/zones/${ZONE_ID}/dns_records/${rec_id}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" > /dev/null
done <<< "$EXISTING_IDS"

CREATE_RESP=$(curl -s -X POST "${CF_API}/zones/${ZONE_ID}/dns_records" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"type\":\"CNAME\",\"name\":\"${SUBDOMAIN}\",\"content\":\"${TUNNEL_CNAME}\",\"proxied\":true,\"comment\":\"Cloudflare Tunnel → Traefik → Argo CD\"}")

echo "$CREATE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d['success'] else 1)" \
  || { echo "❌ DNS create failed:"; echo "$CREATE_RESP" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('errors',[]), indent=2))"; exit 1; }
echo "✅ DNS CNAME: ${HOSTNAME} → ${TUNNEL_CNAME} (proxied)"

echo ""
echo "⏳ Waiting 10s for DNS propagation..."
sleep 10
echo "🔍 DNS check:"
dig +short "${HOSTNAME}" || true

echo ""
echo "══════════════════════════════════════════════"
echo "✅ Done! Argo CD available at:"
echo "   https://${HOSTNAME}"
echo ""
echo "Add Zero Trust auth (recommended):"
echo "   CF_API_TOKEN='...' bash setup-access-policy.sh"
echo "══════════════════════════════════════════════"
