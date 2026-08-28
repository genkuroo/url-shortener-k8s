# EKS managed add-ons.
#
# kind ships a working cluster out of the box. EKS ships a control plane and
# nothing else — these are the pieces that make it behave like the cluster the
# Helm chart already expects.
#
# vpc-cni / coredns / kube-proxy are the baseline every cluster needs. The
# interesting one is the EBS CSI driver: without it there is NO storage backend
# at all, so the chart's Postgres StatefulSet claims a PVC that can never be
# satisfied and `postgres-0` sits Pending forever. On kind this was invisible
# because kind bundles a local-path provisioner.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "vpc-cni"
  addon_version = null # let EKS pick the default for this cluster version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "kube-proxy"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# CoreDNS pods are scheduled onto worker nodes, so they can't become Ready until
# the node group exists — hence the explicit dependency.
resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.main]
}

# --- EBS CSI driver + its IRSA role ------------------------------------------
#
# The trust policy below is the whole point of IRSA. Read the Condition block as:
# "allow this role to be assumed only by a token this cluster issued, only for
# the ServiceAccount named ebs-csi-controller-sa in kube-system, and only when
# the audience is sts.amazonaws.com."
#
# That's dramatically tighter than attaching AmazonEBSCSIDriverPolicy to the node
# role, which would let ANY pod on the node create and delete EBS volumes.

data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.main.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.main.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.main.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.project}-ebs-csi-role"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "aws-ebs-csi-driver"

  # This is where the IRSA role is handed to the driver's ServiceAccount.
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_node_group.main,
    aws_iam_role_policy_attachment.ebs_csi,
  ]
}

# NOTE: installing the driver is only half the job. A StorageClass still has to
# exist and be marked default, because the chart's volumeClaimTemplates omit
# storageClassName and fall back to the cluster default. That StorageClass is
# delivered the GitOps way (gitops/eks/apps/storageclass.yaml) rather than from
# Terraform — same philosophy as the rest of the project: Terraform owns
# infrastructure, Argo owns anything inside the cluster.
