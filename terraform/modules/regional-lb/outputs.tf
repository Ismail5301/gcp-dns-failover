output "ip_address" {
  description = "Reserved static IP of this region's regional external HTTPS LB. Feed this into the dns-failover module's primary_ip."
  value       = google_compute_address.lb_ip.address
}

output "forwarding_rule_name" {
  description = "Forwarding rule name, e.g. app-region-eu-fr (informational -- kept for parity with the gcloud script's output; not consumed by the dns-failover module, see REFERENCES.md for why)"
  value       = google_compute_forwarding_rule.app.name
}

output "backend_service_name" {
  description = "Backend service name, for use with scripts/03-test-failover.sh's BACKEND_SERVICE var"
  value       = google_compute_region_backend_service.app.name
}

output "health_check_name" {
  description = "Original backend health check name, for use with scripts/03-test-failover.sh's ORIGINAL_HEALTH_CHECK var"
  value       = google_compute_region_health_check.backend.name
}
