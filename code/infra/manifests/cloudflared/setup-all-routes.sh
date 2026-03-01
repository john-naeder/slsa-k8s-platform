#!/usr/bin/env bash
# =============================================================================
# setup-all-routes.sh — Configure ALL Cloudflare Tunnel routes
# =============================================================================
#
# Configures cloudflared tunnel to route:
#   - demo.kythuat.vn    → Traefik → demo-api (HTTP API)
#   - tekton.kythuat.vn  → Traefik → Tekton EventListener (GitHub webhook)
#   - argocd.kythuat.vn  → Traefik → ArgoCD Server (dashboard)
#   - harbor.kythuat.vn  → Traefik → Harbor (registry — external access)
#
# Usage:
#   CF_API_TOKEN="your-token" bash setup-all-routes.sh
#
# Token permissions:
#   Zone > DNS > Edit  (kythuat.vn)
#   Account > Cloudflare Tunnel > Edit
# =============================================================================
set -euo pipefail

TUNNEL_ID="3d402a26-0f5f-48af-a110-690ceb1c0302"
ACCOUNT_ID="7bcb17f8406016e96db910de9b0c2253"
ZONE_NAME="kythuat.vn"
SERVICE_URL="http://traefik.traefik.svc.cluster.local:80"
CF_API="https://api.cloudflare.com/client/v4"

# ── All subdomains to route ──
SUBDOMAINS=("demo" "tekton" "argocd" "harbor")

trap 'rm -f /tmp/cf_*.json /tmp/cf_*.txt' EXIT

if [[ -z "${CF_API_TOKEN:-}" ]]; then
  echo "❌ CF_API_TOKEN not set. export CF_API_TOKEN='your-token'"
  exit 1
fi

echo "══════════════════════════════════════════════"
echo "  Cloudflare Tunnel — All Routes Setup"
echo "══════════════════════════════════════════════"

# ── Verify token ──
echo "🔍 Verifying API token..."
TOKEN_RESP=$(curl -s "${CF_API}/user/tokens/verify" -H "Authorization: Bearer ${CF_API_TOKEN}")
echo "$TOKEN_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d['success'] else 1)" \
  || { echo "❌ Invalid token: $TOKEN_RESP"; exit 1; }
echo "✅ API Token valid"

# ── Get Zone ID ──
echo "🔍 Getting Zone ID for ${ZONE_NAME}..."
ZONE_RESP=$(curl -s "${CF_API}/zones?name=${ZONE_NAME}" -H "Authorization: Bearer ${CF_API_TOKEN}")
ZONE_ID=$(echo "$ZONE_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['result'][0]['id'])" 2>/dev/null)
[[ -z "$ZONE_ID" ]] && { echo "❌ Zone not found"; exit 1; }
echo "✅ Zone ID: ${ZONE_ID}"

# ── Build tunnel ingress config ──
echo ""
echo "📡 Configuring tunnel ingress for all routes..."

# Get existing config
curl -s "${CF_API}/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" -o /tmp/cf_existing.json || echo '{}' > /tmp/cf_existing.json

# Build subdomain list for Python
printf '%s\n' "${SUBDOMAINS[@]}" > /tmp/cf_subdomains.txt

python3 << 'PYEOF'
import json

with open('/tmp/cf_existing.json') as f:
    data = json.load(f)

try:
    existing = data['result']['config']['ingress']
except (KeyError, TypeError):
    existing = []

zone = "kythuat.vn"
service_url = "http://traefik.traefik.svc.cluster.local:80"

with open('/tmp/cf_subdomains.txt') as f:
    subdomains = [s.strip() for s in f if s.strip()]

# Remove existing entries for our subdomains + catch-all
our_hostnames = set(f"{s}.{zone}" for s in subdomains)
filtered = [r for r in existing if r.get('hostname') and r['hostname'] not in our_hostnames]

# Build new ingress rules
new_rules = []
for sub in subdomains:
    hostname = f"{sub}.{zone}"
    new_rules.append({
        "hostname": hostname,
        "service": service_url,
        "originRequest": {
            "noTLSVerify": True,
            "httpHostHeader": hostname,
        }
    })

new_ingress = new_rules + filtered + [{"service": "http_status:404"}]

with open('/tmp/cf_new_config.json', 'w') as f:
    json.dump({"config": {"ingress": new_ingress}}, f, indent=2)

print(f"  Routes: {[r.get('hostname','(catch-all)') for r in new_ingress]}")
PYEOF

# ── Update tunnel config ──
UPDATE_RESP=$(curl -s -X PUT \
  "${CF_API}/accounts/${ACCOUNT_ID}/cfd_tunnel/${TUNNEL_ID}/configurations" \
  -H "Authorization: Bearer ${CF_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d @/tmp/cf_new_config.json)

echo "$UPDATE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d['success'] else 1)" \
  || { echo "❌ Tunnel config update failed:"; echo "$UPDATE_RESP" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin).get('errors',[]), indent=2))"; exit 1; }
echo "✅ Tunnel ingress configured"

# ── Create/Update DNS records ──
echo ""
echo "🌐 Updating DNS records..."
TUNNEL_CNAME="${TUNNEL_ID}.cfargotunnel.com"

for SUB in "${SUBDOMAINS[@]}"; do
  HOSTNAME="${SUB}.${ZONE_NAME}"
  echo "  📌 ${HOSTNAME}..."

  # Delete existing records
  DNS_RESP=$(curl -s "${CF_API}/zones/${ZONE_ID}/dns_records?name=${HOSTNAME}" \
    -H "Authorization: Bearer ${CF_API_TOKEN}")

  EXISTING_IDS=$(echo "$DNS_RESP" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for r in d.get('result', []):
    print(r['id'])
" 2>/dev/null || true)

  while IFS= read -r rec_id; do
    [[ -z "$rec_id" ]] && continue
    curl -s -X DELETE "${CF_API}/zones/${ZONE_ID}/dns_records/${rec_id}" \
      -H "Authorization: Bearer ${CF_API_TOKEN}" > /dev/null
  done <<< "$EXISTING_IDS"

  # Create CNAME
  CREATE_RESP=$(curl -s -X POST "${CF_API}/zones/${ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${CF_API_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"CNAME\",\"name\":\"${SUB}\",\"content\":\"${TUNNEL_CNAME}\",\"proxied\":true,\"comment\":\"Cloudflare Tunnel → Traefik\"}")

  echo "$CREATE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); exit(0 if d['success'] else 1)" \
    && echo "     ✅ CNAME: ${HOSTNAME} → ${TUNNEL_CNAME}" \
    || echo "     ❌ Failed to create DNS for ${HOSTNAME}"
done

echo ""
echo "══════════════════════════════════════════════"
echo "  ✅ All routes configured!"
echo ""
echo "  Services available at:"
for SUB in "${SUBDOMAINS[@]}"; do
  echo "    https://${SUB}.${ZONE_NAME}"
done
echo ""
echo "  ⏳ DNS propagation may take up to 5 minutes."
echo "══════════════════════════════════════════════"
