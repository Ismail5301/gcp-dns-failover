#!/usr/bin/env bash
#
# Run this ONCE from inside your cloned gcp-dns-failover/ folder.
# It creates every folder and file for you -- nothing to copy/paste by hand.
#
#   cd gcp-dns-failover
#   bash setup_repo.sh
#
set -euo pipefail

mkdir -p scripts manifests terraform

# ---------------------------------------------------------------------------
cat > README.md << 'FILE_EOF'
# Multi-Region L7 HTTPS Failover with Cloud DNS

A GCP reference architecture for routing HTTPS traffic to one of two regional
GKE clusters, using Cloud DNS geolocation + failover routing policies to (a)
pin normal traffic to a specific region for data-residency reasons, and (b)
fail over to a healthy region -- including a region outside GCP -- when the
primary is down.

This repo currently implements the design using `gcloud` only. A Terraform
implementation is planned (see [Roadmap](#roadmap)).

---

## Why DNS failover, and why not just a Global External HTTPS LB

For a plain "route to whichever GKE region is healthy" requirement, a single
**Global External HTTPS LB with zonal NEGs from both clusters attached to one
backend service** is the better answer, not this repo's approach. GKE
container-native NEGs carry a real health check, so the LB automatically
stops sending traffic to an unhealthy region's backends and routes to the
other region -- one anycast IP, failover in single-digit seconds, one
forwarding rule to pay for. If that's your whole requirement, use that
instead of what's in this repo.

DNS failover earns its place when either of these is actually true, which
they are for the scenario this repo targets:

1. **Data residency / traffic pinning.** A single global LB routes by
   proximity to the nearest *healthy* backend -- it doesn't give you a hard
   guarantee that, say, EU traffic is served only from EU infrastructure
   under normal conditions. Cloud DNS's geolocation routing policy (with
   geofencing enabled) does: it pins traffic to the region mapped to the
   client's location and does **not** silently fail over to another
   geolocation just because that's easier -- it returns the pinned region's
   answer unless that entire geolocation's endpoints fail health checks.
   That's a real, common requirement (regulatory, contractual, or just "we
   don't want EU customer traffic hairpinning through US infrastructure even
   during a partial degradation").

2. **A backup target that isn't a GCP NEG-eligible backend at all** -- an
   on-prem data center or a different cloud provider's own load balancer,
   with no private network path (VPN/Interconnect) into that environment.
   GCP does support hybrid NEGs for on-prem/other-cloud backends on a global
   LB, but only for targets reachable over a private VPC extension -- Google's
   health check probers need to reach the endpoint privately. If that
   connectivity doesn't exist (a public endpoint sitting in AWS/Azure with
   its own independent load balancer, or an on-prem site with no
   Interconnect), you can't attach it as a backend at all. Cloud DNS doesn't
   care what's behind the IP -- it just needs a forwarding rule (for the GCP
   side) and returns the backup IP when the primary is unhealthy. That makes
   it the practical option for tying a GCP region to a non-GCP failover
   target, not just the cheaper one.

| Approach | Failover mechanism | Works across clouds/on-prem? | Pins traffic to a region under normal ops? | Failover latency |
|---|---|---|---|---|
| Global External HTTPS LB, multi-region NEGs | LB-level health check, single anycast IP | No -- NEGs must be GCP-native or privately reachable hybrid NEGs | No -- routes by proximity to nearest healthy backend | Seconds |
| **Cloud DNS geolocation + failover** (this repo) | Client re-resolves once Cloud DNS's health check on the primary fails | Yes -- backup can be any IP, including outside GCP | Yes -- geofencing pins traffic to the mapped region | Tens of seconds (health check detection + TTL) |
| Multi-cluster Gateway / Anthos Service Mesh | Mesh-aware routing across a GKE Fleet | GCP/Anthos-attached clusters only | Not its purpose -- built for east-west traffic management | Varies |

