# References

Every resource/argument choice in this Terraform module traces back to one
of these. Worth reading directly rather than taking this module's word for
it, especially the DNS routing-policy pieces since the gcloud CLI and the
Terraform provider expose the same underlying API a little differently.

## Cloud DNS routing policies and health checks

- **Overview** -- routing policy types, health-check scope (internal LB vs
  external endpoint), the 30-300s check-interval range for external
  endpoints, geofencing behavior:
  https://cloud.google.com/dns/docs/routing-policies-overview

- **Configure routing policies and health checks** -- exact `gcloud` and
  REST syntax for WRR/GEO/FAILOVER, including the split between *private
  zones* (`--enable-health-checking`, internal load balancers, Cloud DNS
  reads the ILB's own health signal) and *public zones*
  (`--health-check=NAME` against a standalone health check, external
  endpoints only). This is the doc that resolves the "which health-check
  flag" question for a public-zone FAILOVER record with a forwarding-rule
  primary:
  https://cloud.google.com/dns/docs/configure-routing-policies

- **gcloud dns record-sets create reference** -- authoritative flag
  reference; confirms `--routing-policy-primary-data` takes a
  forwarding-rule reference, `--health-check` and `--enable-health-checking`
  are mutually exclusive per record:
  https://cloud.google.com/sdk/gcloud/reference/dns/record-sets/create

## Terraform: google_dns_record_set

- **Resource docs (routing_policy, primary_backup, health_check,
  external_endpoints, internal_load_balancers)**:
  https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/dns_record_set

- **Config Connector DNSRecordSet schema** -- useful as a second,
  independently-maintained view of the exact same underlying API fields
  (`routingPolicy.primaryBackup.primary.externalEndpoints` vs
  `.internalLoadBalancers`), which is what this module's primary/backup
  structure is built from:
  https://cloud.google.com/config-connector/docs/reference/resource-docs/dns/dnsrecordset

- **terraform-provider-google GitHub issue #19250** -- concrete example of
  the private-zone (`internal_load_balancers`) error you get if you mix up
  the public/private zone schemas (`internalLoadBalancerDisallowedInPublicZone`),
  useful if you ever see that error while adapting this module:
  https://github.com/hashicorp/terraform-provider-google/issues/19250

## Regional external Application Load Balancer

- **Proxy-only subnets** -- why the LB needs a dedicated
  `REGIONAL_MANAGED_PROXY` subnet:
  https://cloud.google.com/load-balancing/docs/proxy-only-subnets

- **Container-native load balancing through standalone NEGs** -- how GKE
  creates the NEG this module reads via
  `data.google_compute_network_endpoint_group`:
  https://cloud.google.com/kubernetes-engine/docs/how-to/standalone-neg

- **google_compute_region_backend_service**:
  https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_region_backend_service

- **google_compute_forwarding_rule** (EXTERNAL_MANAGED for regional
  external HTTP(S) LBs):
  https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_forwarding_rule

## SSL certificates

- **Use Google-managed SSL certificates** -- confirms Compute Engine
  Google-managed certs are NOT supported for regional external
  Application LBs (hence the self-managed cert in this module):
  https://cloud.google.com/load-balancing/docs/ssl-certificates/google-managed-certs

- **Certificate Manager: regional Google-managed certificates** -- the
  actual alternative to self-managed certs for this LB type (not the
  Compute-Engine-classic kind above). Worth evaluating if you want to
  drop the manual cert/key management this module currently requires:
  https://cloud.google.com/certificate-manager/docs/deploy-google-managed-regional
