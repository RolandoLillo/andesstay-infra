# AndesStay — Infraestructura y Orquestación Backend

Este repositorio contiene la definición de infraestructura como código (IaC) para **AWS API Gateway**, la orquestación local/producción con **Docker Compose** y las colecciones de pruebas **Postman** para el ecosistema microservicios de **AndesStay**.

---

## 🏛️ Arquitectura del Sistema

El ecosistema sigue un patrón **Gateway ──► BFF ──► Microservicios**, garantizando un único punto de entrada expuesto hacia los clientes y aislando la lógica de dominio en redes internas.

```
             ┌──────────────────────────────────────────┐
             │          Cliente (Angular + MSAL)        │
             └────────────────────┬─────────────────────┘
                                  │ HTTP / HTTPS
                                  ▼
             ┌──────────────────────────────────────────┐
             │         AWS API Gateway (HTTP API)       │
             │      (JWT Authorizer — Entra ID)         │
             └────────────────────┬─────────────────────┘
                                  │ Red Interna / Proxy
                                  ▼
        ┌──────────────────────────────────────────┐
        │        BFF (andesstay-ms-bff:8080)       │
        │  (RBAC: Admin, Operador, Cliente, ...)   │
        └──────────┬───────────────────┬───────────┘
                   │                   │
      ┌────────────┘                   └────────────┐
      ▼                                            ▼
┌────────────────────┐                   ┌──────────────────────┐
│  ms-catalog:8081   │                   │ ms-reservations:8082 │
└────────────────────┘                   └───────────┬──────────┘
                                                     │
                                                     ▼
                                     ┌────────────────────────────┐
                                     │ postgres-db (5432)         │
                                     │ (interno — andesstay-net)  │
                                     └────────────────────────────┘
```

### Principios de Seguridad y Ruteo

1. **Punto Único de Entrada:** El navegador únicamente interactúa con el API Gateway.
2. **Validación JWT en Gateway:** El Gateway valida la firma del token con Azure AD (Entra ID), verificando `issuer`, `audience` y requiriendo el scope `access_as_user`.
3. **Autorización RBAC en BFF:** El Gateway **no** emite respuestas `403` por roles. El **BFF** inspecciona el claim `roles` (Admin, Operador, Cliente, Auditor) y deniega el acceso si los permisos son insuficientes.

### Redes Docker

* `andesstay-net` (**interna**): aísla `postgres-db`, `ms-reservations` y `ms-catalog`. Sin salida a Internet; solo accesible desde el Gateway/BFF.
* `andesstay-public`: red para los componentes expuestos externamente — `ms-bff` (puerto `8080`) y, en el futuro, `frontend`. El **API Gateway** en EC2 alcanza al BFF a través de esta red.

---

## 🔑 Configuración de Identidad (Azure AD / Entra ID)

La autenticación se realiza mediante **OAuth 2.0 / OIDC** integrado con Microsoft Entra ID (App Registration).

| Campo       | Valor                                                                                 |
|-------------|---------------------------------------------------------------------------------------|
| Tenant ID   | `cb0b9f53-0ba7-4f09-8da2-c2f5ab4b73ee`                                                 |
| Client ID   | `4cd6df9a-e2f7-4024-aea6-dd67c49709bc`                                                 |
| Issuer      | `https://login.microsoftonline.com/cb0b9f53-0ba7-4f09-8da2-c2f5ab4b73ee/v2.0`          |
| Audience    | `api://4cd6df9a-e2f7-4024-aea6-dd67c49709bc`                                           |
| Scope (MSAL)| `access_as_user` (URI: `api://4cd6df9a-e2f7-4024-aea6-dd67c49709bc/access_as_user`)   |
| Roles       | `Admin`, `Operador`, `Cliente`, `Auditor`                                              |

> ⚠️ **Nota de Seguridad:** No se almacenan ni suben credenciales, secretos ni archivos `.env` al repositorio. Los valores listados son identificadores públicos de la App Registration.

---

## 🗺️ Mapeo de Rutas del Gateway

| Método | Ruta | Tipo / Auth | Enrutamiento / Servicio Destino |
| :--- | :--- | :--- | :--- |
| `GET` | `/api/reservations/health` | **Público** | `ms-reservations` (vía BFF) |
| `GET` | `/api/catalog/health` | **JWT** (`access_as_user`) | `ms-catalog` (vía BFF) |
| `GET` | `/api/me` | **JWT** (`access_as_user`) | `andesstay-ms-bff` |
| `GET` | `/api/catalog` | **JWT** (`access_as_user`) | `andesstay-ms-bff` ──► `ms-catalog` |
| `POST/PUT` | `/api/catalog` | **JWT** (`access_as_user`) | `andesstay-ms-bff` ──► `ms-catalog` *(Solo Admin)* |
| `GET/POST` | `/api/reservations/{proxy+}` | **JWT** (`access_as_user`) | `andesstay-ms-bff` ──► `ms-reservations` |

*CORS configurado para permitir solicitudes desde `http://localhost:4200` y la IP pública asignada a la instancia EC2.*

---

## 🐳 Orquestación con Docker Compose

El archivo `apps/compose.yml` orquesta los componentes, aislando la persistencia y los microservicios en la red interna `andesstay-net`.

### Servicios Incluidos

