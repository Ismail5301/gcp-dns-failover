#!/usr/bin/env bash
#
# Creates the Cloud DNS geolocation record (pins each region's traffic to its
# own regional LB under normal conditions) and, optionally, a per-region
# FAILOVER record pointing at a backup target outside GCP (on-prem/other
# cloud).
#
# This is a PUBLIC zone, so Cloud DNS uses health checks for external
# endpoints (GA since Feb 2025): a standalone health check that probes a
# plain IP:port directly over the internet, from three source regions you
# choose (three probers per region, nine total). This is a different
# mechanism from the forwarding-rule-reference health checking used for
# internal load balancers in private zones -- don't mix the two up.
#
# Usage:
#   ZONE=app-zone \
#   DOMAIN=app.example.com. \
#   EU_LB_IP=<ip from 01-create-regional-lb.sh, europe-west1 run> \
#   US_LB_IP=<ip from 01-create-regional-lb.sh, us-central1 run> \
#   ./02-create-dns-geo-failover-record.sh

set -euo pipefail

: "${ZONE:?Set ZONE, e.g. app-zone (your Cloud DNS managed zone name)}"
: "${DOMAIN:?Set DOMAIN, e.g. app.example.com. (include trailing dot)}"
: "${EU_LB_IP:?Set EU_LB_IP to the static IP from the europe-west1 LB run}"
: "${US_LB_IP:?Set US_LB_IP to the static IP from the us-central1 LB run}"

echo "==> Creating standalone external-endpoint health check (app-hc)"
echo "    Note: check-interval has a hard floor of 30s for this health"
echo "    check type -- you cannot configure faster detection than that."
gcloud beta compute health-checks create https app-hc \
  --global \
  --check-interval=30 \
  --source-regions=europe-west1,us-central1,us-east1 \
  --port=443 \
  --request-path=/healthz

echo "==> Creating geolocation record for ${DOMAIN}, geofenced"
gcloud dns record-sets create "${DOMAIN}" \
  --zone="${ZONE}" \
  --type=A \
  --ttl=30 \
  --routing-policy-type=GEO \
  --enable-geo-fencing \
  --routing-policy-item="location=europe-west1,rrdatas=${EU_LB_IP},external_endpoints=${EU_LB_IP}" \
  --routing-policy-item="location=us-central1,rrdatas=${US_LB_IP},external_endpoints=${US_LB_IP}" \
  --health-check=app-hc

echo "==> Done. To add a FAILOVER leg to a non-GCP backup for one region, run:"
cat <<'INNER_EOF'

BACKUP_IP=<on-prem or other-cloud public IP>

gcloud dns record-sets create eu.app.example.com. \
  --zone=${ZONE} \
  --type=A \
  --ttl=30 \
  --routing-policy-type=FAILOVER \
  --routing-policy-primary-data="${EU_LB_IP}" \
  --routing-policy-backup-data-type=GEO \
  --routing-policy-backup-item="location=europe-west1,rrdatas=${BACKUP_IP},external_endpoints=${BACKUP_IP}" \
  --backup-data-trickle-ratio=0 \
  --health-check=app-hc

# Same app-hc health check works unchanged -- Cloud DNS is just probing an
# IP:port over the public internet either way, GCP or not.
INNER_EOF
