# Wires modules/regional-lb and modules/dns-failover together once per
# entry in var.regions -- the Terraform equivalent of running
# scripts/01-create-regional-lb.sh and
# scripts/02-create-regional-failover-record.sh once per region.
#
# The external-endpoint health check (app-hc in the gcloud script) is
# created ONCE here, globally, and shared across all regions' DNS
# records -- same as the gcloud script's "create if it doesn't already
# exist" check.
#
# Reference: gcloud beta compute health-checks create https ...
# https://cloud.google.com/sdk/gcloud/reference/beta/compute/health-checks/create/https

resource "google_compute_health_check" "app_hc" {
  name = "app-hc"

  # Hard floor of 30s for this health check type -- see
  # https://cloud.google.com/dns/docs/routing-policies-overview
  check_interval_sec = 30

  source_regions = var.global_health_check_source_regions

  https_health_check {
    port         = 443
    request_path = "/healthz"
  }
}

module "regional_lb" {
  source   = "./modules/regional-lb"
  for_each = var.regions

  name                = "app-region-${each.key}"
  region              = each.value.region
  zone                = each.value.zone
  neg_zones           = each.value.neg_zones
  network             = var.network
  proxy_subnet_range  = each.value.proxy_subnet_range
  neg_name            = each.value.neg_name
  cert_pem            = file(each.value.cert_pem_file)
  private_key_pem     = file(each.value.key_pem_file)
}

module "dns_failover" {
  source   = "./modules/dns-failover"
  for_each = var.regions

  domain          = each.value.domain
  managed_zone    = var.dns_zone
  region          = each.value.region
  primary_ip      = module.regional_lb[each.key].ip_address
  backup_ip       = each.value.backup_ip
  health_check_id = google_compute_health_check.app_hc.id
}
