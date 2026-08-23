# Terraform implementation -- in progress

The `gcloud`-based scripts in `../scripts/` are the current source of truth
for this architecture. A Terraform module covering the same resources
(regional external HTTPS LBs, health checks, backend services, and the
Cloud DNS geolocation/failover record set) is planned.

Planned structure:

```
terraform/
├── main.tf
├── variables.tf
├── outputs.tf
└── modules/
    ├── regional-lb/
    └── dns-failover/
```
