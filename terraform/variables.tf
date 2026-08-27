variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "network" {
  description = "VPC network name shared by all regions"
  type        = string
  default     = "default"
}

variable "dns_zone" {
  description = "Cloud DNS managed zone name, e.g. app-zone"
  type        = string
}

variable "global_health_check_source_regions" {
  description = "Source regions for the shared external-endpoint health check (app-hc). Pick 3, per the gcloud script's default."
  type        = list(string)
  default     = ["europe-west1", "us-central1", "us-east1"]
}

variable "regions" {
  description = <<-EOT
    One entry per region this architecture is deployed to. Mirrors running
    scripts/01 and scripts/02 once per region with different env vars.
  EOT
  type = map(object({
    region             = string
    zone               = string
    neg_zones          = optional(list(string))
    neg_name           = string
    proxy_subnet_range = string
    cert_pem_file      = string # path to a local PEM cert file, e.g. ./eu-cert.pem
    key_pem_file       = string # path to the matching PEM private key
    domain             = string # e.g. eu.app.example.com.  (include trailing dot)
    backup_ip          = string # on-prem/other-cloud public IP for this region
  }))

  # Example (see terraform.tfvars.example):
  # regions = {
  #   eu = {
  #     region             = "europe-west1"
  #     zone               = "europe-west1-a"
  #     neg_name           = "sample-app-https-neg"
  #     proxy_subnet_range = "10.129.0.0/23"
  #     cert_pem_file      = "./eu-cert.pem"
  #     key_pem_file       = "./eu-key.pem"
  #     domain             = "eu.app.example.com."
  #     backup_ip          = "203.0.113.10"
  #   }
  # }
}
