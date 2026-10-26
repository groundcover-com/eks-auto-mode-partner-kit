################################################################################
# AWS access
################################################################################

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Optional named AWS CLI profile (e.g. an SSO profile). Leave null to use the default credential chain."
  type        = string
  default     = null
}

variable "assume_role_arn" {
  description = "Optional IAM role ARN to assume for all AWS and cluster operations."
  type        = string
  default     = null
}

variable "admin_principal_arns" {
  description = "Extra IAM user/role ARNs that get cluster-admin on the EKS cluster. The identity running Terraform is always added."
  type        = list(string)
  default     = []
}

################################################################################
# Cluster
################################################################################

variable "cluster_name" {
  description = "Name of the EKS cluster. Also used as the groundcover clusterId."
  type        = string
  default     = "gc-partner-demo"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Must be supported by the pinned Flux version (see flux_version)."
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR block for the new VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API endpoint. Narrow this to your own IP for anything beyond a short-lived demo."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "tags" {
  description = "Extra tags applied to every AWS resource."
  type        = map(string)
  default     = {}
}

################################################################################
# Flux
################################################################################

variable "flux_operator_version" {
  description = "Flux Operator Helm chart version (ghcr.io/controlplaneio-fluxcd/charts)."
  type        = string
  default     = "0.61.0"
}

variable "flux_version" {
  description = "Flux distribution version installed by the operator."
  type        = string
  default     = "2.9.6"
}

################################################################################
# groundcover
################################################################################

variable "groundcover_api_key" {
  description = "groundcover sensor ingestion key (`groundcover auth get-ingestion-key sensor`). Pass via TF_VAR_groundcover_api_key; it is never written to state."
  type        = string
  sensitive   = true
  ephemeral   = true
  nullable    = false
}

variable "groundcover_api_key_revision" {
  description = "Bump this number to push a new groundcover_api_key to the cluster (write-only values are not diffed)."
  type        = number
  default     = 1
}

variable "groundcover_byoc_endpoint" {
  description = "Your groundcover BYOC ingestion endpoint, from the Ingestion Keys tab in the groundcover console (e.g. example.platform.grcv.io)."
  type        = string
}

variable "groundcover_env" {
  description = "groundcover environment label shown in the cluster picker."
  type        = string
  default     = "partner-demo"
}

variable "groundcover_chart_version" {
  description = "groundcover Helm chart version (https://helm.groundcover.com)."
  type        = string
  default     = "1.13.166"
}

################################################################################
# OpenTelemetry demo
################################################################################

variable "otel_demo_chart_version" {
  description = "opentelemetry-demo Helm chart version (app version 3.1.0)."
  type        = string
  default     = "0.42.6"
}
