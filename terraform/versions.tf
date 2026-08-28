terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Used once, to read the thumbprint of the cluster's OIDC issuer certificate
    # so we can register it as an IAM identity provider (that's what makes IRSA
    # work — see eks.tf).
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
