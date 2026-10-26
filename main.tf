data "aws_availability_zones" "available" {
  # Exclude Local Zones / Wavelength Zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = merge(
    {
      Project   = "groundcover-partner-kit"
      Cluster   = var.cluster_name
      ManagedBy = "terraform"
    },
    var.tags,
  )
}

################################################################################
# VPC
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7"

  name = var.cluster_name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  # Lets EKS Auto Mode's built-in load balancer controller find the right subnets
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

################################################################################
# EKS (Auto Mode)
#
# With compute_config enabled, AWS runs and manages compute, CoreDNS,
# kube-proxy, VPC CNI, EBS CSI and the load balancer controller. No managed
# node groups or add-ons are declared here on purpose.
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  compute_config = {
    enabled    = true
    node_pools = ["general-purpose", "system"]
  }

  # The identity running Terraform gets cluster-admin via an EKS access entry
  enable_cluster_creator_admin_permissions = true

  access_entries = {
    for i, arn in var.admin_principal_arns : "admin-${i}" => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Nodes in private subnets need the NAT gateway to pull images. Without this,
  # a failed NAT/EIP (e.g. AddressLimitExceeded) still lets the cluster build and
  # only surfaces 15 minutes later as a Helm "context deadline exceeded".
  depends_on = [module.vpc]
}

################################################################################
# Default StorageClass
#
# Auto Mode ships the EBS CSI driver but no StorageClass. Add a gp3 default so
# any PVCs (from the demo or later experiments) bind.
################################################################################

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.eks.amazonaws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [module.eks]
}
