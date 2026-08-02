#!/usr/bin/env bash
# Lightweight health/disk monitor for the JumpServer stack. Suitable for cron.
# Reports (and optionally alerts via webhook) on:
#   - any container not running / not healthy
#   - host disk usage above a threshold (session recordings grow over time)
# Exits non-zero if any problem is found (so cron/monitoring can catch it).
#
# Optional env:
#   DISK_THRESHOLD   percent, default 85
#   ALERT_WEBHOOK    URL to POST {"text": "..."} on problems (Slack/Discord/…)
#
# Usage:  ./deploy/monitor.sh
set -uo pipefail

cd "$(dirname "$0")"
COMPOSE="docker compose -f docker-compose.yml"
DISK_THRESHOLD="${DISK_THRESHOLD:-85}"
problems=()

# ---- container health ----
# expected services from the compose file
services="$($COMPOSE config --services 2>/dev/null)"
for svc in $services; do
  cid="$($COMPOSE ps -q "$svc" 2>/dev/null)"
  if [ -z "$cid" ]; then
    problems+=("service '$svc' has no container (not started)")
    continue
  fi
  state="$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null || echo unknown)"
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null || echo unknown)"
  if [ "$state" != "running" ]; then
    problems+=("container '$svc' state=$state")
  elif [ "$health" = "unhealthy" ]; then
    problems+=("container '$svc' health=unhealthy")
  fi
done

# ---- disk usage (filesystem holding docker data) ----
docker_root="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
use_pct="$(df -P "$docker_root" 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')"
if [ -n "${use_pct:-}" ] && [ "$use_pct" -ge "$DISK_THRESHOLD" ]; then
  problems+=("disk at ${use_pct}% on $docker_root (threshold ${DISK_THRESHOLD}%)")
fi

# ---- report ----
ts="$(date '+%Y-%m-%d %H:%M:%S')"
if [ "${#problems[@]}" -eq 0 ]; then
  echo "[$ts] OK — all containers healthy, disk ${use_pct:-?}% on $docker_root"
  exit 0
fi

msg="[$ts] JumpServer monitor found ${#problems[@]} problem(s):"
for p in "${problems[@]}"; do msg="$msg"$'\n'"  - $p"; done
echo "$msg" >&2

if [ -n "${ALERT_WEBHOOK:-}" ]; then
  payload="$(printf '%s' "$msg" | python3 -c 'import json,sys; print(json.dumps({"text": sys.stdin.read()}))')"
  curl -fsS -X POST -H 'Content-Type: application/json' -d "$payload" "$ALERT_WEBHOOK" >/dev/null \
    && echo "(alert sent to webhook)" >&2 || echo "(WARN: webhook POST failed)" >&2
fi
exit 1
