#!/usr/bin/env bash
# Restore a JumpServer backup produced by backup.sh. DESTRUCTIVE — it overwrites
# the current database and volume contents. Run on the target host. (CLJUMPSERV-13)
#
# Usage:
#   ./deploy/restore.sh <jumpserver-backup-YYYYmmdd-HHMMSS.tar.gz> --yes
set -euo pipefail

cd "$(dirname "$0")"
COMPOSE="docker compose -f docker-compose.yml"
ARCHIVE="${1:-}"
CONFIRM="${2:-}"

[ -f "$ARCHIVE" ] || { echo "ERROR: backup archive not found: $ARCHIVE"; exit 1; }
if [ "$CONFIRM" != "--yes" ]; then
  echo "This will OVERWRITE the database, recordings and TLS certs from:"
  echo "  $ARCHIVE"
  echo "Re-run with --yes to proceed:  ./deploy/restore.sh $ARCHIVE --yes"
  exit 1
fi
[ -f .env ] || { echo "ERROR: .env missing (restore env.bak from the archive first if needed)"; exit 1; }
# shellcheck disable=SC1091
set -a; . ./.env; set +a

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
tar xzf "$ARCHIVE" -C "$work"

echo ">> ensuring data stores are up"
$COMPOSE up -d postgresql redis
sleep 5

echo ">> restoring PostgreSQL ($DB_NAME) — dropping & recreating schema"
$COMPOSE exec -T -e PGPASSWORD="$DB_PASSWORD" postgresql \
  psql -U "$DB_USER" -d "$DB_NAME" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
gunzip -c "$work/db.sql.gz" | $COMPOSE exec -T -e PGPASSWORD="$DB_PASSWORD" postgresql \
  psql -U "$DB_USER" -d "$DB_NAME"

echo ">> restoring core_data + caddy_data volumes"
$COMPOSE up -d core caddy >/dev/null 2>&1 || true
sleep 3
docker run --rm --volumes-from jms_core -v "$work":/backup alpine \
  sh -c 'rm -rf /opt/jumpserver/data/* && tar xzf /backup/core_data.tgz -C /opt/jumpserver/data'
docker run --rm --volumes-from jms_caddy -v "$work":/backup alpine \
  sh -c 'rm -rf /data/* && tar xzf /backup/caddy_data.tgz -C /data'

echo ">> restarting stack"
$COMPOSE up -d
echo ">> done. Verify login and that terminal components are online (CLJUMPSERV-12)."
echo "   NOTE: env.bak is in the archive but NOT auto-applied — diff it against .env if needed."
