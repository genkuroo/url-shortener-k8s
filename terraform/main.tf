# Provider configuration. `default_tags` are applied to every taggable resource
# this provider creates, so we don't repeat them on each resource.
#
# Same convention as the sibling ECS project (url-shortener-aws/infra/main.tf) —
# the two stacks are meant to be read side by side.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}

# Handy lookups used across the other files.
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # The cluster name is derived from the project prefix so every resource in this
  # stack shares one recognizable name, and so the EKS-specific subnet tags below
  # can reference it without a second variable.
  cluster_name = "${var.project}-eks"

  # Use the first two AZs in whatever region we deploy into. Two is the minimum
  # EKS accepts for a control plane, and it's enough for this demo.
  azs = slice(data.aws_availability_zones.available.names, 0, 2)
}
