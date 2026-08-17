output "resource_group_name" {
  description = "Name of the created resource group."
  value       = azurerm_resource_group.this.name
}

output "acr_login_server" {
  description = "Login server of the Azure Container Registry."
  value       = azurerm_container_registry.this.login_server
}

output "image_reference" {
  description = "Fully-qualified image that the app runs."
  value       = "${azurerm_container_registry.this.login_server}/${local.image}"
}

output "app_url" {
  description = "Public HTTPS URL of the FastAPI app."
  value       = "https://${azurerm_container_app.this.ingress[0].fqdn}"
}

output "app_docs_url" {
  description = "Swagger UI for the API."
  value       = "https://${azurerm_container_app.this.ingress[0].fqdn}/docs"
}
