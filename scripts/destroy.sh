#!/usr/bin/env bash
# Tears the kit down cleanly.
#
# Why not just `terraform destroy`? Deleting the in-cluster objects one by one
# (Flux, HelmReleases, namespaces) races against Flux finalizers and can hang.
# Everything inside the cluster goes away with the cluster anyway, so we:
#   1. delete anything that created AWS resources outside Terraform
#      (LoadBalancer Services, Ingresses, PVCs) so AWS can clean them up
#   2. drop the in-cluster resources from state
#   3. destroy the cluster, IAM and VPC
#
# Set TF=tofu to use OpenTofu.
set -euo pipefail

TF="${TF:-terraform}"
cd "$(dirname "$0")/.."

# Destroy doesn't use the key, but the variable is still required.
export TF_VAR_groundcover_api_key="${TF_VAR_groundcover_api_key:-unused-during-destroy}"

if command -v kubectl >/dev/null 2>&1; then
  cluster="$("$TF" output -raw cluster_name 2>/dev/null || true)"
  region="$("$TF" output -raw region 2>/dev/null || true)"
  if [[ -n "$cluster" && -n "$region" ]] && \
     eval "$("$TF" output -raw configure_kubectl)" >/dev/null 2>&1; then
    echo "==> Stopping Flux so it doesn't recreate anything"
    kubectl -n flux-system delete helmreleases --all --wait=true --timeout=5m || true

    echo "==> Deleting LoadBalancer Services, Ingresses and PVCs"
    kubectl get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' |
      while read -r ns name; do
        [[ -n "$ns" ]] && kubectl -n "$ns" delete svc "$name" --wait=true || true
      done
    kubectl delete ingress -A --all --wait=true --timeout=5m || true
    kubectl delete pvc -A --all --wait=true --timeout=5m || true
  else
    echo "==> Cluster not reachable; skipping in-cluster cleanup"
  fi
fi

echo "==> Removing in-cluster resources from state"
for addr in \
  helm_release.flux_apps \
  helm_release.flux_instance \
  helm_release.flux_operator \
  kubernetes_secret_v1.groundcover_api_key \
  kubernetes_namespace_v1.groundcover \
  kubernetes_storage_class_v1.gp3; do
  if "$TF" state list "$addr" >/dev/null 2>&1 && [[ -n "$("$TF" state list "$addr")" ]]; then
    "$TF" state rm "$addr"
  fi
done

echo "==> Destroying EKS, IAM and VPC"
"$TF" destroy "$@"
