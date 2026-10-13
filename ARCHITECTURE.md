# Arquitectura

Este documento describe cómo está armado el despliegue y por qué. Para los pasos de
uso, ver [README.md](README.md).

## Visión general

Hay dos planos:

- **Plano de aplicación (cluster k3s)**: frontend, backend y PostgreSQL, cada uno como
  `Deployment` de 1 réplica con su `Service`.
- **Plano de secretos (Azure + ESO)**: la contraseña de la base vive en un Azure Key
  Vault; External Secrets Operator, corriendo en el k3s, la lee con un Service
  Principal de solo lectura y la materializa como un `Secret` nativo (`db-secret`) que
  consume el backend.

```
                         ┌──────────────────────── Azure ────────────────────────┐
                         │  rg-pablodevops-k3s                                   │
                         │                                                       │
 terraform apply ───────►│  Key Vault (RBAC)            Entra ID                 │
 (TF_VAR_db_password)    │   └─ secret "db-password"     └─ App/SP sp-eso-...    │
                         │       (base64)                    rol: Key Vault      │
                         │          ▲                        Secrets User        │
                         └──────────┼────────────────────────────────────────────┘
                                    │ HTTPS (client credentials)
 ┌──────────────────────────────────┼──────────────── cluster k3s ───────────────┐
 │                                  │                                            │
 │  ns external-secrets             │          ns default                        │
 │  ┌───────────────────┐           │  ┌──────────────────────────────────────┐  │
 │  │ ESO (Helm release)│───────────┘  │ Secret azure-kv-sp (ClientID/Secret) │  │
 │  └─────────┬─────────┘   usa ──────►│ SecretStore azure-kv                 │  │
 │            │                        │ ExternalSecret db-secret             │  │
 │            └──── crea/refresca ────►│ Secret db-secret (DB_PASSWORD)       │  │
 │                                     └──────────────────┬───────────────────┘  │
 │                                                        │ secretKeyRef         │
 │   localhost:3000 (pf)          localhost:8000 (pf)     │                      │
 │        │                             │                 │                      │
 │        ▼                             ▼                 ▼                      │
 │  front-service NodePort 32000   back-service NodePort 32001                   │
 │        │                             │                                        │
 │        ▼                             ▼                                        │
 │  front-deploy (front4)  ──HTTP──► back-deployment (back3)                     │
 │                                      │ DB_HOST=db-service                     │
 │                                      ▼                                        │
 │                              db-service ClusterIP :5432                       │
 │                                      │                                        │
 │                                      ▼                                        │
 │                              db-deployment (db1, PostgreSQL, sin PVC)         │
 └───────────────────────────────────────────────────────────────────────────────┘
```

## Plano de aplicación

| Recurso           | Tipo       | Imagen              | Exposición                     | Notas                                 |
|-------------------|------------|---------------------|--------------------------------|---------------------------------------|
| `front-deploy`    | Deployment | `jpcc141999/front4` | `front-service` NodePort 32000 | —                                     |
| `back-deployment` | Deployment | `jpcc141999/back3`  | `back-service` NodePort 32001  | `DB_HOST`, `NGROK`, `DB_PASSWORD`     |
| `db-deployment`   | Deployment | `jpcc141999/db1`    | `db-service` ClusterIP 5432    | Sin volumen; credenciales en la imagen|

- El descubrimiento entre componentes es por DNS de Service (`db-service`,
  `front-service`), todo en el namespace `default`.
- El esquema lo gestiona el backend con Alembic (`alembic upgrade head`), ejecutado por
  `up.sh` vía `kubectl exec` — no hay `Job` ni init container de migración.
- El acceso externo es por `kubectl port-forward` (o NodePort directo). No hay Ingress
  ni TLS.

## Plano de secretos

### Qué crea Terraform

Terraform vive en la raíz del repo, tiene **state local** y es autocontenido: crea
todos sus recursos de Azure y no depende de las capas `bootstrap`/`application` del
repo padre (que apuntan a AKS, no a este k3s).

| Archivo         | Recursos                                                                 |
|-----------------|--------------------------------------------------------------------------|
| `main.tf`       | `azurerm_resource_group`, `azurerm_key_vault` (RBAC), `azurerm_key_vault_secret.db_password`, `azuread_application`/`service_principal`/`application_password` de ESO, role assignments |
| `kubernetes.tf` | `helm_release.external_secrets` (ns `external-secrets`), `kubernetes_secret_v1.azure_kv_sp` |
| `outputs.tf`    | `key_vault_uri`, `tenant_id`, `eso_client_id`, `apply_external_secret_command` |

Role assignments:

- Quien corre `terraform apply` → **Key Vault Secrets Officer** (necesario para escribir
  el secreto con el vault en modo RBAC).
