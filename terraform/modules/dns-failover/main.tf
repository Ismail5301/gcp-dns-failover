# Cloud DNS FAILOVER record for ONE region -- primary is that region's LB
# IP, backup is a raw external IP (on-prem/other-cloud), both health
# checked via the shared external-endpoint health check passed in as
# health_check_id.
#
# IMPORTANT gcloud-vs-Terraform difference, worth understanding before you
# run this:
#
# The gcloud script (scripts/02-create-regional-failover-record.sh) sets
# --routing-policy-primary-data="<forwarding-rule-name>@<region>" -- a
# reference to the forwarding rule itself, not its IP.
#
# The Terraform google provider's public-zone schema for primary_backup
# only exposes `primary.external_endpoints` (a list of raw IP strings) --
# there is no forwarding-rule-reference field for the primary in a public
# zone (that option, `primary.internal_load_balancers`, exists only for
# private zones/internal load balancers, where Cloud DNS reads the ILB's
# own health signal directly). See the Config Connector DNSRecordSet
# schema in REFERENCES.md, which documents the same
# externalEndpoints-vs-internalLoadBalancers split at the API level.
#
# In practice this is a distinction without a behavioral difference here:
# for a PUBLIC zone, Cloud DNS health-checks the primary the same way
# regardless of whether you handed it a forwarding-rule reference or the
# resolved IP directly -- an external-endpoint probe against that IP:port
# over the public internet, using the health check referenced by
# routing_policy.health_check. This module passes the LB's static IP
# (module.regional_lb.ip_address) into `external_endpoints`, which is the
# Terraform-native way to express the same thing the gcloud script does.
#
# References (see ../../REFERENCES.md):
# - google_dns_record_set (primary_backup, health_check, external_endpoints):
#   https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/dns_record_set
# - DNS routing policies and health checks (public zone, gcloud + REST):
#   https://cloud.google.com/dns/docs/configure-routing-policies
# - Routing policies overview (health check floor, external-endpoint scope):
#   https://cloud.google.com/dns/docs/routing-policies-overview

resource "google_dns_record_set" "failover" {
  name         = var.domain
  type         = "A"
  ttl          = var.ttl
  managed_zone = var.managed_zone

  routing_policy {
    health_check = var.health_check_id

    primary_backup {
      trickle_ratio = var.trickle_ratio

      primary {
        external_endpoints = [var.primary_ip]
      }

      backup_geo {
        location = var.region
        health_checked_targets {
          external_endpoints = [var.backup_ip]
        }
      }
    }
  }
}
