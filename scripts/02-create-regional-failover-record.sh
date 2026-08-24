#!/usr/bin/env bash
#
# Creates a Cloud DNS FAILOVER record for ONE region: primary is that
# region's own regional external HTTPS LB (referenced by forwarding rule,
# so Cloud DNS reads its health natively), backup is a raw external IP
# (on-prem or another cloud), health-checked directly via the
# external-endpoint health check created below.
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
#   PRIMARY_FORWARDING_RULE=app-region-eu-fr \
#   BACKUP_IP=203.0.113.10 \
#   ./02-create-regional-failover-record.sh

set -euo pipefail

: "${ZONE:?Set ZONE, e.g. app-zone (your Cloud DNS managed zone name)}"
: "${DOMAIN:?Set DOMAIN, e.g. eu.app.example.com. (include trailing dot)}"
: "${REGION:?Set REGION, e.g. europe-west1}"
: "${PRIMARY_FORWARDING_RULE:?Set PRIMARY_FORWARDING_RULE, e.g. app-region-eu-fr (from 01-create-regional-lb.sh)}"
: "${BACKUP_IP:?Set BACKUP_IP, the on-prem or other-cloud public IP}"

echo "==> Creating external-endpoint health check (app-hc), if it doesn't"
echo "    already exist. Note: check-interval has a hard floor of 30s for"
echo "    this health check type -- you cannot configure faster detection."
echo "    This is still a 'gcloud beta' command as of this writing."
if ! gcloud compute health-checks describe app-hc --global >/dev/null 2>&1; then
  gcloud beta compute health-checks create https app-hc \
    --global \
    --check-interval=30 \
    --source-regions=europe-west1,us-central1,us-east1 \
    --port=443 \
    --request-path=/healthz
else
  echo "    app-hc already exists, reusing it."
fi

echo "==> Creating FAILOVER record for ${DOMAIN}"
echo "    primary: ${PRIMARY_FORWARDING_RULE}@${REGION} (forwarding rule --"
echo "    Cloud DNS reads this LB's own health state directly)"
echo "    backup: ${BACKUP_IP} (external endpoint -- health-checked by app-hc"
echo "    over the public internet, same as the primary would be if it were"
echo "    also a raw IP)"
gcloud dns record-sets create "${DOMAIN}" \
  --zone="${ZONE}" \
  --type=A \
  --ttl=30 \
  --routing-policy-type=FAILOVER \
  --routing-policy-primary-data="${PRIMARY_FORWARDING_RULE}@${REGION}" \
  --routing-policy-backup-data-type=GEO \
  --routing-policy-backup-item="location=${REGION},rrdatas=${BACKUP_IP},external_endpoints=${BACKUP_IP}" \
  --backup-data-trickle-ratio=0 \
  --health-check=app-hc

echo "==> Done. Repeat this script for each additional region's hostname."
