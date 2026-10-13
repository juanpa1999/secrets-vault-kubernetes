# kubernetes-Digital-ocean

Despliegue de una aplicación de monitoreo de sensores (temperatura, humedad y peso) de
tres capas — **frontend**, **backend** y **PostgreSQL** — sobre un cluster **k3s**.
Las imágenes vienen de Docker Hub (`jpcc141999/*`); este repo no contiene código de
aplicación, solo el despliegue:

- **Manifiestos de Kubernetes** (`dp-*.yaml`) para los tres componentes.
- **Terraform** (raíz del repo) que crea en Azure un Key Vault con la contraseña de la
  base de datos y un Service Principal de solo lectura, e instala **External Secrets
  Operator (ESO)** en el cluster para sincronizar ese secreto como `db-secret`.
- **`up.sh`**, que despliega todo, corre migraciones, carga datos de prueba y abre
  port-forwards.

> Aunque el nombre menciona DigitalOcean, el objetivo actual es un cluster **k3s**. Los
> manifiestos no usan nada específico de ningún proveedor; el único acoplamiento a la
> nube es el Key Vault de Azure del que ESO lee el secreto.

El diseño, el flujo del secreto y las decisiones tomadas están en
[ARCHITECTURE.md](ARCHITECTURE.md).

## Componentes

| Componente | Manifiesto      | Imagen              | Puerto | Service                          |
|------------|-----------------|---------------------|--------|----------------------------------|
| Base datos | `dp-db.yaml`    | `jpcc141999/db1`    | 5432   | `db-service` (ClusterIP)         |
| Backend    | `dp-back.yaml`  | `jpcc141999/back3`  | 8000   | `back-service` (NodePort 32001)  |
| Frontend   | `dp-front.yaml` | `jpcc141999/front4` | 3000   | `front-service` (NodePort 32000) |

El backend usa Alembic para las migraciones del esquema, valida contraseñas con bcrypt
(passlib) y recibe `DB_PASSWORD` desde el Secret `db-secret` (creado por ESO).

## Estructura

```
.
├── versions.tf                # Providers: azurerm, azuread, random, kubernetes, helm
├── variables.tf               # Variables (Azure + k3s)
├── main.tf                    # RG, Key Vault (RBAC), secreto db-password, SP de ESO
├── kubernetes.tf              # helm_release de ESO + Secret azure-kv-sp en el cluster
├── outputs.tf                 # URI del vault, tenant, client ID y comando para aplicar el ExternalSecret
├── external-secret-db.yaml    # SecretStore + ExternalSecret (con placeholders) → db-secret
├── dp-db.yaml                 # Deployment + Service de PostgreSQL
├── dp-back.yaml               # Deployment + Service del backend (lee db-secret)
├── dp-front.yaml              # Deployment + Service del frontend
├── up.sh                      # Despliegue completo + migraciones + seed + port-forward
├── sql/
│   └── seed_pablodevops.sql   # Datos de prueba (usuario, sensores, lecturas de 24 h)
└── test/                      # Manifiestos de pruebas iniciales (nginx, front1); no los usa up.sh
```

## Requisitos

- Un cluster **k3s** accesible y `kubectl` apuntando a él
  (`kubectl config current-context`). En el servidor k3s el kubeconfig está en
  `/etc/rancher/k3s/k3s.yaml`.
- Terraform `>= 1.3`.
- Azure CLI con sesión iniciada (`az login`) y permisos para crear un Resource Group,
  un Key Vault, role assignments y una App Registration en Entra ID.
- Acceso a Docker Hub para descargar las imágenes `jpcc141999/*`.

## 1. Infraestructura de secretos (Terraform)

Crea `terraform.tfvars` (está en `.gitignore`) con al menos:

```hcl
subscription_id = "<az account show --query id -o tsv>"
tenant_id       = "<az account show --query tenantId -o tsv>"

# Opcional: restringir el Key Vault a la IP de salida del nodo k3s y la tuya
# key_vault_allowed_cidrs = ["203.0.113.10/32", "198.51.100.7/32"]

# Opcional: si el contexto k3s no es el actual
# kubeconfig_context = "k3s"
```

La contraseña de la base **no** va en `terraform.tfvars`; pásala por variable de
entorno:

```bash
export TF_VAR_db_password='...'
terraform init
terraform apply
```

Esto crea en Azure el Resource Group, el Key Vault, el secreto `db-password` y el
Service Principal de ESO; y en el cluster instala ESO (namespace `external-secrets`) y
el Secret `azure-kv-sp` con las credenciales del SP.

Variables principales (ver `variables.tf`):

