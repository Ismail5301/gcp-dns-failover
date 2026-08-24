#!/usr/bin/env bash
#
# Creates a regional external Application Load Balancer for one region:
# proxy-only subnet, firewall rule for health check/proxy traffic, static IP,
# regional health check, backend service, GKE NEG backend, self-managed SSL
# cert, URL map, target proxy, forwarding rule.
#
# IMPORTANT: this targets the sample-app.yaml in ../manifests, which serves
# plain HTTP on container port 8080. The backend service and its health
# check are HTTP against that port -- TLS is terminated at the LB, not the
# pod. If your own app serves HTTPS on the pod, change --protocol to HTTPS
# and the health check protocol/port to match.
#
# Regional external Application LBs do NOT support Compute Engine
# Google-managed SSL certs -- only self-managed certs (or Certificate
# Manager). You need a cert/key pair on disk before running this.
#
# Usage:
#   REGION=europe-west1 \
#   NAME=app-region-eu \
#   NEG_NAME=cluster-eu-neg \
#   ZONE=europe-west1-a \
#   NETWORK=default \
#   BACKEND_SUBNET=default \
#   PROXY_SUBNET_RANGE=10.129.0.0/23 \
#   CERT_FILE=./eu-cert.pem \
#   KEY_FILE=./eu-key.pem \
#   ./01-create-regional-lb.sh

set -euo pipefail

: "${REGION:?Set REGION, e.g. europe-west1}"
: "${NAME:?Set NAME, e.g. app-region-eu}"
: "${NEG_NAME:?Set NEG_NAME, e.g. cluster-eu-neg (the GKE-created NEG)}"
: "${ZONE:?Set ZONE, e.g. europe-west1-a}"
: "${NETWORK:?Set NETWORK, e.g. default (the VPC network name)}"
: "${PROXY_SUBNET_RANGE:?Set PROXY_SUBNET_RANGE, e.g. 10.129.0.0/23}"
: "${CERT_FILE:?Set CERT_FILE, path to a PEM cert (self-managed certs only -- regional LBs don't support Google-managed certs)}"
: "${KEY_FILE:?Set KEY_FILE, path to the matching PEM private key}"

echo "==> Creating proxy-only subnet in ${REGION} (required for any regional"
echo "    external Application LB -- one per region per VPC network)"
gcloud compute networks subnets create "${NAME}-proxy-subnet" \
  --purpose=REGIONAL_MANAGED_PROXY \
  --role=ACTIVE \
  --region="${REGION}" \
  --network="${NETWORK}" \
  --range="${PROXY_SUBNET_RANGE}"

echo "==> Allowing health check + proxy traffic to reach the backends"
echo "    (Google health check ranges + the proxy-only subnet, port 8080)"
gcloud compute firewall-rules create "${NAME}-allow-lb-health-check" \
  --network="${NETWORK}" \
  --action=ALLOW \
  --direction=INGRESS \
  --source-ranges=130.211.0.0/22,35.191.0.0/16,"${PROXY_SUBNET_RANGE}" \
  --rules=tcp:8080

echo "==> Reserving static IP (${NAME}-ip) in ${REGION}"
gcloud compute addresses create "${NAME}-ip" \
  --region="${REGION}"

echo "==> Creating backend health check (${NAME}-hc) -- HTTP on the pod's"
echo "    serving port, matching sample-app.yaml"
gcloud compute health-checks create http "${NAME}-hc" \
  --region="${REGION}" \
  --use-serving-port \
  --request-path=/healthz \
  --check-interval=10s \
  --unhealthy-threshold=3

echo "==> Creating backend service (${NAME}-bs), protocol HTTP to match the pod"
gcloud compute backend-services create "${NAME}-bs" \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --protocol=HTTP \
  --region="${REGION}" \
  --health-checks="${NAME}-hc"

echo "==> Attaching GKE NEG (${NEG_NAME}) as backend"
echo "    Note: if your GKE cluster/node pool spans multiple zones, repeat"
echo "    this add-backend call once per zone with that zone's NEG."
gcloud compute backend-services add-backend "${NAME}-bs" \
  --region="${REGION}" \
  --network-endpoint-group="${NEG_NAME}" \
  --network-endpoint-group-zone="${ZONE}" \
  --balancing-mode=RATE \
  --max-rate-per-endpoint=100

echo "==> Creating URL map (${NAME}-urlmap)"
gcloud compute url-maps create "${NAME}-urlmap" \
  --region="${REGION}" \
  --default-service="${NAME}-bs"

echo "==> Creating self-managed SSL cert (${NAME}-cert) -- regional external"
echo "    Application LBs don't support Google-managed certs"
gcloud compute ssl-certificates create "${NAME}-cert" \
  --region="${REGION}" \
  --certificate="${CERT_FILE}" \
  --private-key="${KEY_FILE}"

echo "==> Creating target HTTPS proxy (${NAME}-proxy)"
gcloud compute target-https-proxies create "${NAME}-proxy" \
  --region="${REGION}" \
  --url-map="${NAME}-urlmap" \
  --ssl-certificates="${NAME}-cert"

echo "==> Creating forwarding rule (${NAME}-fr)"
gcloud compute forwarding-rules create "${NAME}-fr" \
  --region="${REGION}" \
  --load-balancing-scheme=EXTERNAL_MANAGED \
  --network="${NETWORK}" \
  --address="${NAME}-ip" \
  --target-https-proxy="${NAME}-proxy" \
  --target-https-proxy-region="${REGION}" \
  --ports=443

echo "==> Done. Forwarding rule reference for DNS: ${NAME}-fr@${REGION}"
gcloud compute addresses describe "${NAME}-ip" --region="${REGION}" --format="value(address)"