The tradeoff for using DNS is the one thing DNS-based routing can never fully
avoid: it depends on the client re-resolving, so failover time is measured in
tens of seconds rather than the single-digit-second failover a proxy-based LB
gets by just dropping an unhealthy backend from rotation. That's the real
cost of buying region-pinning and cross-provider portability with this
pattern -- worth stating plainly rather than glossing over.

## Architecture

```mermaid
flowchart TB
    ClientEU((EU Client))
    ClientUS((US Client))
    DNS[Cloud DNS<br/>Geolocation + Failover<br/>routing policy, geofenced]

    subgraph RegionEU["Region A - europe-west1 (pinned for EU traffic)"]
        LBEU[Regional External<br/>HTTPS LB]
        GKEEU[GKE Cluster - EU]
        LBEU --> GKEEU
    end

    subgraph RegionUS["Region B - us-central1 (pinned for US traffic)"]
        LBUS[Regional External<br/>HTTPS LB]
        GKEUS[GKE Cluster - US]
        LBUS --> GKEUS
    end

    subgraph Backup["Backup target - outside GCP"]
        Other[On-prem / other-cloud<br/>endpoint, own health check]
    end

    ClientEU --> DNS
    ClientUS --> DNS
    DNS -- "EU traffic, primary" --> LBEU
    DNS -- "US traffic, primary" --> LBUS
    DNS -. "EU failover, if region A unhealthy" .-> Other

    style RegionEU fill:#f3fff3,stroke:#3a3
    style RegionUS fill:#f3fff3,stroke:#3a3
    style Backup fill:#fff3f3,stroke:#d33
```

Each region's stack is fully independent -- its own regional external HTTPS
LB, its own certs, its own config surface. Cloud DNS is the only thing tying
them together, which is exactly the point: a bad config push to the EU LB
can't touch the US stack, and the backup target doesn't need to be a GCP
resource at all.

## How failover actually behaves (and the latency tradeoff)

Cloud DNS's `FAILOVER` routing policy reads the health state of the backend
service behind the forwarding rule you reference as primary -- it isn't
running independent probes. Total time for a client to actually reach the
backup breaks into two pieces:

1. **Health check detection** -- `check_interval x unhealthy_threshold`. With
   a 5-10s interval and 2-3 consecutive failures, that's roughly 10-30s
   before Cloud DNS's view of the primary flips to unhealthy.
