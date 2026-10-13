output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  description = "Va en spec.provider.azurekv.vaultUrl del SecretStore (placeholder __KEY_VAULT_URL__)."
  value       = azurerm_key_vault.this.vault_uri
}

output "tenant_id" {
  description = "Va en spec.provider.azurekv.tenantId del SecretStore (placeholder __TENANT_ID__)."
  value       = var.tenant_id
}

output "eso_client_id" {
  description = "Client ID del Service Principal de ESO (ya está en el Secret azure-kv-sp del cluster)."
  value       = azuread_application.eso.client_id
}

output "apply_external_secret_command" {
  description = "Renderiza los placeholders de external-secret-db.yaml y lo aplica al cluster."
  value       = "sed -e 's|__KEY_VAULT_URL__|${azurerm_key_vault.this.vault_uri}|' -e 's|__TENANT_ID__|${var.tenant_id}|' external-secret-db.yaml | kubectl apply -f -"
}
