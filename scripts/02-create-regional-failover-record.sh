#!/usr/bin/env bash
#
# Creates a Cloud DNS FAILOVER record for ONE region in a PUBLIC zone.
#
# Health data source is Mechanism 2 (external-endpoint probes), not
# Mechanism 1 (native LB control-plane health). Those two are mutually
# exclusive flags: --health-check vs --enable-health-checking.
#
# Primary is this region's regional external HTTPS LB. gcloud accepts a
# forwarding-rule reference here and resolves it to the VIP; Cloud DNS
# then probes that VIP over the public internet with the standalone
# health check created below. It does NOT read the LB's backend
# health signal -- that's a private-zone-only mechanism (see the
# README's "How failover actually behaves" section). Backup is a raw
# public IP, probed the same way.
#
# The health check is created ONE PER REGION (${NAME}-dns-hc), not as a
# single shared global check. Reason: the check's --host flag can only
# hold one value, and each region's domain is different
# (eu.app.example.com vs us.app.example.com) -- a shared check would
# have to send an arbitrary Host header for at least one of them.
#
# Run this once per region -- e.g. once for eu.app.example.com, once for
# us.app.example.com. There is deliberately no single top-level
# "app.example.com" record combining both regions: Cloud DNS's GEO routing
# policy and its FAILOVER routing policy are separate policy types that
# cannot be nested (a GEO entry cannot itself own an independent FAILOVER
# policy). If you want a single entry point that sends EU/US clients to the
# right regional hostname, that has to happen upstream of Cloud DNS (in the
# client/SDK config, or via a GEO record that points each location's rrdata
# at the regional hostname's current IP) -- see the README and Roadmap.
#
# Usage:
#   ZONE=app-zone \
#   DOMAIN=eu.app.example.com. \
#   REGION=europe-west1 \
#   NAME=app-region-eu \
#   PRIMARY_FORWARDING_RULE=app-region-eu-fr \
#   BACKUP_IP=203.0.113.10 \
#   ./02-create-regional-failover-record.sh

set -euo pipefail

: "${ZONE:?Set ZONE, e.g. app-zone (your Cloud DNS managed zone name)}"
: "${DOMAIN:?Set DOMAIN, e.g. eu.app.example.com. (include trailing dot)}"
: "${REGION:?Set REGION, e.g. europe-west1}"
: "${NAME:?Set NAME, e.g. app-region-eu (same NAME used in 01-create-regional-lb.sh)}"
: "${PRIMARY_FORWARDING_RULE:?Set PRIMARY_FORWARDING_RULE, e.g. app-region-eu-fr (from 01-create-regional-lb.sh)}"
: "${BACKUP_IP:?Set BACKUP_IP, the on-prem or other-cloud public IP}"

HEALTH_CHECK_NAME="${NAME}-dns-hc"
HEALTH_CHECK_HOST="${DOMAIN%.}"

echo "==> Creating external-endpoint health check (${HEALTH_CHECK_NAME}), if"
echo "    it doesn't already exist. Note: check-interval has a hard floor of"
echo "    30s for this health check type -- you cannot configure faster"
echo "    detection. This is still a 'gcloud beta' command as of this writing."
if ! gcloud compute health-checks describe "${HEALTH_CHECK_NAME}" --global >/dev/null 2>&1; then
  gcloud beta compute health-checks create https "${HEALTH_CHECK_NAME}" \
    --global \
    --check-interval=30 \
    --source-regions=europe-west1,us-central1,us-east1 \
    --port=443 \
    --host="${HEALTH_CHECK_HOST}" \
    --request-path=/healthz
else
  echo "    ${HEALTH_CHECK_NAME} already exists, reusing it."
fi

echo "==> Creating FAILOVER record for ${DOMAIN}"
echo "    primary: ${PRIMARY_FORWARDING_RULE}@${REGION}"
echo "             (forwarding-rule name -> VIP; public-zone probes hit that IP)"
echo "    backup:  ${BACKUP_IP}"
echo "             (external endpoint, same health check, same probe path)"
echo "    health:  ${HEALTH_CHECK_NAME} (HTTPS :443 Host=${HEALTH_CHECK_HOST} GET /healthz, 3 source regions)"
gcloud dns record-sets create "${DOMAIN}" \
  --zone="${ZONE}" \
  --type=A \
  --ttl=30 \
  --routing-policy-type=FAILOVER \
  --routing-policy-primary-data="${PRIMARY_FORWARDING_RULE}@${REGION}" \
  --routing-policy-backup-data-type=GEO \
  --routing-policy-backup-item="location=${REGION},rrdatas=${BACKUP_IP},external_endpoints=${BACKUP_IP}" \
  --backup-data-trickle-ratio=0 \
  --health-check="${HEALTH_CHECK_NAME}"

echo "==> Done. Repeat this script for each additional region's hostname."
echo "    Remember: the non-GCP backup at ${BACKUP_IP} must accept HTTPS on"
echo "    :443 at /healthz from ANY source IP -- Cloud DNS's external-endpoint"
echo "    probes don't originate from the fixed 35.191.0.0/16 / 130.211.0.0/22"
echo "    ranges GCP load balancers use for backend health checks. See the"
echo "    README's Known limitations section."
