# Guide for AI assistants

This file is for AI coding assistants (Claude Code, Cursor, Copilot, etc.) helping someone deploy this kit. Humans should start with [README.md](README.md). Everything here was learned from real deployments.

## What this kit does

Terraform/OpenTofu builds a VPC and an EKS Auto Mode cluster, installs Flux via the Flux Operator, and hands Flux two HelmReleases: the groundcover sensor, then the OpenTelemetry Demo (`dependsOn: groundcover`). Architecture and design decisions are in the README.

## Ground rules

1. **Never write the groundcover API key to disk.** Not to `terraform.tfvars`, not to `.env`, not to any committed file, and not into a command you echo back. Pass it only as `TF_VAR_groundcover_api_key` in the environment of the `terraform`/`tofu` process. The variable is `ephemeral`, and Terraform stores it with a write-only attribute, so it stays out of state as long as you don't put it somewhere else.
2. **If the user pastes the key into the chat,** use it only in that environment variable, and suggest they rotate it once testing is done, because it now lives in the transcript.
3. **Confirm before `apply` and before destroy.** Both take 15+ minutes. `apply` starts billing (EKS control plane, Auto Mode, EC2, NAT gateway), and destroy is irreversible. The exception is when the user has clearly told you to go ahead.
4. **Tear down only with `./scripts/destroy.sh`** (`TF=tofu ./scripts/destroy.sh` for OpenTofu), never a bare `terraform destroy`. Section 7 of the README explains why.
5. **Don't commit** `terraform.tfvars`, state, plans or `.terraform.lock.hcl`. They're all git-ignored; keep it that way.

## Turning groundcover's Helm overrides into kit settings

The groundcover console hands users a Helm values snippet like this:

```yaml
global:
  groundcover_token: gcik_...
  ingress:
    site: example.platform.grcv.io
  backend:
    enabled: false
clusterId: my-cluster
```

Map it like this. Don't paste it into the chart:

| Helm value | Kit setting |
|---|---|
| `global.groundcover_token` | `export TF_VAR_groundcover_api_key=...` (environment only) |
| `global.ingress.site` | `groundcover_byoc_endpoint` in `terraform.tfvars` (hostname only, no `https://`) |
| `global.backend.enabled: false` | Already set in `charts/flux-apps/templates/groundcover.yaml` |
| `clusterId` | `cluster_name` in `terraform.tfvars` (the kit uses it as `clusterId`) |
| `env` (if present) | `groundcover_env` in `terraform.tfvars` |

## Preflight

Run these before `apply`. Each one has caused a real failure.

```bash
terraform version || tofu version   # needs >= 1.11; use whichever exists
aws --version                       # AWS CLI v2 must be on PATH (Kubernetes/Helm auth calls it)
aws sts get-caller-identity         # confirms credentials work; this identity becomes cluster admin
```

**Quotas (most common failure).** The kit needs 1 free VPC and 1 free Elastic IP in the target region, and shared demo accounts often sit at the default limit of 5:

```bash
REGION=<region>
echo "VPCs: $(aws ec2 describe-vpcs --region $REGION --query 'length(Vpcs)') / $(aws service-quotas get-service-quota --region $REGION --service-code vpc --quota-code L-F678F1CE --query Quota.Value)"
echo "EIPs: $(aws ec2 describe-addresses --region $REGION --query 'length(Addresses)') / $(aws service-quotas get-service-quota --region $REGION --service-code ec2 --quota-code L-0263D0A3 --query Quota.Value)"
```

If either is at its limit, suggest another region or a quota increase. Don't release Elastic IPs or delete VPCs you didn't create. A count above the reported quota means the quota API is stale; treat that region as full.

## Deploy

```bash
cp terraform.tfvars.example terraform.tfvars   # then set region, cluster_name, groundcover_byoc_endpoint
export TF_VAR_groundcover_api_key=...          # same shell (or same command) as apply
terraform init
terraform plan                                 # expect: Plan: 64 to add, 0 to change, 0 to destroy.
terraform apply
```

`apply` takes about 15 minutes, 10 of them for the EKS cluster. Run it in the background or with a long timeout, and watch for `Error` lines.

If `apply` fails partway, read the first error, not the last. A Helm `context deadline exceeded` is usually a symptom of something earlier, such as nodes that couldn't pull images.

