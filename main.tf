# Recursos de Azure para servir los secretos de la app al cluster k3s:
# Resource Group + Key Vault (modo RBAC) + secreto de la DB + un Service
# Principal de solo lectura que usa External Secrets Operator (ESO).
#
# Por qué Service Principal con client secret y no Workload Identity: k3s no
# corre en Azure y su service-account issuer no está publicado como OIDC
# issuer público, así que Entra ID no puede federarse con él. El client secret
# del SP es el "secreto cero" y solo vive en el state y en el cluster
# (kubernetes.tf), nunca en git.

locals {
  name_prefix = "${var.project_name}-${var.environment}"
}

data "azurerm_client_config" "current" {}

resource "random_string" "kv_suffix" {
  length  = 4
  special = false
  upper   = false
}

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name_prefix}"
  location = var.location
  tags     = var.tags
}

# --- Key Vault --------------------------------------------------------------

resource "azurerm_key_vault" "this" {
  # Nombre global único, máx. 24 caracteres.
  name                       = substr("kv-${local.name_prefix}-${random_string.kv_suffix.result}", 0, 24)
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = var.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
  soft_delete_retention_days = 7
  tags                       = var.tags

  network_acls {
    default_action = length(var.key_vault_allowed_cidrs) > 0 ? "Deny" : "Allow"
    bypass         = "AzureServices"
    ip_rules       = var.key_vault_allowed_cidrs
  }
}

# Quien corre terraform apply necesita escribir secrets (vault en modo RBAC).
resource "azurerm_role_assignment" "kv_secrets_officer_current_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# Se guarda en base64 (sin salto de línea al final); el ExternalSecret lo
# decodifica con decodingStrategy: Base64 antes de crear db-secret.
# base64 NO cifra: el valor sigue legible en el state de este folder.
resource "azurerm_key_vault_secret" "db_password" {
  name         = "db-password"
  value        = base64encode(var.db_password)
  key_vault_id = azurerm_key_vault.this.id
  content_type = "base64"

  # El RBAC de Azure tarda en propagarse; sin esto el primer apply puede dar 403.
  depends_on = [azurerm_role_assignment.kv_secrets_officer_current_user]
}

# --- Service Principal de solo lectura para ESO -----------------------------

resource "azuread_application" "eso" {
  display_name = "sp-eso-${local.name_prefix}"
  owners       = [data.azurerm_client_config.current.object_id]
}

resource "azuread_service_principal" "eso" {
  client_id = azuread_application.eso.client_id
  owners    = [data.azurerm_client_config.current.object_id]
}

# Sin end_date explícito Entra ID le da 2 años; para rotarlo:
#   terraform apply -replace=azuread_application_password.eso
resource "azuread_application_password" "eso" {
  application_id = azuread_application.eso.id
  display_name   = "eso-k3s"
}

resource "azurerm_role_assignment" "eso_kv_secrets_user" {
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azuread_service_principal.eso.object_id
  principal_type       = "ServicePrincipal"
}
