output "record_name" {
  description = "The DNS name of the created FAILOVER record"
  value       = google_dns_record_set.failover.name
}
