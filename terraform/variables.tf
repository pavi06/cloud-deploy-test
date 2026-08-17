# ---------------------------------------------------------------------------
# Input variables
# ---------------------------------------------------------------------------

variable "prefix" {
  description = "Short name prefix for all resources (lowercase letters/numbers only; used for globally-unique names like the ACR)."
  type        = string
  default     = "pavdevopsagnt"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{2,17}$", var.prefix))
    error_message = "prefix must be 3-18 chars, lowercase letters/numbers, starting with a letter (ACR name rules)."
  }
}

variable "location" {
  description = "Azure region to deploy into."
  type        = string
  default     = "eastus"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    created_by  = "pavithrap@presidio.com"
    application = "devops-cloud-explainer-agent"
    managed_by  = "terraform"
  }
}

# ---- Container image -------------------------------------------------------

variable "backend_source_path" {
  description = "Path to the backend directory (contains the Dockerfile) relative to this Terraform config, or absolute."
  type        = string
  default     = "../backend"
}

variable "image_name" {
  description = "Repository/name of the image inside the registry."
  type        = string
  default     = "agentic-api"
}

# ---- Networking ------------------------------------------------------------

variable "vnet_address_space" {
  description = "Address space for the virtual network."
  type        = list(string)
  default     = ["10.10.0.0/16"]
}

variable "infra_subnet_prefix" {
  description = "CIDR for the Container Apps infrastructure subnet. A Consumption-only environment requires at least a /23."
  type        = string
  default     = "10.10.0.0/23"
}

# ---- Scaling ---------------------------------------------------------------

variable "min_replicas" {
  description = "Minimum replicas. 1 avoids cold starts; set 0 to scale to zero and save cost when idle."
  type        = number
  default     = 1
}

variable "max_replicas" {
  description = "Maximum replicas the app can scale out to."
  type        = number
  default     = 3
}

variable "cpu" {
  description = "vCPU per replica (Consumption profile allows 0.25-2.0 in 0.25 steps)."
  type        = number
  default     = 0.5
}

variable "memory" {
  description = "Memory per replica. Must pair with cpu (0.5 vCPU -> 1Gi)."
  type        = string
  default     = "1Gi"
}

# ---- Application settings (Azure OpenAI) ------------------------------------

variable "azure_openai_endpoint" {
  description = "Azure OpenAI endpoint, e.g. https://my-resource.openai.azure.com/"
  type        = string
}

variable "azure_openai_api_key" {
  description = "Azure OpenAI API key. Stored as a Container App secret, never in plaintext env."
  type        = string
  sensitive   = true
}

variable "azure_openai_deployment" {
  description = "Azure OpenAI deployment (model) name, e.g. gpt-5."
  type        = string
  default     = "gpt-5"
}

variable "azure_openai_api_version" {
  description = "Azure OpenAI API version."
  type        = string
  default     = "2024-10-21"
}
