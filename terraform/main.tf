# ===========================================================================
# DevOps & Cloud Explainer Agent — FastAPI on Azure Container Apps
#
# Builds the backend image (server-side, via `az acr build`), pushes it to a
# Basic Azure Container Registry, and runs it on a VNet-integrated Container
# Apps environment (Consumption profile — no Premium/Dedicated features).
# ===========================================================================

locals {
  # Suffix keeps globally-unique names (ACR) stable per resource group.
  suffix   = substr(sha256(azurerm_resource_group.this.id), 0, 6)
  acr_name = "${var.prefix}acr${local.suffix}"

  # Generate a new immutable image tag whenever one of these application
  # files changes.
  source_hash = substr(
    sha256(
      join("", [
        filesha256("${var.backend_source_path}/Dockerfile"),
        filesha256("${var.backend_source_path}/requirements.txt"),
        filesha256("${var.backend_source_path}/main.py"),
        filesha256("${var.backend_source_path}/agent.py"),
        filesha256("${var.backend_source_path}/websearch.py"),
      ])
    ),
    0,
    12
  )
  
  image    = "${var.image_name}:${local.source_hash}"
}

# ---------------------------------------------------------------------------
# Resource group
# ---------------------------------------------------------------------------
resource "azurerm_resource_group" "this" {
  name     = "${var.prefix}-rg"
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Networking — VNet with a subnet delegated to the Container Apps environment
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "this" {
  name                = "${var.prefix}-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = var.vnet_address_space
  tags                = var.tags
}

resource "azurerm_subnet" "infra" {
  name                 = "container-apps-infra"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.infra_subnet_prefix]

  # The Container Apps environment owns this subnet.
  delegation {
    name = "container-apps-delegation"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# ---------------------------------------------------------------------------
# Log Analytics — required backing store for the Container Apps environment
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "this" {
  name                = "${var.prefix}-logs"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Azure Container Registry (Basic SKU — no Premium features)
# admin_enabled = false: the app pulls with a managed identity, not a password.
# ---------------------------------------------------------------------------
resource "azurerm_container_registry" "this" {
  name                = local.acr_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = "Basic"
  admin_enabled       = false
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# User-assigned managed identity for the app to pull from ACR
# (best practice: no registry username/password stored anywhere)
# ---------------------------------------------------------------------------
resource "azurerm_user_assigned_identity" "app" {
  name                = "${var.prefix}-app-id"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_role_assignment" "acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.app.principal_id
}

# Give the AcrPull role assignment a moment to propagate before the app tries
# to authenticate to the registry.
resource "time_sleep" "role_propagation" {
  depends_on      = [azurerm_role_assignment.acr_pull]
  create_duration = "60s"
}

# ---------------------------------------------------------------------------
# Build and push the application image
#
# The source hash is part of the image name. Whenever one of the application
# files changes:
#
# 1. local.source_hash changes.
# 2. local.image changes.
# 3. This null_resource is replaced.
# 4. A new Docker image is built and pushed.
# 5. Container Apps detects the new image tag and creates a new revision.
# ---------------------------------------------------------------------------

resource "null_resource" "build_push" {
  triggers = {
    image      = local.image
    dockerfile = filesha256("${var.backend_source_path}/Dockerfile")
    requires   = filesha256("${var.backend_source_path}/requirements.txt")
    main       = filesha256("${var.backend_source_path}/main.py")
    agent      = filesha256("${var.backend_source_path}/agent.py")
    websearch  = filesha256("${var.backend_source_path}/websearch.py")
  }

  provisioner "local-exec" {
    command = "az acr build --registry ${azurerm_container_registry.this.name} --image ${local.image} --file ${var.backend_source_path}/Dockerfile ${var.backend_source_path}"
  }

  depends_on = [azurerm_container_registry.this]
}

# ---------------------------------------------------------------------------
# Container Apps environment — VNet-integrated, Consumption only
# (no workload_profile block = Consumption; internal LB disabled = public app)
# ---------------------------------------------------------------------------
resource "azurerm_container_app_environment" "this" {
  name                       = "${var.prefix}-env"
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  infrastructure_subnet_id       = azurerm_subnet.infra.id
  internal_load_balancer_enabled = false

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Container App — the FastAPI backend
# ---------------------------------------------------------------------------
resource "azurerm_container_app" "this" {
  name                         = "${var.prefix}-api"
  resource_group_name          = azurerm_resource_group.this.name
  container_app_environment_id = azurerm_container_app_environment.this.id
  revision_mode                = "Single"
  tags                         = var.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.app.id]
  }

  # Pull from ACR using the managed identity (no stored credentials).
  registry {
    server   = azurerm_container_registry.this.login_server
    identity = azurerm_user_assigned_identity.app.id
  }

  secret {
    name  = "azure-openai-api-key"
    value = var.azure_openai_api_key
  }

  template {
    min_replicas = var.min_replicas
    max_replicas = var.max_replicas

    container {
      name   = "api"
      image  = "${azurerm_container_registry.this.login_server}/${local.image}"
      cpu    = var.cpu
      memory = var.memory

      env {
        name  = "AZURE_OPENAI_ENDPOINT"
        value = var.azure_openai_endpoint
      }
      env {
        name        = "AZURE_OPENAI_API_KEY"
        secret_name = "azure-openai-api-key"
      }
      env {
        name  = "AZURE_OPENAI_DEPLOYMENT"
        value = var.azure_openai_deployment
      }
      env {
        name  = "AZURE_OPENAI_API_VERSION"
        value = var.azure_openai_api_version
      }

      # Liveness: the process is up (always 200 while running).
      liveness_probe {
        transport = "HTTP"
        path      = "/health"
        port      = 8000
      }

      # Readiness: required env set and Azure reachable (503 until ready).
      readiness_probe {
        transport = "HTTP"
        path      = "/ready"
        port      = 8000
      }
    }

    # Simple HTTP autoscaling rule — scale on concurrent requests.
    http_scale_rule {
      name                = "http-concurrency"
      concurrent_requests = 50
    }
  }

  # Public HTTPS ingress on the app's port 8000.
  ingress {
    external_enabled = true
    target_port      = 8000
    transport        = "auto"

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  # Deploy the application only after:
  # 1. The image has been built and pushed.
  # 2. The AcrPull permission has had time to propagate.
  depends_on = [
    null_resource.build_push,
    time_sleep.role_propagation,
  ]
}
