# --- Azure ------------------------------------------------------------------

variable "subscription_id" {
  description = "Azure subscription ID (az account show --query id -o tsv)."
  type        = string
}

variable "tenant_id" {
  description = "Azure tenant ID (az account show --query tenantId -o tsv)."
  type        = string
}

variable "project_name" {
  description = "Prefijo de nombres de los recursos de Azure."
  type        = string
  default     = "pablodevops"
}

variable "environment" {
  description = "Sufijo de entorno de los recursos de Azure."
  type        = string
  default     = "k3s"
}

variable "location" {
  description = "Región de Azure."
  type        = string
  default     = "eastus"
}

variable "key_vault_allowed_cidrs" {
  description = "IPs públicas (CIDR) que pueden llegar al Key Vault: la IP de salida del nodo k3s y la tuya. Vacío = acceso público abierto (solo protegido por RBAC)."
  type        = list(string)
  default     = []
}

variable "db_password" {
  description = "Contraseña de Postgres que se guarda en Key Vault como 'db-password'. Pásala con TF_VAR_db_password, nunca en terraform.tfvars."
  type        = string
  sensitive   = true
}

variable "tags" {
  description = "Tags aplicados a los recursos de Azure."
  type        = map(string)
  default = {
    managed_by = "terraform"
    layer      = "kubernetes-digital-ocean"
  }
}

# --- k3s --------------------------------------------------------------------

variable "kubeconfig_path" {
  description = "Ruta al kubeconfig del cluster k3s."
  type        = string
  default     = "~/.kube/config"
}

variable "kubeconfig_context" {
  description = "Contexto del kubeconfig que apunta al k3s (kubectl config get-contexts). null = el contexto actual."
  type        = string
  default     = null
}

variable "app_namespace" {
  description = "Namespace donde corre la app y donde viven el SecretStore/ExternalSecret (debe coincidir con external-secret-db.yaml)."
  type        = string
  default     = "default"
}

variable "external_secrets_chart_version" {
  description = "Versión del chart Helm de External Secrets Operator."
  type        = string
  default     = "2.12.0"
}