2. **DNS caching** -- Google's guidance for primary/backup failover is a TTL
   of 30s or less specifically so resolvers re-query quickly. That covers
   compliant resolvers; it doesn't cover already-open connections/keep-alives
   (which don't re-resolve until they reconnect) or clients/resolvers that
   don't honor TTL.

Combined, **30-60 seconds is a realistic number** for new connections with an
aggressive health check and a 30s TTL -- not a guarantee, and there's a tail
risk from non-compliant caching that no TTL setting fully removes.

## Repo layout

```
.
├── README.md
├── scripts/
│   ├── 01-create-regional-lb.sh            # regional ext. HTTPS LB + health check, per region
│   ├── 02-create-dns-geo-failover-record.sh
│   └── 03-test-failover.sh
├── manifests/
│   └── sample-app.yaml                     # Deployment + Service (NEG-enabled)
└── terraform/
    └── README.md                           # "in progress" placeholder
```

## Implementation walkthrough (gcloud)

Assumes two GKE clusters (`cluster-eu` in `europe-west1`, `cluster-us` in
`us-central1`) each running the same Deployment/Service, and a Cloud DNS
managed zone for your domain. The backup target for this walkthrough is
modeled as a third static IP, standing in for an on-prem or other-cloud
endpoint -- swap in whatever's actually behind it.

### 1. Reserve a static IP and create the regional external HTTPS LB, per region

```bash
REGION=europe-west1 \
NAME=app-region-eu \
NEG_NAME=cluster-eu-neg \
ZONE=europe-west1-a \
DOMAIN=eu.app.example.com \
./scripts/01-create-regional-lb.sh
```

Repeat for `us-central1` / `cluster-us` with `NAME=app-region-us`.

### 2. Create the Cloud DNS geolocation + failover record

```bash
ZONE=app-zone \
DOMAIN=app.example.com. \
./scripts/02-create-dns-geo-failover-record.sh
```

### 3. Test the failover

```bash
REGION=europe-west1 \
BACKEND_SERVICE=app-region-eu-bs \
ORIGINAL_HEALTH_CHECK=app-region-eu-hc \
DOMAIN=eu.app.example.com \
./scripts/03-test-failover.sh
```

## Roadmap

- [ ] Terraform module covering everything in `scripts/`
- [ ] GitHub Actions workflow that runs `03-test-failover.sh` against a
      staging zone on a schedule
- [ ] Cloud Monitoring alert policy on health-check state transitions
- [ ] Independent uptime check on the non-GCP backup target, since Cloud DNS
      can't health-check it directly
FILE_EOF

# ---------------------------------------------------------------------------
cat > .gitignore << 'FILE_EOF'
# Terraform (once added)
.terraform/
*.tfstate
*.tfstate.*
.terraform.lock.hcl
*.tfvars

# OS / editor cruft
.DS_Store
*.swp
FILE_EOF

# ---------------------------------------------------------------------------
cat > scripts/01-create-regional-lb.sh << 'FILE_EOF'
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
FILE_EOF

# ---------------------------------------------------------------------------
cat > scripts/02-create-dns-geo-failover-record.sh << 'FILE_EOF'
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
FILE_EOF

# ---------------------------------------------------------------------------
cat > scripts/03-test-failover.sh << 'FILE_EOF'
#!/usr/bin/env bash
#
# Simulates a regional outage by pointing a backend service at a health
# check that will never pass, then watches the DNS answer for a domain
# until it flips to the backup. Restores the original health check after.
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

echo "==> Watching DNS answer -- expect it to flip within ~30-60s"
echo "    (Ctrl+C once you see the backup IP)"
for i in $(seq 1 24); do
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
FILE_EOF

# ---------------------------------------------------------------------------
cat > manifests/sample-app.yaml << 'FILE_EOF'
# Minimal Deployment + Service exposing a container-native load balancing
# NEG, so the Service can be attached as a backend to the regional external
# HTTPS LB created by scripts/01-create-regional-lb.sh.
#
# The NEG name GKE generates is discoverable after apply via:
#   kubectl get svc sample-app -o jsonpath='{.metadata.annotations.cloud\.google\.com/neg-status}'

apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-app
  labels:
    app: sample-app
spec:
  replicas: 2
  selector:
    matchLabels:
      app: sample-app
  template:
    metadata:
      labels:
        app: sample-app
    spec:
      containers:
        - name: sample-app
          image: gcr.io/google-samples/hello-app:2.0
          ports:
            - containerPort: 8080
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: sample-app
  annotations:
    cloud.google.com/neg: '{"exposed_ports": {"443":{"name": "cluster-region-neg"}}}'
spec:
  type: ClusterIP
  selector:
    app: sample-app
  ports:
    - port: 443
      targetPort: 8080
FILE_EOF

# ---------------------------------------------------------------------------
cat > terraform/README.md << 'FILE_EOF'
# Terraform implementation -- in progress

The `gcloud`-based scripts in `../scripts/` are the current source of truth
for this architecture. A Terraform module covering the same resources
(regional external HTTPS LBs, health checks, backend services, and the
Cloud DNS geolocation/failover record set) is planned.

Planned structure:

```
terraform/
├── main.tf
├── variables.tf
├── outputs.tf
└── modules/
    ├── regional-lb/
    └── dns-failover/
```
FILE_EOF

chmod +x scripts/*.sh

echo ""
echo "All files created. Now run:"
echo "  git add -A"
echo "  git commit -m \"Initial architecture: README, DNS failover scripts, sample manifest\""
echo "  git push -u origin main"
