# The worker nodes — a managed node group of Graviton (arm64) EC2 instances.
#
# "Managed" means AWS handles the AMI, the bootstrap, the join, and rolling
# replacements on upgrade; you declare how many and what size. This is the layer
# that replaces "three Docker containers inside a Colima VM".
#
# WHY ARM64: the app image has been multi-arch since Phase 7 (CI builds
# linux/amd64 + linux/arm64 via QEMU), so Graviton "just works" — and t4g
# instances are roughly 20% cheaper than the x86 equivalent. That multi-arch
# build was added because the laptop is Apple Silicon; it pays for itself twice.
#
# The AMI type below MUST stay in sync with the instance type. Pointing an x86
# AMI at a t4g instance (or vice versa) fails at launch, and the node group just
# reports a create failure after several minutes.

resource "aws_iam_role" "node" {
  name = "${var.project}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# The three policies every EKS worker node needs:
#   WorkerNodePolicy  — let the kubelet register with the cluster
#   CNI_Policy        — let the VPC CNI plugin attach ENIs / hand out pod IPs
#   ECR ReadOnly      — pull images from ECR (harmless here; images come from
#                       GHCR, but the EKS-managed add-on images do come from ECR)
resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "main" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project}-nodes"
  node_role_arn   = aws_iam_role.node.arn

  # Private subnets only: nodes get no public IP and reach the internet through
  # the NAT gateway. Inbound traffic arrives via the NLB, not directly.
  subnet_ids = [for s in aws_subnet.private : s.id]

  # AL2023_ARM_64_STANDARD pairs with the t4g (Graviton) instance type above.
  # For an x86 instance type this must become AL2023_x86_64_STANDARD.
  ami_type       = "AL2023_ARM_64_STANDARD"
  instance_types = [var.node_instance_type]
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  # The node role needs its policies attached BEFORE nodes try to join, or they
  # come up and fail to register.
  depends_on = [aws_iam_role_policy_attachment.node]

  tags = { Name = "${var.project}-nodes" }

  lifecycle {
    # The app's HPA changes pod counts, not node counts — but if a Cluster
    # Autoscaler is ever added, it edits desired_size directly and Terraform
    # would fight it on the next apply.
    ignore_changes = [scaling_config[0].desired_size]
  }
}