## Verify, in this order

```bash
$(terraform output -raw configure_kubectl)
kubectl get nodes                                   # >= 1 Ready, OS Bottlerocket
kubectl -n flux-system get fluxinstance             # READY True
kubectl -n flux-system get helmreleases             # see the expected states below
kubectl -n groundcover get ds groundcover-sensor    # desired == ready == number of nodes
kubectl -n otel-demo get pods                       # all Running
```

What normal looks like:

| Time after apply | groundcover | otel-demo |
|---|---|---|
| 0 to 2 min | `Unknown`, "Running 'install' action" | `False`, "dependency 'flux-system/groundcover' is not ready" (expected) |
| about 2 min | `True` | `Unknown`, installing |
| about 5 to 10 min | `True` | `True` |

To wait instead of polling:

```bash
kubectl -n flux-system wait helmrelease/groundcover --for=condition=Ready --timeout=15m
kubectl -n flux-system wait helmrelease/otel-demo   --for=condition=Ready --timeout=15m
```

To open the storefront, run the port-forward in the background, wait until it prints `Forwarding from`, and only then `curl` it. Curling right away returns `000`.

```bash
kubectl -n otel-demo port-forward svc/frontend-proxy 8080:8080
# http://localhost:8080  /loadgen/  /feature/  /api/products should all return 200
```

If you have the groundcover MCP server, confirm telemetry arrived. Pick the workspace whose backend matches the BYOC endpoint, and filter on `cluster:<cluster_name>`. Expect traces with `source` values `eBPF`, `opentelemetry` and `envoy`; logs from `otel-demo`; `groundcover_kube_*` metrics; and profiles for otel-demo workloads.

## These look alarming but are normal

- **Node churn for 5 to 10 minutes after rollout.** Auto Mode consolidates nodes: you'll see events like `Evicted pod: Underutilized` and `DisruptionTerminating`, nodes being created and removed, and a DaemonSet briefly showing `desired` = nodes + 1. It settles on its own. Check that nothing stays `Pending`.
- **Short-lived warnings on new nodes:** `NetworkNotReady`, `cni plugin not initialized`, `FailedMount ... not registered`, readiness probe failures. These clear within a minute or two as the node initializes.
- **The sensor logs `fetchPVCsMetrics ... context deadline exceeded`.** A kubelet scrape timed out against a node that was being removed. Harmless if it's occasional.
- **`kubectl top` says `Metrics API not available`.** Auto Mode doesn't install metrics-server. Use groundcover for resource usage.

## Known failures and fixes

| Symptom | Cause | Fix |
|---|---|---|
| `AddressLimitExceeded` or `VpcLimitExceeded` | Region quota is full | `./scripts/destroy.sh`, then switch region (changing `region` on a live deployment doesn't move it; destroy first) |
| A DaemonSet pod stays `Pending` with `Insufficient memory` | Auto Mode never adds nodes for DaemonSet pods | Add `priorityClassName: system-node-critical` to that DaemonSet's values. The bundled otel-demo profiler already has it |
| `apply` prompts for `var.groundcover_api_key` | The variable isn't in this process's environment | Export it in the same shell or command as `apply` |
| `Unauthorized` from kubectl or Helm | A different AWS identity than the one that created the cluster | Switch identity, or add the ARN to `admin_principal_arns` |
| `ExpiredToken` | SSO session expired mid-run | `aws sso login`, then re-run `apply`; it resumes from state |
| HelmRelease `groundcover` stays `False` | Wrong BYOC endpoint or an invalid key | Check `groundcover_byoc_endpoint` (hostname only), re-export the key, bump `groundcover_api_key_revision`, re-apply |

## Making changes to the kit

Validate before committing:

```bash
terraform fmt -check -recursive
terraform validate
helm template t charts/flux-apps -n flux-system \
  --set groundcover.chartVersion=X --set groundcover.site=x --set groundcover.clusterId=x \
  --set otelDemo.chartVersion=X
helm template t open-telemetry/opentelemetry-demo --version <ver> -f values/otel-demo.yaml   # after editing demo values
```

When bumping versions, keep `kubernetes_version` inside the range the pinned Flux version supports. Flux release notes list it under "Kubernetes compatibility".