| Variable                         | Default            | Descripción                                          |
|----------------------------------|--------------------|------------------------------------------------------|
| `project_name` / `environment`   | `pablodevops`/`k3s`| Prefijo de nombres de recursos (`rg-pablodevops-k3s`)|
| `location`                       | `eastus`           | Región de Azure                                      |
| `key_vault_allowed_cidrs`        | `[]`               | Vacío = vault público, protegido solo por RBAC       |
| `kubeconfig_path`                | `~/.kube/config`   | Kubeconfig del k3s                                   |
| `app_namespace`                  | `default`          | Debe coincidir con `external-secret-db.yaml`         |
| `external_secrets_chart_version` | `2.12.0`           | Versión del chart de ESO                             |

## 2. Despliegue de la aplicación

Desde la raíz del repo, con el `terraform apply` ya hecho:

```bash
./up.sh
```

El script:

1. Aplica `dp-db.yaml`.
2. Renderiza los placeholders de `external-secret-db.yaml` con los outputs de
   Terraform, lo aplica y espera a que el `ExternalSecret` quede `Ready` (es decir, que
   exista `db-secret`).
3. Aplica `dp-back.yaml` y `dp-front.yaml`.
4. Espera a que PostgreSQL acepte conexiones (`pg_isready`).
5. Corre las migraciones en el pod del backend: `alembic upgrade head`.
6. Carga los datos de prueba de `sql/seed_pablodevops.sql`.
7. Abre port-forward de ambos servicios y queda en primer plano:
   - Frontend: <http://localhost:3000>
   - Backend: <http://localhost:8000>

`Ctrl+C` detiene los port-forwards (los recursos siguen corriendo en el cluster).

### Despliegue manual

```bash
kubectl apply -f dp-db.yaml

# SecretStore + ExternalSecret → db-secret
eval "$(terraform output -raw apply_external_secret_command)"
kubectl wait externalsecret/db-secret --for=condition=Ready --timeout=60s

kubectl apply -f dp-back.yaml
kubectl apply -f dp-front.yaml

# esperar a la base de datos
kubectl exec deploy/db-deployment -- pg_isready -U postgres -d postgres

# migraciones + seed
kubectl exec deploy/back-deployment -- alembic upgrade head
kubectl exec -i deploy/db-deployment -- psql -U postgres -d postgres -v ON_ERROR_STOP=1 < sql/seed_pablodevops.sql

# acceso local
kubectl port-forward svc/front-service 3000:3000
kubectl port-forward svc/back-service 8000:8000
```

Como los Services son `NodePort`, también se puede entrar por
`http://<IP-del-nodo>:32000` (front) y `:32001` (back) si el firewall del nodo lo
permite.

## Datos de prueba

`sql/seed_pablodevops.sql` es idempotente (se puede correr varias veces) y crea:

- Usuario `pablodevops` con rol `master` (la contraseña se guarda como hash bcrypt).
- Sensores `101`, `102`, `103`, `201` (activos) y `301` (inactivo).
- Una lectura por hora durante las últimas 24 h (zona horaria `America/Bogota`) para
  temperatura, humedad y peso.

Requiere que el esquema ya exista, es decir, correr antes `alembic upgrade head`.

## Operación

**Rotar la contraseña de la base:** actualizar `TF_VAR_db_password` y `terraform apply`.
ESO refresca `db-secret` cada hora (`refreshInterval: 1h`); para forzarlo antes:

```bash
kubectl annotate externalsecret db-secret force-sync=$(date +%s) --overwrite
kubectl rollout restart deploy/back-deployment   # el pod lee la env var solo al arrancar
```

**Rotar el client secret del Service Principal** (expira a los 2 años):

```bash
terraform apply -replace=azuread_application_password.eso
```

## Limpieza

```bash
kubectl delete -f dp-front.yaml -f dp-back.yaml -f dp-db.yaml
kubectl delete -f external-secret-db.yaml
terraform destroy   # Key Vault (se purga), SP, ESO y el Secret azure-kv-sp
```

## Limitaciones conocidas

- **Sin persistencia**: PostgreSQL corre como `Deployment` sin volumen (PVC); si el pod
  se reinicia se pierden los datos y hay que volver a correr migraciones y seed.
- **Sin alta disponibilidad**: una réplica por componente.
- **Secretos parcialmente centralizados**: solo `DB_PASSWORD` del backend viene de Key
  Vault; el resto de la configuración sigue en claro en los manifiestos y las
  credenciales de la base siguen dentro de la imagen `db1`.
- **Secretos en el state de Terraform**: la contraseña de la DB (en base64, que no es
  cifrado) y el client secret del SP quedan legibles en `terraform.tfstate`, que hoy es
  **local** (gitignored, sin backend remoto).
- **Imágenes sin tag**: se usa `latest` implícito, así que un redeploy puede traer una
  versión distinta.
- **Sin probes ni límites de recursos** (`readinessProbe`, `livenessProbe`,
  `resources`), por eso `up.sh` usa `sleep` y `pg_isready` para esperar.
- Todo se despliega en el namespace `default` (hardcodeado en
  `external-secret-db.yaml`).
