#!/usr/bin/env bash
# Bring up the JumpServer stack: pull -> up -d -> wait for core healthy.
# DB migrate runs automatically inside core on first boot (jms start web ->
# prepare() -> upgrade_db()), and a default admin is seeded by a data migration.
# Run this ON THE TARGET HOST after ./gen-env.sh. (CLJUMPSERV-10)
set -euo pipefail

cd "$(dirname "$0")"
COMPOSE="docker compose -f docker-compose.yml"

# ---- preflight ----
command -v docker >/dev/null || { echo "ERROR: docker not installed (CLJUMPSERV-2)"; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "ERROR: 'docker compose' plugin not available"; exit 1; }
[ -f .env ] || { echo "ERROR: .env missing — run ./gen-env.sh first (CLJUMPSERV-7)"; exit 1; }
grep -q 'CHANGE_ME' .env && { echo "ERROR: .env still has CHANGE_ME placeholders — run ./gen-env.sh"; exit 1; }
grep -q 'example.com' .env && { echo "ERROR: set a real DOMAIN / TLS_EMAIL in .env (still example.com)"; exit 1; }

# shellcheck disable=SC1091
set -a; . ./.env; set +a

echo ">> Pulling images..."
$COMPOSE pull

echo ">> Starting stack..."
$COMPOSE up -d

# ---- wait for core to become healthy (first boot runs migrate + downloads) ----
echo ">> Waiting for core to become healthy (first boot runs DB migrate, up to ~10 min)..."
deadline=$(( $(date +%s) + 600 ))
while :; do
  status="$(docker inspect -f '{{.State.Health.Status}}' jms_core 2>/dev/null || echo missing)"
  case "$status" in
    healthy) echo ">> core is healthy."; break ;;
    missing) echo "ERROR: jms_core container not found"; $COMPOSE ps; exit 1 ;;
  esac
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "ERROR: core did not become healthy in time. Recent logs:"
    $COMPOSE logs --tail=40 core
    exit 1
  fi
  sleep 5
done

echo ""
$COMPOSE ps
echo ""
echo "=================================================================="
echo " JumpServer is up."
echo "   URL   : https://${DOMAIN}/   (Caddy auto-provisions the TLS cert on first hit)"
echo "   Login : admin / ChangeMe   <-- CHANGE THIS PASSWORD IMMEDIATELY"
echo "   TLS   : ensure DNS for ${DOMAIN} points here and ports 80+443 are open."
echo ""
echo " Verify terminal components registered (koko/lion/magnus/chen should"
echo " appear online under 系統設定 > 終端機, or via CLJUMPSERV-12 smoke test)."
echo ""
echo " Reset admin password if needed:"
echo "   $COMPOSE exec core bash -lc 'cd apps && python manage.py changepassword admin'"
echo "=================================================================="
