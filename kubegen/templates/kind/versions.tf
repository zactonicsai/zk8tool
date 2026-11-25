# Terraform and provider requirements.
terraform {
  required_version = ">= 1.3"

  required_providers {
    # Community provider that drives kind (Kubernetes in Docker) directly.
    # It embeds kind, so only Docker has to be installed and running.
    kind = {
      source  = "tehcyx/kind"
      version = ">= 0.4.0"
    }
  }
}
