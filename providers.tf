################################################################################
# AWS
#
# Credentials come from the standard AWS credential chain (AWS_PROFILE,
# `aws sso login`, environment variables, instance roles, ...). Nothing is
# hard-coded here. Optionally set `aws_profile` and/or `assume_role_arn`.
################################################################################

provider "aws" {
  region  = var.region
  profile = var.aws_profile

  dynamic "assume_role" {
    for_each = var.assume_role_arn == null ? [] : [var.assume_role_arn]
    content {
      role_arn     = assume_role.value
      session_name = "groundcover-partner-kit"
    }
  }

  default_tags {
    tags = local.tags
  }
}

################################################################################
# Kubernetes / Helm
#
# Both authenticate to the new cluster with short-lived tokens from
# `aws eks get-token`, using the same profile / role as the AWS provider.
################################################################################

locals {
  eks_token_args = concat(
    ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region, "--output", "json"],
    var.assume_role_arn == null ? [] : ["--role-arn", var.assume_role_arn],
  )
  eks_token_env = var.aws_profile == null ? {} : { AWS_PROFILE = var.aws_profile }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.eks_token_args
    env         = local.eks_token_env
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.eks_token_args
      env         = local.eks_token_env
    }
  }
}