| Servicio         | Puerto host | Red                                  | Notas                                      |
|------------------|-------------|--------------------------------------|--------------------------------------------|
| `postgres-db`    | interno     | `andesstay-net`                      | PostgreSQL 16, **no expuesto al host en producción** |
| `ms-reservations`| interno (opcional `8082` para testing) | `andesstay-net` | Spring Boot, perfil `prod`, conecta a `postgres-db` |
| `ms-catalog`     | interno | `andesstay-net`                      | Microservicio de catálogo (puerto `8081`)  |
| `ms-bff`         | `8080`      | `andesstay-net` + `andesstay-public` | Único punto de entrada para el Gateway     |
| ~~`frontend`~~   | `4200`      | `andesstay-public`                   | **Comentado** — se ejecuta con `ng serve`  |

> `postgres-db` es un servicio **interno**: sus credenciales y datos circulan solo dentro de `andesstay-net`. En producción no se publica su puerto al host; las herramientas de administración pueden habilitarlo localmente de forma opcional.

### Ejecución Local

1. **Clonar/actualizar los repositorios hermanos** en el mismo directorio raíz (`../`):
   - `andesstay-infra`
   - `andesstay-ms-bff`
   - `andesstay-ms-catalog`
   - `andesstay-ms-reservations`
   - `andesstay-frontend`

2. **Configurar credenciales de entorno:**
   ```bash
   cp .env.example .env          # Windows: copy .env.example .env
   # Editar .env con las credenciales reales antes de continuar
   ```

3. **Levantar la infraestructura:**
   ```bash
   cd apps
   docker compose up --build -d
   ```

4. **Verificar estado de los contenedores:**
   ```bash
   docker compose ps
   ```

5. **Ejecutar el Frontend Angular** (mientras esté comentado en compose):
   ```bash
   cd ../../andesstay-frontend
   npm install
   ng serve --proxy-config proxy.conf.json
   ```

### Variables de Entorno (`.env`)

`compose.yml` interpola las siguientes variables desde el archivo `.env`:

| Variable            | Descripción                                             | Valor por Defecto       |
|---------------------|---------------------------------------------------------|-------------------------|
| `POSTGRES_USER`     | Usuario de PostgreSQL                                   | *(obligatorio)*         |
| `POSTGRES_PASSWORD` | Contraseña de PostgreSQL                                | *(obligatorio)*         |
| `POSTGRES_DB`       | Nombre de la base de datos creada por PostgreSQL        | `andesstay_db`          |
| `BFF_PUBLIC_HOST`   | Interfaz de escucha del BFF: `127.0.0.1` (local) / `0.0.0.0` (EC2) | `127.0.0.1`   |
| `BFF_PORT`          | Puerto del BFF publicado al host                        | `8080`                  |

---

## ☁️ Despliegue de AWS API Gateway

La plantilla `aws/api-gateway/http-api.yml` crea el HTTP API con el Authorizer JWT (`issuer` + `audience`, scope `access_as_user`) y CORS para `localhost:4200` y la IP pública de la instancia.

```bash
aws cloudformation deploy \
  --template-file aws/api-gateway/http-api.yml \
  --stack-name andesstay-api-gateway \
  --parameter-overrides \
      BffUrl=<URL_O_IP_DEL_BFF> \
      AllowedOriginPublic=<ORIGEN_PERMITIDO> \
  --capabilities CAPABILITY_IAM
```

> `TenantId` y `ApiClientId` traen como default los IDs de la App Registration de AndesStay (`cb0b9f53-...` / `4cd6df9a-...`), por lo que no hace falta pasarlos salvo que se apunte a otro entorno.

El endpoint público se obtiene del output `HttpApiEndpoint` (`https://<API_ID>.execute-api.<REGION>.amazonaws.com`).

> En producción, el tráfico del Gateway al BFF debería usar una NLB/VPC Link privada. Este template expone `BffUrl` como parámetro para el caso EC2 público de la fase actual.

---

## 🧪 Validaciones y Pruebas Postman

En `docs/postman/` se encuentra la colección unificada **`andesstay-gateway.collection.json`**. Importarla en Postman y definir las siguientes variables de colección:

| Variable         | Descripción                                                        |
|------------------|--------------------------------------------------------------------|
| `baseUrl`        | Endpoint del stage — output `HttpApiEndpoint` del CloudFormation   |
| `validToken`     | Access Token válido con scope `access_as_user`                     |
| `invalidToken`   | Token vencido o inválido                                           |
| `noScopeToken`   | Token sin el scope `access_as_user`                                |

### Casos de Prueba Incluidos

- **Health Checks (200 OK):** Verificación de endpoints públicos y estado de los microservicios.
- **Unauthenticated (401 Unauthorized):** Consumo de rutas protegidas sin encabezado `Authorization`.
- **Forbidden (403 Forbidden):** RBAC donde el BFF rechaza acciones de escritura para roles Cliente u Operador.
- **Flow Completions (200 OK / 201 Created):** Consultas de catálogo y creación de reservas persistidas en PostgreSQL con tokens válidos (`access_as_user`).

Una vez configuradas las variables, ejecutar la colección completa con el **Collection Runner** de Postman.

---

## 📁 Estructura del Repositorio

```
andesstay-infra/
├── apps/
│   └── compose.yml                  # Orquestación Docker Compose
├── aws/
│   └── api-gateway/
│       └── http-api.yml             # CloudFormation del HTTP API + JWT + CORS
├── docs/
│   └── postman/
│       └── andesstay-gateway.collection.json
├── .env.example                     # Plantilla de variables de entorno
└── README.md
```