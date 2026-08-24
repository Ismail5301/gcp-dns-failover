#!/usr/bin/env bash
#
# Simulates a regional outage by breaking the LB's own backend health check
# (so the regional LB itself starts returning errors), then watches the DNS
# answer until Cloud DNS's external-endpoint health check on that IP fails
# and the record flips to the backup. Restores the original config after.
#
# Note: this exercises TWO health checks in sequence, on purpose --
# breaking the backend-service health check makes the regional LB stop
# serving traffic from its backends, which in turn makes Cloud DNS's
# external-endpoint HTTPS probe against that LB's public IP start failing.
# That second, outer health check (app-hc from
# 02-create-dns-geo-failover-record.sh) is what actually drives the DNS
# failover -- expect this to take longer than a plain LB-level failover
# would, per the latency section in the README.
#
# Usage:
#   REGION=europe-west1 \
#   BACKEND_SERVICE=app-region-eu-bs \
#   ORIGINAL_HEALTH_CHECK=app-region-eu-hc \
#   DOMAIN=eu.app.example.com \
#   ./03-test-failover.sh

set -euo pipefail

: "${REGION:?Set REGION, e.g. europe-west1}"
: "${BACKEND_SERVICE:?Set BACKEND_SERVICE, e.g. app-region-eu-bs}"
: "${ORIGINAL_HEALTH_CHECK:?Set ORIGINAL_HEALTH_CHECK, e.g. app-region-eu-hc}"
: "${DOMAIN:?Set DOMAIN, e.g. eu.app.example.com}"

echo "==> Current DNS answer for ${DOMAIN}:"
dig +short "${DOMAIN}"

echo "==> Creating a throwaway health check that always fails (404 path)"
gcloud compute health-checks create https "${BACKEND_SERVICE}-broken-hc" \
  --region="${REGION}" \
  --port=443 \
  --request-path=/this-path-does-not-exist \
  --check-interval=5s \
  --unhealthy-threshold=2

echo "==> Pointing ${BACKEND_SERVICE} at the broken health check"
gcloud compute backend-services update "${BACKEND_SERVICE}" \
  --region="${REGION}" \
  --health-checks="${BACKEND_SERVICE}-broken-hc"

echo "==> Watching DNS answer -- expect it to flip in roughly 90-120s"
echo "    (the app-hc external-endpoint check has a 30s minimum interval,"
echo "     see the README's latency section for the full breakdown)"
echo "    (Ctrl+C once you see the backup IP)"
for i in $(seq 1 36); do
  sleep 5
  echo "[$(date +%T)] $(dig +short "${DOMAIN}")"
done

echo "==> Restoring original health check (${ORIGINAL_HEALTH_CHECK})"
gcloud compute backend-services update "${BACKEND_SERVICE}" \
  --region="${REGION}" \
  --health-checks="${ORIGINAL_HEALTH_CHECK}"

echo "==> Cleaning up throwaway health check"
gcloud compute health-checks delete "${BACKEND_SERVICE}-broken-hc" \
  --region="${REGION}" \
  --quiet

echo "==> Test complete. Confirm DNS answer flips back once TTL expires:"
dig +short "${DOMAIN}"
