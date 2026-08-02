#!/usr/bin/env bash
# Generate deploy/.env from .env.example with fresh random secrets.
# Run this ON THE TARGET HOST. The resulting .env holds real secrets and is
# gitignored — never commit it. (CLJUMPSERV-7)
#
# Usage:
#   ./deploy/gen-env.sh            # create deploy/.env (refuses if it exists)
#   ./deploy/gen-env.sh --force    # overwrite an existing deploy/.env
set -eu

cd "$(dirname "$0")"

TEMPLATE=".env.example"
OUT=".env"
FORCE="${1:-}"

[ -f "$TEMPLATE" ] || { echo "ERROR: $TEMPLATE not found (run from repo root or deploy/)"; exit 1; }

if [ -f "$OUT" ] && [ "$FORCE" != "--force" ]; then
  echo "ERROR: $OUT already exists. Use --force to overwrite (regenerates ALL secrets)." >&2
  exit 1
fi

# random alphanumeric of length $1 (no pipefail: head closing the pipe is expected)
gen() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1"; }

SECRET_KEY="$(gen 48)"
BOOTSTRAP_TOKEN="$(gen 24)"
DB_PASSWORD="$(gen 24)"
REDIS_PASSWORD="$(gen 24)"

# Copy template, replacing only the secret placeholder lines. Comments and all
# other values (image tags, ports, TZ, ...) are preserved verbatim.
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    SECRET_KEY=*)      printf 'SECRET_KEY=%s\n'      "$SECRET_KEY" ;;
    BOOTSTRAP_TOKEN=*) printf 'BOOTSTRAP_TOKEN=%s\n' "$BOOTSTRAP_TOKEN" ;;
    DB_PASSWORD=*)     printf 'DB_PASSWORD=%s\n'     "$DB_PASSWORD" ;;
    REDIS_PASSWORD=*)  printf 'REDIS_PASSWORD=%s\n'  "$REDIS_PASSWORD" ;;
    *)                 printf '%s\n' "$line" ;;
  esac
done < "$TEMPLATE" > "$OUT"

chmod 600 "$OUT"

mask() { printf '%s' "$1" | sed -E 's/^(.{4}).*(.{2})$/\1…\2/'; }
echo "Wrote $OUT (chmod 600). Generated secrets (masked):"
echo "  SECRET_KEY=$(mask "$SECRET_KEY")  (48 chars)"
echo "  BOOTSTRAP_TOKEN=$(mask "$BOOTSTRAP_TOKEN")  (24)"
echo "  DB_PASSWORD=$(mask "$DB_PASSWORD")  (24)"
echo "  REDIS_PASSWORD=$(mask "$REDIS_PASSWORD")  (24)"
echo
echo "Next: review non-secret values in $OUT (image tags, TZ, ports), then:"
echo "  docker compose -f docker-compose.yml up -d"
