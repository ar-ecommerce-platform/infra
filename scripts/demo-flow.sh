#!/usr/bin/env bash
# End-to-end demo through the API gateway. Needs curl + python3.
#   bash infra/scripts/demo-flow.sh [base-url]
set -euo pipefail
BASE="${1:-http://localhost:8080}"
EMAIL="demo+$RANDOM@example.com"
PW="Passw0rd!"

j() { python3 -c "import sys,json;d=json.load(sys.stdin);print(d$1)"; }
step() { printf '\n=== %s ===\n' "$1"; }

step "Wait for the gateway to route (lb:// routes activate after the first Eureka fetch)"
ready=""
for i in $(seq 1 40); do
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/auth/register" \
    -H 'Content-Type: application/json' -d "{\"email\":\"probe-$i@example.com\",\"password\":\"Passw0rd!\"}")
  # 201 -> routed + permitAll working ; 409 -> route works, email taken
  if [ "$code" = "201" ] || [ "$code" = "409" ]; then ready=1; break; fi
  sleep 2
done
[ -n "$ready" ] || { echo "gateway not routing to auth-service after 80s"; exit 1; }
echo "gateway ready"

step "Register $EMAIL"
curl -fsS -X POST "$BASE/api/auth/register" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\"}" >/dev/null && echo registered

step "Login"
TOKEN=$(curl -fsS -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PW\"}" | j "['token']")
AUTH="Authorization: Bearer $TOKEN"
echo "token acquired"

step "Browse products"
PRODUCTS=$(curl -fsS "$BASE/api/products" -H "$AUTH"); echo "$PRODUCTS"
P1=$(echo "$PRODUCTS" | j "[0]['id']")
P2=$(echo "$PRODUCTS" | j "[1]['id']")

step "Inventory for product $P1"
curl -fsS "$BASE/api/inventory/$P1" -H "$AUTH"; echo

step "Place order (2x $P1, 1x $P2)"
ORDER=$(curl -fsS -X POST "$BASE/api/orders" -H "$AUTH" -H 'Content-Type: application/json' \
  -d "{\"userId\":\"$EMAIL\",\"items\":[{\"productId\":$P1,\"quantity\":2},{\"productId\":$P2,\"quantity\":1}]}")
echo "$ORDER"
STATUS=$(echo "$ORDER" | j "['status']")
[ "$STATUS" = "CONFIRMED" ] || { echo "expected CONFIRMED, got $STATUS"; exit 1; }
PAYMENT_ID=$(echo "$ORDER" | j "['paymentId']")

step "Payment $PAYMENT_ID"
curl -fsS "$BASE/api/payments/$PAYMENT_ID" -H "$AUTH"; echo

step "Notifications for $EMAIL"
curl -fsS -G "$BASE/api/notifications" --data-urlencode "userId=$EMAIL" -H "$AUTH"; echo

step "Orders for $EMAIL"
curl -fsS -G "$BASE/api/orders" --data-urlencode "userId=$EMAIL" -H "$AUTH"; echo

step "Failure: no token -> 401"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/orders" \
  -H 'Content-Type: application/json' \
  -d "{\"userId\":\"$EMAIL\",\"items\":[{\"productId\":$P1,\"quantity\":1}]}")
echo "got $code"; [ "$code" = "401" ] || exit 1

step "Failure: over-stock -> 409"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/orders" -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d "{\"userId\":\"$EMAIL\",\"items\":[{\"productId\":5,\"quantity\":9999}]}")
echo "got $code"; [ "$code" = "409" ] || exit 1

step "Failure: over payment ceiling -> 402"
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/orders" -H "$AUTH" \
  -H 'Content-Type: application/json' \
  -d "{\"userId\":\"$EMAIL\",\"items\":[{\"productId\":$P1,\"quantity\":5}]}")
echo "got $code"; [ "$code" = "402" ] || exit 1

printf '\nAll demo steps passed.\n'
