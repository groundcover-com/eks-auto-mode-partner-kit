output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "region" {
  description = "AWS region."
  value       = var.region
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the new cluster."
  value = join(" ", compact([
    "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}",
    var.aws_profile == null ? "" : "--profile ${var.aws_profile}",
    var.assume_role_arn == null ? "" : "--role-arn ${var.assume_role_arn}",
  ]))
}

output "next_steps" {
  description = "Commands to watch the rollout and open the demo."
  value       = <<-EOT
    # Watch Flux reconcile groundcover, then otel-demo (takes ~5-10 minutes)
    kubectl get helmreleases -n flux-system -w

    # Open the demo storefront at http://localhost:8080
    kubectl -n otel-demo port-forward svc/frontend-proxy 8080:8080
  EOT
}