- Service Principal de ESO → **Key Vault Secrets User** (solo lectura), con scope al
  vault.

### Flujo del secreto

1. `TF_VAR_db_password` → Terraform lo guarda en Key Vault como `db-password`,
   codificado en base64.
2. Terraform crea el SP de ESO y escribe sus credenciales en el Secret `azure-kv-sp`
   del namespace de la app.
3. `apply_external_secret_command` sustituye `__TENANT_ID__` y `__KEY_VAULT_URL__` en
   `external-secret-db.yaml` con `sed` y lo aplica.
4. El `SecretStore azure-kv` autentica contra Entra ID con `azure-kv-sp`; el
   `ExternalSecret db-secret` lee `db-password`, lo decodifica (`decodingStrategy:
   Base64`) y crea el Secret `db-secret` con la clave `DB_PASSWORD`
   (`creationPolicy: Owner`, refresco cada 1 h).
5. `back-deployment` monta `DB_PASSWORD` vía `secretKeyRef`.

### Orden de despliegue

```
terraform apply            → Azure (RG, KV, secreto, SP) + ESO + azure-kv-sp
kubectl apply dp-db.yaml
render + apply external-secret-db.yaml → wait Ready → db-secret existe
kubectl apply dp-back.yaml (necesita db-secret) y dp-front.yaml
pg_isready → alembic upgrade head → seed SQL → port-forward
```

## Decisiones de diseño

### Service Principal con client secret en vez de Workload Identity

k3s no corre en Azure y el issuer de sus service accounts no está publicado como OIDC
issuer público, así que Entra ID no puede federarse con él. El client secret del SP es
el "secreto cero": vive solo en el state de Terraform y en el Secret `azure-kv-sp` del
cluster, nunca en git.

- Tradeoff: es una credencial de larga duración (2 años por defecto) que hay que rotar
  (`terraform apply -replace=azuread_application_password.eso`).
- Alternativa: publicar el issuer OIDC de k3s (discovery doc + JWKS en un endpoint
  público) y usar federated credentials — elimina el secreto, pero agrega
  infraestructura que mantener.

### `SecretStore`/`ExternalSecret` fuera de Terraform

Los CRDs de ESO no existen hasta que el Helm release se instala, y
`kubernetes_manifest` necesita los CRDs en tiempo de `plan`. Por eso esos dos objetos
están en `external-secret-db.yaml` y se aplican con `kubectl` después del `apply`,
renderizando los valores dinámicos desde los outputs.

### Secreto en base64 dentro del Key Vault

El valor se guarda como `base64encode(var.db_password)` y ESO lo decodifica. Evita
problemas con caracteres especiales y saltos de línea; **no** es cifrado — el valor
sigue legible en el state.

### Key Vault de práctica

`purge_protection_enabled = false`, `soft_delete_retention_days = 7` y
`purge_soft_delete_on_destroy = true` permiten destruir y recrear el vault con el mismo
nombre. Para un entorno real habría que activar purge protection.

## Seguridad

| Aspecto                       | Estado actual                                                         |
|-------------------------------|-----------------------------------------------------------------------|
| Secretos en git               | Ninguno: `terraform.tfvars`, `*.tfstate`, `secret_db.yaml` en `.gitignore` |
| State de Terraform            | Local, contiene `db_password` (base64) y el client secret del SP       |
| Acceso de red al Key Vault    | Abierto si `key_vault_allowed_cidrs = []`; con CIDRs → `Deny` por defecto |
| Privilegios del SP            | Solo lectura de secretos, scope a un único vault                       |
| Credenciales de PostgreSQL    | Embebidas en la imagen `db1`; deben coincidir con `db-password`        |
| Exposición de la app          | NodePort sin TLS; acceso pensado vía port-forward                      |

## Limitaciones y siguientes pasos

| Limitación                                   | Posible mejora                                               |
|----------------------------------------------|--------------------------------------------------------------|
| PostgreSQL sin persistencia                  | `StatefulSet` + PVC (`local-path` de k3s)                    |
| Contraseña de la DB duplicada (imagen + KV)  | Que `db-deployment` también lea `POSTGRES_PASSWORD` de `db-secret` |
| State local con secretos                     | Backend remoto (Azure Blob) con acceso restringido           |
| Imágenes sin tag (`latest`)                  | Tags inmutables o digest                                     |
| Sin probes ni `resources`                    | `readinessProbe`/`livenessProbe` y requests/limits; quitar los `sleep` de `up.sh` |
| Migraciones por `kubectl exec`               | `Job` de Alembic o init container                            |
| Despliegue imperativo (`up.sh`)              | Pasar los manifiestos al flujo GitOps/ArgoCD del repo padre  |
| Namespace `default` hardcodeado              | Namespace dedicado, parametrizado igual que `app_namespace`  |
