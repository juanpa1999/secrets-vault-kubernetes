# Lo que Terraform pone en el cluster k3s: el operador ESO y el Secret con las
# credenciales del Service Principal. El SecretStore y el ExternalSecret NO van
# aquí (sus CRDs no existen hasta que ESO se instala, y kubernetes_manifest
# falla en el plan): viven en external-secret-db.yaml.

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.external_secrets_chart_version
  namespace        = "external-secrets"
  create_namespace = true

  set {
    name  = "installCRDs"
    value = "true"
  }
}

# Referenciado por spec.provider.azurekv.authSecretRef del SecretStore.
resource "kubernetes_secret_v1" "azure_kv_sp" {
  metadata {
    name      = "azure-kv-sp"
    namespace = var.app_namespace
  }

  type = "Opaque"

  data = {
    ClientID     = azuread_application.eso.client_id
    ClientSecret = azuread_application_password.eso.value
  }
}
