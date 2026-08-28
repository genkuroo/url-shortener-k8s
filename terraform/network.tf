# Networking for the EKS cluster.
#
# Two AZs, each with a public and a private subnet:
#   public  — the NLB that ingress-nginx creates, plus the NAT gateway
#   private — the worker nodes (no public IPs; they reach the internet via NAT)
#
# This differs deliberately from the sibling ECS project, which skipped NAT
# entirely to avoid ~$32/mo. That was the right call for a stack that might be
# left running. Here the cluster is applied and destroyed in the same session, so
# NAT costs ~$0.045/hour — a few cents per demo — and private nodes are the more
# defensible architecture.
#
# Nodes genuinely need outbound internet: to pull the app image from GHCR, pull
# Argo CD and ingress-nginx manifests, and reach the EKS control plane endpoint.

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # EKS requires both

  tags = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.project}-igw" }
}

locals {
  public_subnets = {
    "public-a" = { cidr = cidrsubnet(var.vpc_cidr, 8, 0), az = local.azs[0] }
    "public-b" = { cidr = cidrsubnet(var.vpc_cidr, 8, 1), az = local.azs[1] }
  }

  private_subnets = {
    "private-a" = { cidr = cidrsubnet(var.vpc_cidr, 8, 10), az = local.azs[0] }
    "private-b" = { cidr = cidrsubnet(var.vpc_cidr, 8, 11), az = local.azs[1] }
  }
}

# --- Subnets -----------------------------------------------------------------
#
# THE TAGS BELOW ARE LOAD-BEARING. When ingress-nginx's Service asks Kubernetes
# for a LoadBalancer, the in-tree AWS cloud provider goes looking for subnets to
# place it in, and it finds them ONLY by these tags:
#
#   kubernetes.io/role/elb          = 1   -> "put internet-facing LBs here"
#   kubernetes.io/role/internal-elb = 1   -> "put internal LBs here"
#   kubernetes.io/cluster/<name>    = shared
#
# Get them wrong and there is no error worth reading: the Service just sits at
# EXTERNAL-IP <pending> forever. This is the single most common way a first EKS
# ingress silently fails, which is why they're spelled out here rather than
# tucked into a module.

resource "aws_subnet" "public" {
  for_each = local.public_subnets

  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true

  tags = {
    Name                                          = "${var.project}-${each.key}"
    "kubernetes.io/role/elb"                      = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

resource "aws_subnet" "private" {
  for_each = local.private_subnets

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az

  tags = {
    Name                                          = "${var.project}-${each.key}"
    "kubernetes.io/role/internal-elb"             = "1"
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
  }
}

# --- NAT ---------------------------------------------------------------------
# One NAT gateway (not one per AZ). A per-AZ NAT is the HA answer and doubles the
# cost; for a cluster that lives for one demo, a single NAT in the first public
# subnet is the right trade. Note the blast radius: if that AZ fails, private
# nodes in the other AZ lose egress.

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${var.project}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["public-a"].id

  # The IGW must exist before a NAT gateway can route through it.
  depends_on = [aws_internet_gateway.main]

  tags = { Name = "${var.project}-nat" }
}

# --- Routing -----------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.project}-rt-public" }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.project}-rt-private" }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
