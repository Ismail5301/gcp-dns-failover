#!/usr/bin/env bash
#
# Creates a regional external HTTPS LB (static IP, health check, backend
# service, GKE NEG backend, managed cert, target proxy, forwarding rule)
# for a single region. Run once per region.
#
# Usage:
#   REGION=europe-west1 \
#   NAME=app-region-eu \
#   NEG_NAME=cluster-eu-neg \
#   ZONE=europe-west1-a \
#   DOMAIN=eu.app.example.com \
#   ./01-create-regional-lb.sh

set -euo pipefail

: "${REGION:?Set REGION, e.g. europe-west1}"
: "${NAME:?Set NAME, e.g. app-region-eu}"
: "${NEG_NAME:?Set NEG_NAME, e.g. cluster-eu-neg (the GKE-created NEG)}"
: "${ZONE:?Set ZONE, e.g. europe-west1-a}"
: "${DOMAIN:?Set DOMAIN, e.g. eu.app.example.com}"

echo "==> Reserving static IP (${NAME}-ip) in ${REGION}"
gcloud compute addresses create "${NAME}-ip" \
  --region="${REGION}"

echo "==> Creating health check (${NAME}-hc)"
gcloud compute health-checks create https "${NAME}-hc" \
  --region="${REGION}" \
  --port=443 \
  --request-path=/healthz \
  --check-interval=10s \
  --unhealthy-threshold=3

echo "==> Creating backend service (${NAME}-bs)"
gcloud compute backend-services create "${NAME}-bs" \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --protocol=HTTPS \
  --region="${REGION}" \
  --health-checks="${NAME}-hc"

echo "==> Attaching GKE NEG (${NEG_NAME}) as backend"
gcloud compute backend-services add-backend "${NAME}-bs" \
  --region="${REGION}" \
  --network-endpoint-group="${NEG_NAME}" \
  --network-endpoint-group-zone="${ZONE}" \
  --balancing-mode=RATE \
  --max-rate-per-endpoint=100

echo "==> Creating managed SSL cert for ${DOMAIN}"
gcloud compute ssl-certificates create "${NAME}-cert" \
  --region="${REGION}" \
  --domains="${DOMAIN}"

echo "==> Creating URL map (${NAME}-urlmap)"
gcloud compute url-maps create "${NAME}-urlmap" \
  --region="${REGION}" \
  --default-service="${NAME}-bs"

echo "==> Creating target HTTPS proxy (${NAME}-proxy)"
gcloud compute target-https-proxies create "${NAME}-proxy" \
  --region="${REGION}" \
  --url-map="${NAME}-urlmap" \
  --ssl-certificates="${NAME}-cert"

echo "==> Creating forwarding rule (${NAME}-fr)"
gcloud compute forwarding-rules create "${NAME}-fr" \
  --region="${REGION}" \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --address="${NAME}-ip" \
  --target-https-proxy="${NAME}-proxy" \
  --ports=443

echo "==> Done. Forwarding rule reference for DNS: ${NAME}-fr@${REGION}"
gcloud compute addresses describe "${NAME}-ip" --region="${REGION}" --format="value(address)"
