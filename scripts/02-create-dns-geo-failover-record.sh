#!/usr/bin/env bash
#
# Creates the Cloud DNS geolocation record (pins each region's traffic to its
# own regional LB under normal conditions) and, optionally, a per-region
# FAILOVER record pointing at a backup target outside GCP (on-prem/other
# cloud). Adjust the routing-policy-item list to match your regions.
#
# Usage:
#   ZONE=app-zone \
#   DOMAIN=app.example.com. \
#   ./02-create-dns-geo-failover-record.sh

set -euo pipefail

: "${ZONE:?Set ZONE, e.g. app-zone (your Cloud DNS managed zone name)}"
: "${DOMAIN:?Set DOMAIN, e.g. app.example.com. (include trailing dot)}"

echo "==> Creating geolocation + health-checked record for ${DOMAIN}"
gcloud dns record-sets create "${DOMAIN}" \
  --zone="${ZONE}" \
  --type=A \
  --ttl=30 \
  --routing-policy-type=GEO \
  --enable-geo-fencing \
  --routing-policy-item="europe-west1=app-region-eu-fr@europe-west1" \
  --routing-policy-item="us-central1=app-region-us-fr@us-central1" \
  --enable-health-checking

echo "==> Done. To add a FAILOVER leg to a non-GCP backup for one region, run:"
cat <<'INNER_EOF'

gcloud dns record-sets create eu.app.example.com. \
  --zone=${ZONE} \
  --type=A \
  --ttl=30 \
  --routing-policy-type=FAILOVER \
  --routing-policy-primary-data="app-region-eu-fr@europe-west1" \
  --routing-policy-backup-data-type=GEO \
  --routing-policy-backup-item="location=europe-west1,rrdatas=<BACKUP_IP>" \
  --enable-health-checking \
  --backup-data-trickle-ratio=0.0

# Note: <BACKUP_IP> (on-prem / other cloud) is not health-checked by Cloud
# DNS itself -- monitor it independently (see terraform/ roadmap item).
INNER_EOF
