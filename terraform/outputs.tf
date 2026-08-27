output "lb_ip_addresses" {
  description = "Reserved static IP per region"
  value       = { for k, m in module.regional_lb : k => m.ip_address }
}

output "backend_services" {
  description = "Backend service name per region -- feed into scripts/03-test-failover.sh's BACKEND_SERVICE"
  value       = { for k, m in module.regional_lb : k => m.backend_service_name }
}

output "original_health_checks" {
  description = "Original backend health check name per region -- feed into scripts/03-test-failover.sh's ORIGINAL_HEALTH_CHECK"
  value       = { for k, m in module.regional_lb : k => m.health_check_name }
}

output "dns_records" {
  description = "FAILOVER record name per region"
  value       = { for k, m in module.dns_failover : k => m.record_name }
}

output "dns_health_checks" {
  description = "Per-region external-endpoint health check name (app-region-<key>-dns-hc) -- this is the outer, DNS-facing check; it's a different resource from original_health_checks above, which is the inner LB backend check"
  value       = { for k, hc in google_compute_health_check.app_hc : k => hc.name }
}
