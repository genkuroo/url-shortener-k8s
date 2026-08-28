variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Name prefix applied to all resources (and the Project tag)."
  type        = string
  default     = "url-shortener-k8s"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "cluster_version" {
  description = "Kubernetes minor version for the EKS control plane."
  type        = string
  default     = "1.31"
}

# --- Node group sizing -------------------------------------------------------
# These are variables (not hard-coded) on purpose: node capacity is the single
# knob you turn when the cluster gets tight. Two cases where you'll raise it:
#   1. Turning the monitoring stack on (kube-prometheus-stack wants ~2-3 GiB).
#   2. Letting prod's HPA scale far — pods go Pending when nodes run out.

variable "node_instance_type" {
  description = "EC2 instance type for the managed node group. t4g = Graviton (arm64), ~20% cheaper than the x86 equivalent — usable here because the app image is multi-arch (built for linux/amd64 + linux/arm64 in CI since Phase 7)."
  type        = string
  default     = "t4g.medium"
}

variable "node_desired_size" {
  description = "Number of worker nodes to run. 2 is comfortable for the app + Postgres + Argo CD + ingress-nginx with monitoring OFF. Raise to 3 (or move to t4g.large) before enabling kube-prometheus-stack."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum worker nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum worker nodes. Headroom for the app HPA to scale into; the node group itself does not autoscale (no Cluster Autoscaler installed) — this is just a ceiling."
  type        = number
  default     = 4
}

# --- Control-plane observability ---------------------------------------------
# On kind, Prometheus couldn't scrape kube-scheduler / controller-manager / etcd
# because they bind to 127.0.0.1. On EKS you can't scrape them either — but for a
# different reason: AWS runs the control plane and doesn't expose those endpoints
# at all. That's a real thing you give up for a managed control plane.
#
# The EKS-native replacement is control-plane logs shipped to CloudWatch. Left
# EMPTY by default so a throwaway cluster doesn't quietly accrue log charges;
# set it to e.g. ["api", "audit"] when you actually want to look.
variable "cluster_log_types" {
  description = "EKS control-plane log types to ship to CloudWatch. Valid: api, audit, authenticator, controllerManager, scheduler. Empty disables control-plane logging."
  type        = list(string)
  default     = []
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint. Defaults to open because kubectl and Argo CD are driven from a laptop with a changing IP; narrow it to your own /32 for a longer-lived cluster."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
