#!/usr/bin/env bash
# Back up JumpServer: PostgreSQL dump + .env + core_data (media/recordings) +
# caddy_data (TLS certs). Produces one timestamped tarball and prunes old ones.
# Redis is cache/session only (rebuildable) and is intentionally NOT backed up.
# Run on the target host, e.g. from cron. (CLJUMPSERV-13)
#
# Usage:
#   ./deploy/backup.sh [BACKUP_DIR] [RETENTION_DAYS]
# Defaults: BACKUP_DIR=./backups  RETENTION_DAYS=14
set -euo pipefail

cd "$(dirname "$0")"
COMPOSE="docker compose -f docker-compose.yml"
BACKUP_DIR="${1:-./backups}"
RETENTION_DAYS="${2:-14}"

[ -f .env ] || { echo "ERROR: .env missing"; exit 1; }
# shellcheck disable=SC1091
set -a; . ./.env; set +a

stamp="$(date +%Y%m%d-%H%M%S)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$BACKUP_DIR"

echo ">> [1/4] pg_dump ($DB_NAME)"
$COMPOSE exec -T -e PGPASSWORD="$DB_PASSWORD" postgresql \
  pg_dump -U "$DB_USER" "$DB_NAME" | gzip > "$work/db.sql.gz"

echo ">> [2/4] .env"
cp .env "$work/env.bak"

echo ">> [3/4] core_data (media/recordings) + caddy_data (certs)"
# --volumes-from mounts the container's volumes at their in-container paths,
# so we don't need to resolve project-prefixed volume names.
docker run --rm --volumes-from jms_core -v "$work":/backup alpine \
  tar czf /backup/core_data.tgz -C /opt/jumpserver/data . 2>/dev/null \
  || echo "   WARN: could not archive core_data (is jms_core running?)"
docker run --rm --volumes-from jms_caddy -v "$work":/backup alpine \
  tar czf /backup/caddy_data.tgz -C /data . 2>/dev/null \
  || echo "   WARN: could not archive caddy_data (is jms_caddy running?)"

echo ">> [4/4] bundle"
cat > "$work/MANIFEST.txt" <<EOF
JumpServer backup $stamp
db.sql.gz     - PostgreSQL dump ($DB_NAME)
env.bak       - deploy/.env (SECRETS — keep this backup private)
core_data.tgz - media, session recordings, static, ansible
caddy_data.tgz- Let's Encrypt certs & ACME account
EOF
out="$BACKUP_DIR/jumpserver-backup-$stamp.tar.gz"
tar czf "$out" -C "$work" .
chmod 600 "$out"

echo ">> pruning backups older than ${RETENTION_DAYS}d in $BACKUP_DIR"
find "$BACKUP_DIR" -maxdepth 1 -name 'jumpserver-backup-*.tar.gz' -mtime "+${RETENTION_DAYS}" -print -delete || true

echo ">> done: $out ($(du -h "$out" | cut -f1))"
echo "   NOTE: this file contains secrets — store it off-host and access-controlled."
