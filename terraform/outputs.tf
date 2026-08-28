# Outputs are what Terraform prints after `apply`, and what `terraform output`
# reprints anytime. The Makefile reads several of these, so renaming one means
# updating the corresponding target.

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "Kubernetes API server endpoint."
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_version" {
  description = "Kubernetes version running on the control plane."
  value       = aws_eks_cluster.main.version
}

output "region" {
  description = "Region the cluster was deployed into."
  value       = var.region
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider that makes IRSA work. Any future add-on needing AWS permissions (an external-secrets operator, the AWS Load Balancer Controller) builds its trust policy against this."
  value       = aws_iam_openid_connect_provider.main.arn
}

output "node_group_capacity" {
  description = "Instance type and desired node count, so it's obvious from the output what you're paying for."
  value       = "${var.node_desired_size} x ${var.node_instance_type}"
}

output "kubeconfig_command" {
  description = "Run this to point kubectl at the new cluster (`make eks-kubeconfig` does it for you)."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.main.name}"
}
