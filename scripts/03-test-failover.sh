#!/usr/bin/env bash
#
# Simulates a regional outage by breaking the LB's own backend health check
# (so the regional LB itself starts returning errors), then watches the DNS
# answer until Cloud DNS's external-endpoint health check on that IP fails
# and the FAILOVER record flips to the backup. Restores the original config
# after -- via a trap, so restoration happens even if you Ctrl+C out of the
# watch loop early or the script errors partway through.
#
# Note: this exercises TWO health checks in sequence, on purpose --
# breaking the backend-service health check makes the regional LB stop
# serving traffic from its backends, which in turn makes Cloud DNS's
# external-endpoint HTTPS probe against that LB's public IP start failing.
# That second, outer health check (app-hc from
# 02-create-regional-failover-record.sh) is what actually drives the DNS
# failover -- expect this to take longer than a plain LB-level failover
# would (see the README's latency section).
#
# Usage:
#   REGION=europe-west1 \
#   BACKEND_SERVICE=app-region-eu-bs \
#   ORIGINAL_HEALTH_CHECK=app-region-eu-hc \
#   DOMAIN=eu.app.example.com \
#   BACKUP_IP=203.0.113.10 \
#   ./03-test-failover.sh
#
# BACKUP_IP is optional. If set, the watch loop exits as soon as dig
# returns that IP and the script reports pass/fail instead of just
# printing timestamps. If unset, it falls back to the old fixed-duration
# watch (36 x 5s) and you judge the output yourself.

set -euo pipefail

: "${REGION:?Set REGION, e.g. europe-west1}"
: "${BACKEND_SERVICE:?Set BACKEND_SERVICE, e.g. app-region-eu-bs}"
: "${ORIGINAL_HEALTH_CHECK:?Set ORIGINAL_HEALTH_CHECK, e.g. app-region-eu-hc}"
: "${DOMAIN:?Set DOMAIN, e.g. eu.app.example.com}"
BACKUP_IP="${BACKUP_IP:-}"

BROKEN_HC="${BACKEND_SERVICE}-broken-hc"

# --- cleanup -----------------------------------------------------------
# Runs on normal exit, Ctrl+C (INT), or TERM -- including if the script
# is interrupted partway through the watch loop below. Guarded with a
# flag so it can't run twice (e.g. once from the script's own end-of-file
# path and again from the EXIT trap).
CLEANED_UP=0
cleanup() {
  if [[ "${CLEANED_UP}" -eq 1 ]]; then
    return
  fi
  CLEANED_UP=1

  echo
  echo "==> Cleaning up (restoring original config)..."

  if gcloud compute backend-services describe "${BACKEND_SERVICE}" \
      --region="${REGION}" >/dev/null 2>&1; then
    echo "==> Restoring original health check (${ORIGINAL_HEALTH_CHECK}) on ${BACKEND_SERVICE}"
    gcloud compute backend-services update "${BACKEND_SERVICE}" \
      --region="${REGION}" \
      --health-checks="${ORIGINAL_HEALTH_CHECK}" || \
      echo "    WARNING: failed to restore original health check -- check manually."
  fi

  if gcloud compute health-checks describe "${BROKEN_HC}" \
      --region="${REGION}" >/dev/null 2>&1; then
    echo "==> Deleting throwaway health check (${BROKEN_HC})"
    gcloud compute health-checks delete "${BROKEN_HC}" \
      --region="${REGION}" \
      --quiet || \
      echo "    WARNING: failed to delete ${BROKEN_HC} -- check manually."
  fi

  echo "==> Cleanup complete."
}
trap cleanup EXIT INT TERM
# ------------------------------------------------------------------------

echo "==> Current DNS answer for ${DOMAIN}:"
dig +short "${DOMAIN}"

echo "==> Creating a throwaway health check that always fails (bad path,"
echo "    matching the HTTP/serving-port backend from 01-create-regional-lb.sh)"
gcloud compute health-checks create http "${BROKEN_HC}" \
  --region="${REGION}" \
  --use-serving-port \
  --request-path=/this-path-does-not-exist \
  --check-interval=5s \
  --unhealthy-threshold=2

echo "==> Pointing ${BACKEND_SERVICE} at the broken health check"
gcloud compute backend-services update "${BACKEND_SERVICE}" \
  --region="${REGION}" \
  --health-checks="${BROKEN_HC}"

echo "==> Watching DNS answer -- expect it to flip in roughly 90-120s"
echo "    (app-hc has a 30s minimum check interval, see the README's"
echo "     latency section for the full breakdown)"

FAILOVER_OBSERVED=0
if [[ -n "${BACKUP_IP}" ]]; then
  echo "    BACKUP_IP=${BACKUP_IP} set -- will exit as soon as it's seen"
  for i in $(seq 1 60); do
    sleep 5
    ANSWER="$(dig +short "${DOMAIN}")"
    echo "[$(date +%T)] ${ANSWER}"
    if [[ "${ANSWER}" == "${BACKUP_IP}" ]]; then
      FAILOVER_OBSERVED=1
      echo "==> PASS: DNS answer flipped to backup IP (${BACKUP_IP}) after $((i * 5))s"
      break
    fi
  done
  if [[ "${FAILOVER_OBSERVED}" -eq 0 ]]; then
    echo "==> FAIL: did not observe ${BACKUP_IP} within 300s"
  fi
else
  echo "    (BACKUP_IP not set -- printing for 3 minutes, judge the output yourself)"
  for i in $(seq 1 36); do
    sleep 5
    echo "[$(date +%T)] $(dig +short "${DOMAIN}")"
  done
fi

# cleanup() runs automatically here via the EXIT trap -- including if the
# script is interrupted (Ctrl+C) or errors out above.
echo "==> Test loop finished. Confirm DNS answer flips back once TTL expires:"

if [[ -n "${BACKUP_IP}" && "${FAILOVER_OBSERVED}" -eq 0 ]]; then
  exit 1
fi
