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

## Step-by-step: from zero to deployed

These are the exact commands, in order, to set up, build the container image,
and provision everything. Run them from the repo root.

### 1. Authenticate to Azure

```bash
az login                                        # opens a browser
az account set --subscription "<your-subscription-id>"
az account show                                 # confirm the right subscription
```

### 2. Configure variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and set at least:

```hcl
prefix                  = "yourprefix"          # lowercase, 3-18 chars
location                = "eastus"
azure_openai_endpoint   = "https://your-resource.openai.azure.com/"
azure_openai_api_key    = "your-azure-openai-key"
azure_openai_deployment = "gpt-5"
```

> `terraform.tfvars` is gitignored. Keep the API key out of version control.

### 3. Initialize Terraform

```bash
terraform init                                  # downloads the azurerm provider
```

### 4. Review the plan

```bash
terraform plan                                  # shows everything that will be created
```

### 5. Provision + build + push (one command)

```bash
terraform apply                                 # type "yes" to confirm
```

`apply` does the whole flow in dependency order:
1. Creates the resource group, VNet/subnet, Log Analytics, ACR, and the
   user-assigned identity (with the `AcrPull` role).
2. Runs the **server-side container build** — no local Docker needed:
   ```bash
   az acr build \
     --registry <prefix>acr<suffix> \
     --image agentic-api:<source-hash> \
     --file ../backend/Dockerfile \
     ../backend
   ```
   The tag is a hash of the app source, so a new image is built and pushed
   automatically whenever the code changes.
3. Creates the Container Apps environment and the Container App, which pulls
   the freshly-pushed image and exposes it over public HTTPS.

Typical first run takes a few minutes (the ACR build dominates).

> **Note on the `--file` path:** it's `../backend/Dockerfile`, relative to the
> `terraform/` directory where the provisioner runs — not just `Dockerfile`.
> `az acr build` resolves `--file` against the current working directory, so a
> bare `Dockerfile` would fail with `Unable to find 'Dockerfile'`.

### 6. Use it

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

Just change the code in `../backend` and re-apply — no manual tag bump needed:

```bash
terraform apply
```

The image tag is a **content hash** of the app source (`Dockerfile`,
`requirements.txt`, `main.py`, `agent.py`, `websearch.py`). When any of those
files change, the hash changes, `az acr build` reruns, a new immutable image is
pushed, and the Container App rolls out a new revision. Unchanged source =
no rebuild.

To force a rebuild without changing code (e.g. after fixing the build itself):

```bash
terraform apply -replace=null_resource.build_push
```

## Common overrides

| Variable | Default | Notes |
| --- | --- | --- |
| `prefix` | `pavdevopsagnt` | Name prefix; must be 3–18 lowercase alphanumerics starting with a letter (ACR rule) |
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
