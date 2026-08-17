# Deploy the FastAPI agent to Azure Container Apps

Terraform that builds the backend container image, pushes it to an Azure
Container Registry, and runs it on a **VNet-integrated Azure Container Apps**
environment. Everything uses **Basic / Consumption** tiers — no Premium or
Dedicated features.

## What gets created

| Resource | Purpose | Tier |
| --- | --- | --- |
| Resource group | Holds everything | — |
| Virtual network + subnet | Container Apps run inside your VNet; subnet is delegated to `Microsoft.App/environments` | — |
| Log Analytics workspace | Logs/metrics for the environment (required) | PerGB2018 |
| Azure Container Registry | Stores the image; `admin_enabled = false` | **Basic** |
| User-assigned managed identity | App pulls from ACR with `AcrPull` — no stored passwords | — |
| Container Apps environment | Consumption profile, VNet-integrated | **Consumption** |
| Container App | The FastAPI backend, public HTTPS ingress on port 8000 | — |

### Best practices baked in
- **Managed-identity pull** from ACR (registry admin user disabled, no credentials in state beyond the OpenAI key).
- **API key stored as a Container App secret**, referenced by env — not plaintext.
- **VNet integration** with a dedicated, delegated subnet.
- **Server-side image build** via `az acr build` — no local Docker daemon needed, and the build toolchain never touches your machine.
- **Liveness (`/health`) and readiness (`/ready`) probes** wired to the app's real endpoints.
- **HTTP autoscaling** (scale on concurrent requests); set `min_replicas = 0` to scale to zero when idle.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (`az`) — used both for auth and for the server-side image build
- An Azure subscription with permission to create the resources above and to
  assign roles (Owner or User Access Administrator on the target scope)
- An existing **Azure OpenAI** resource with a deployed model (e.g. `gpt-4o-mini`)

## Setup

### 1. Authenticate

```bash
az login
az account set --subscription "<your-subscription-id>"
```

### 2. Configure variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set at least:

```hcl
azure_openai_endpoint   = "https://your-resource.openai.azure.com/"
azure_openai_api_key    = "your-azure-openai-key"
azure_openai_deployment = "gpt-4o-mini"
```

> `terraform.tfvars` is gitignored. Keep the API key out of version control.

### 3. Deploy

```bash
terraform init
terraform plan
terraform apply
```

`apply` will:
1. Create the registry, network, identity, and environment.
2. Run `az acr build` to build the image from `../backend/Dockerfile` **inside**
   the registry and push it as `agentic-api:v1`.
3. Start the Container App and expose it over HTTPS.

Typical first run takes a few minutes (the ACR build dominates).

### 4. Use it

Terraform prints the URLs on success:

```bash
terraform output app_url        # https://<app>.<region>.azurecontainerapps.io
terraform output app_docs_url   # Swagger UI at /docs
```

Try it:

```bash
APP=$(terraform output -raw app_url)

curl "$APP/health"      # {"status":"healthy"}
curl "$APP/ready"       # env + Azure reachability check

curl -X POST "$APP/ask" \
  -H "Content-Type: application/json" \
  -d '{"question":"What is a Kubernetes pod?"}'
```

## Deploying a new version of the app

Change the code in `../backend`, then bump the tag and re-apply:

```bash
terraform apply -var="image_tag=v2"
```

The build reruns automatically when the Dockerfile, `requirements.txt`, or the
Python source change. Using a unique tag per release (e.g. a git SHA) gives you
immutable, rollback-friendly revisions.

## Common overrides

| Variable | Default | Notes |
| --- | --- | --- |
| `prefix` | `devopsagent` | Name prefix; must be 3–18 lowercase alphanumerics (ACR rule) |
| `location` | `eastus` | Azure region |
| `min_replicas` | `1` | Set `0` to scale to zero (saves cost, adds cold starts) |
| `max_replicas` | `3` | Upper scale-out bound |
| `cpu` / `memory` | `0.5` / `1Gi` | Must be a valid Consumption pair (e.g. 0.25→0.5Gi, 0.5→1Gi, 1→2Gi) |
| `infra_subnet_prefix` | `10.10.0.0/23` | Consumption environments need at least a `/23` |

Example:

```bash
terraform apply -var="min_replicas=0" -var="location=westeurope"
```

## Notes & gotchas

- **Subnet size:** a Consumption-only environment requires a subnet of at least
  `/23`. The default VNet/subnet leave room; adjust `vnet_address_space` and
  `infra_subnet_prefix` if they clash with existing networks.
- **Public vs private:** the app is publicly reachable over HTTPS
  (`internal_load_balancer_enabled = false`). To make it internal-only, set that
  to `true` — you'll then need private DNS / a jump host to reach it, so it's
  left public for the demo.
- **Role propagation:** a 30s `time_sleep` gives the `AcrPull` assignment time to
  propagate before the app authenticates. If the first apply ever fails on an
  image pull, just re-run `terraform apply`.
- **CORS** is wide open (`*`) in the app itself — fine for a demo, tighten in
  `../backend/main.py` for production.

## Clean up

```bash
terraform destroy
```

This removes every resource above, including the registry and its images.
