variable "name" {
  description = "Base name for resources in this region, e.g. app-region-eu"
  type        = string
}

variable "region" {
  description = "GCP region, e.g. europe-west1"
  type        = string
}

variable "zone" {
  description = "GCP zone the GKE NEG lives in, e.g. europe-west1-a. Repeat this module (or extend neg_zones) per zone if your node pool spans multiple zones."
  type        = string
}

variable "network" {
  description = "VPC network name/self_link the LB and proxy-only subnet attach to"
  type        = string
}

variable "proxy_subnet_range" {
  description = "CIDR range for the regional managed proxy subnet, e.g. 10.129.0.0/23. Must not collide with anything else in this region's VPC."
  type        = string
}

variable "neg_name" {
  description = "Name of the GKE-created container-native NEG to attach as a backend (discoverable via kubectl after applying manifests/sample-app.yaml)"
  type        = string
}

variable "neg_zones" {
  description = "Zones the NEG exists in. Usually just [var.zone]; add more if the GKE Service's NEG spans multiple zones, to attach one backend per zone (see the README's zonal-resilience note)."
  type        = list(string)
  default     = null
}

variable "cert_pem" {
  description = "Contents of the self-managed SSL certificate (PEM). Regional external Application LBs don't support Compute Engine Google-managed certs -- use this or evaluate Certificate Manager's regional Google-managed certs instead (see terraform/REFERENCES.md)."
  type        = string
  sensitive   = true
}

variable "private_key_pem" {
  description = "Contents of the private key matching cert_pem (PEM)"
  type        = string
  sensitive   = true
}

variable "health_check_request_path" {
  description = "Path the backend health check probes on the pod's serving port"
  type        = string
  default     = "/healthz"
}
