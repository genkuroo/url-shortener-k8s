# The EKS control plane — the thing you're actually buying.
#
# This is the whole difference from kind in one resource. On kind, the API server,
# etcd, scheduler and controller-manager are containers on the laptop; here AWS
# runs them, patches them, and spreads them across the two AZs. You never see the
# machines, and you can't break them.
#
# Cost note: this bills at roughly $0.10/hour whether or not a single pod runs on
# it. That's the reason `make eks-down` exists and the reason this stack is
# applied and destroyed in the same session.

resource "aws_iam_role" "cluster" {
  name = "${var.project}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  # Empty by default — see the cluster_log_types variable for why control-plane
  # observability works differently on EKS than it did on kind.
  enabled_cluster_log_types = var.cluster_log_types

  vpc_config {
    # Both subnet tiers: the control plane puts its cross-account ENIs in the
    # private subnets, and the public ones are where the NLB will land.
    subnet_ids = concat(
      [for s in aws_subnet.public : s.id],
      [for s in aws_subnet.private : s.id],
    )
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.endpoint_public_access_cidrs
  }

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
    # Without this, the IAM principal that runs `terraform apply` has no
    # Kubernetes RBAC binding, and the very first `kubectl get nodes` fails with
    # a confusing "You must be logged in to the server (Unauthorized)".
    bootstrap_cluster_creator_admin_permissions = true
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]

  tags = { Name = local.cluster_name }
}

# --- IRSA: the OIDC identity provider ----------------------------------------
#
# This is the piece that has no equivalent on kind, and the concept worth being
# able to explain.
#
# Add-ons running in the cluster (the EBS CSI driver, below) need AWS permissions
# to create volumes. The lazy way is to attach the policy to the *node* role,
# which gives every pod on that node those rights. IRSA is the correct way:
# the cluster issues OIDC tokens for ServiceAccounts, AWS is told to trust that
# issuer, and an IAM role's trust policy then names one specific ServiceAccount.
#
# Result: only the ebs-csi-controller-sa ServiceAccount can create EBS volumes —
# not every pod that happens to land on the same node.

data "tls_certificate" "oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "main" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  tags = { Name = "${var.project}-oidc" }
}
