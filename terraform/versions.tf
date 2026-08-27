terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.44.0" # primary_backup + health_check block on google_dns_record_set requires this generation; see REFERENCES.md
    }
  }
}

provider "google" {
  project = var.project_id
}
