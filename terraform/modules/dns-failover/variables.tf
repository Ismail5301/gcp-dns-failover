variable "domain" {
  description = "Fully-qualified DNS name for this region's FAILOVER record, with trailing dot, e.g. eu.app.example.com."
  type        = string
}

variable "managed_zone" {
  description = "Cloud DNS managed zone name, e.g. app-zone"
  type        = string
}

variable "region" {
  description = "GCP region this record's primary lives in, e.g. europe-west1 (used as the backup_geo location, matching the gcloud script's per-region record design)"
  type        = string
}

variable "primary_ip" {
  description = "Primary target IP -- the regional external HTTPS LB's reserved static IP for this region"
  type        = string
}

variable "backup_ip" {
  description = "Backup target IP -- the on-prem or other-cloud public IP"
  type        = string
}

variable "health_check_id" {
  description = "Self link/id of the shared global google_compute_health_check (external-endpoint type) used to probe both primary and backup IPs. Create once in the root module and pass to every region's instance of this module."
  type        = string
}

variable "ttl" {
  description = "Record TTL in seconds"
  type        = number
  default     = 30
}

variable "trickle_ratio" {
  description = "Fraction of traffic sent to the backup even when the primary is healthy (0 = none, matches the gcloud script's default)"
  type        = number
  default     = 0
}
