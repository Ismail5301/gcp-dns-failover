# Regional external Application Load Balancer for one region: proxy-only
# subnet, firewall rule for health-check/proxy traffic, static IP, regional
# health check, backend service, GKE NEG backend(s), self-managed SSL cert,
# URL map, target HTTPS proxy, forwarding rule.
#
# Mirrors scripts/01-create-regional-lb.sh 1:1 -- see that script's
# comments for the "why" behind each resource; this file focuses on the
# Terraform-specific notes.
#
# References (see ../../REFERENCES.md for the full list):
# - Proxy-only subnets: https://cloud.google.com/load-balancing/docs/proxy-only-subnets
# - Container-native load balancing / standalone NEGs:
#   https://cloud.google.com/kubernetes-engine/docs/how-to/standalone-neg
# - google_compute_region_backend_service:
#   https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_region_backend_service

locals {
  neg_zones = coalesce(var.neg_zones, [var.zone])
}

resource "google_compute_subnetwork" "proxy_only" {
  name          = "${var.name}-proxy-subnet"
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"
  region        = var.region
  network       = var.network
  ip_cidr_range = var.proxy_subnet_range
}

resource "google_compute_firewall" "allow_lb_health_check" {
  name      = "${var.name}-allow-lb-health-check"
  network   = var.network
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  # Google health-check probe ranges + the proxy-only subnet itself.
  # NOTE: this is unscoped (applies network-wide), matching the original
  # gcloud script. For anything beyond a portfolio/demo repo, scope this
  # with target_tags or target_service_accounts instead.
  source_ranges = [
    "130.211.0.0/22",
    "35.191.0.0/16",
    var.proxy_subnet_range,
  ]
}

resource "google_compute_address" "lb_ip" {
  name   = "${var.name}-ip"
  region = var.region
}

resource "google_compute_region_health_check" "backend" {
  name                = "${var.name}-hc"
  region              = var.region
  check_interval_sec  = 10
  unhealthy_threshold = 3

  http_health_check {
    port_specification = "USE_SERVING_PORT"
    request_path        = var.health_check_request_path
  }
}

# The NEG itself is created by GKE (via the Service annotation in
# manifests/sample-app.yaml), not by Terraform -- referenced here as a
# data source, one per zone the NEG exists in.
data "google_compute_network_endpoint_group" "gke_neg" {
  for_each = toset(local.neg_zones)
  name     = var.neg_name
  zone     = each.value
}

resource "google_compute_region_backend_service" "app" {
  name                  = "${var.name}-bs"
  region                = var.region
  load_balancing_scheme = "EXTERNAL_MANAGED"
  protocol              = "HTTP"
  health_checks         = [google_compute_region_health_check.backend.id]

  dynamic "backend" {
    for_each = data.google_compute_network_endpoint_group.gke_neg
    content {
      group                 = backend.value.id
      balancing_mode        = "RATE"
      max_rate_per_endpoint = 100
    }
  }
}

resource "google_compute_region_url_map" "app" {
  name            = "${var.name}-urlmap"
  region          = var.region
  default_service = google_compute_region_backend_service.app.id
}

resource "google_compute_region_ssl_certificate" "app" {
  name        = "${var.name}-cert"
  region      = var.region
  certificate = var.cert_pem
  private_key = var.private_key_pem

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_region_target_https_proxy" "app" {
  name             = "${var.name}-proxy"
  region           = var.region
  url_map          = google_compute_region_url_map.app.id
  ssl_certificates = [google_compute_region_ssl_certificate.app.id]
}

resource "google_compute_forwarding_rule" "app" {
  name                  = "${var.name}-fr"
  region                = var.region
  load_balancing_scheme = "EXTERNAL_MANAGED"
  network               = var.network
  ip_address            = google_compute_address.lb_ip.id
  target                = google_compute_region_target_https_proxy.app.id
  port_range            = "443"
}
