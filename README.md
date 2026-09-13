# andesstay-infra

> Infraestructura y orquestacion del ecosistema **AndesStay** (Fase 4).

Repositorio de soporte que contiene la capa de entrada (AWS API Gateway), la
orquestacion de contenedores (Docker Compose) y las pruebas HTTP del Gateway.

## Arquitectura (Fase 4)

```
Internet
   │
   ├── Angular (frontend :4200, ng serve) ────────┐
   │                                              │
   ▼                                CORS / JWT    ▼
AWS HTTP API Gateway ────────────────────▶ ms-bff (:8080)
   │  (JWT Authorizer: Entra ID,                   │
   │   scope access_as_user)                       │
   │                                              │
   ├── GET /api/reservations/health  (publica)      └──▶ ms-reservations (:8082)
   └── /api/me, /api/catalog*, /api/reservations* (JWT) └─▶ ms-catalog (:8081)
                                                       │
                                                       ▼ (interna)
                                               postgres-db (:5432, andesstay_db)
```

- `andesstay-net`: red Docker **interna** que aísla microservicios y BD. Solo
  accesible desde el Gateway/BFF, sin salida a Internet.
- `andesstay-public`: red para el frontend y el puerto del BFF.
- La autenticacion es **JWT centralizada** en el API Gateway: el microservicio
  no valida el token, el Gateway se encarga de validar issuer + audience y de
  rechazar (401) antes de reenviar. El 403 por rol lo decide el BFF (claim `roles`).

## Identidad Azure AD (Microsoft Entra ID)

La autenticacion centralizada esta configurada en la app registration de Azure AD.

| Campo       | Valor                                                                   |
|-------------|-------------------------------------------------------------------------|
| Tenant ID   | `cb0b9f53-0ba7-4f09-8da2-c2f5ab4b73ee`                                 |
| Client ID   | `4cd6df9a-e2f7-4024-aea6-dd67c49709bc`                                 |
| Issuer      | `https://login.microsoftonline.com/cb0b9f53-0ba7-4f09-8da2-c2f5ab4b73ee/v2.0` |
| Audience    | `api://4cd6df9a-e2f7-4024-aea6-dd67c49709bc`                            |
| Scope (MSAL)| `access_as_user`                                                        |
| Roles       | `Admin`, `Operador`, `Cliente`, `Auditor`                               |

> **Nota importante:** El JWT Authorizer del API Gateway valida **issuer + audience + scope `access_as_user`**.
> El 403 por **rol insuficiente** (claim `roles`) lo procesa el **BFF**, no el Gateway.
> Esto asegura que solo los tokens emitidos por la app registration de AndesStay pasen,
> y que la autorizacion a nivel de negocio la gestione el backend.

## Estructura

```
andesstay-infra/
├── apps/
│   └── compose.yml                  # Orquestacion de contenedores
├── aws/
│   └── api-gateway/
│       └── http-api.yml            # CloudFormation del HTTP API + JWT + CORS
├── docs/
│   └── postman/
│       └── andesstay-gateway.collection.json
├── .env.example
└── README.md
```

## 1. Orquestacion local

Requisitos: Docker Engine con Compose v2 instalado.

```bash
cp .env.example .env          # Windows: copy .env.example .env
# Editar .env con credenciales reales

docker compose -f apps/compose.yml up -d --build
docker compose -f apps/compose.yml ps
docker compose -f apps/compose.yml logs -f ms-reservations
```

Detener:

```bash
docker compose -f apps/compose.yml down
# Eliminar tambien el volumen de la BD si se quiere resetear:
docker compose -f apps/compose.yml down -v
```

### Servicios

| Servicio        | Imagen/Origen                      | Puerto host         | Red              |
|-----------------|------------------------------------|---------------------|------------------|
| `postgres-db`   | `postgres:16-alpine`               | solo interno        | `andesstay-net`  |
| `ms-reservations`| `andesstay/ms-reservations:latest` | loopeable (opcional)| `andesstay-net`  |
| `ms-catalog`    | `andesstay/ms-catalog:latest`      | loopeable (opcional)| `andesstay-net`  |
| `ms-bff`        | `andesstay/ms-bff:latest`          | `127.0.0.1:8080`    | `andesstay-net` + `andesstay-public` |
| ~~frontend~~    | (comentado en compose)             | `4200` via `ng serve` | `andesstay-public` |

> - `ms-catalog`, `ms-bff` y `frontend` estan en construccion. Los `context` en
>   `compose.yml` apuntan a los repos kebab-case: `andesstay-ms-bff`,
>   `andesstay-ms-catalog`, `andesstay-ms-reservations/reservations`.
> - `frontend` esta **comentado** en `apps/compose.yml` porque el repo hermano no
>   tiene Dockerfile aun. Hasta que lo incorpore, ejejecutar el frontend localmente:

## 2. AWS API Gateway (HTTP API)

La plantilla `aws/api-gateway/http-api.yml` crea el HTTP API con:

| Config         | Valor                                                              |
|----------------|--------------------------------------------------------------------|
| Protocolo      | HTTP (V2)                                                          |
| Publica        | `GET /api/reservations/health`                                     |
| Protegidas (JWT)| `GET/POST /api/reservations`, `GET /api/reservations/{id}`, `PUT /api/reservations/{id}/status`, `GET /api/me`, `GET/POST/PUT /api/catalog`, `GET /api/catalog/health`, `GET /api/catalog/{proxy+}` |
| Authorizer     | JWT — Issuer `https://login.microsoftonline.com/cb0b9f53-0ba7-4f09-8da2-c2f5ab4b73ee/v2.0` |
| Audience       | `api://4cd6df9a-e2f7-4024-aea6-dd67c49709bc`                       |
| Scope          | `access_as_user` (todas las rutas protegidas)                      |
| CORS           | Origins `http://localhost:4200` y `http://<EC2_PUBLIC_IP>`         |
| Metodos        | `GET, POST, PUT, DELETE, OPTIONS`                                  |
| Headers        | `Authorization, Content-Type`                                      |

**Flujo:** el navegador solo habla con el API Gateway. **Toda** ruta publicada
(catalogo incluido) se reenvia al BFF (`Gateway → BFF → microservicios`).

Respuesta del Gateway:

- `401` sin header `Authorization`, o token invalido/expirado/audience incorrecta.
- `403` del Gateway solo si el token no porta el scope `access_as_user`.
  La **autorizacion por rol** (Admin/Operador/Cliente/Auditor) la evalúa el **BFF**
  con el claim `roles` y responde 403 cuando el rol no tiene permisos.

### Despliegue

```bash
aws cloudformation deploy \
  --template-file aws/api-gateway/http-api.yml \
  --stack-name andesstay-api-gateway \
  --parameter-overrides \
      BffUrl=http://<EC2_PUBLIC_IP>:8080 \
      AllowedOriginPublic=http://<EC2_PUBLIC_IP> \
  --capabilities CAPABILITY_IAM
```

> `TenantId` y `ApiClientId` ya traen como default los IDs de la app registration
> de AndesStay (`cb0b9f53-...` / `4cd6df9a-...`), asi que no hace falta pasarlos
> salvo que se quiera apuntar a otro entorno.

El endpoint publico se obtiene del output `HttpApiEndpoint`
(`https://<API_ID>.execute-api.<REGION>.amazonaws.com`).

> En produccion el tráfico interno del Gateway al BFF deberia usar una NLB/VPC
> Link privada. Este template expone `BffUrl` como parametro para el caso EC2
> publico de la fase actual.

## 3. Pruebas con Postman

Importar `docs/postman/andesstay-gateway.collection.json` y configurar:

| Variable          | Descripcion                                      |
|-------------------|--------------------------------------------------|
| `baseUrl`         | endpoint del stage (output `HttpApiEndpoint`)    |
| `validToken`      | Access Token valido con scope `access_as_user`   |
| `invalidToken`    | token vencido/invalido                           |
| `noScopeToken`    | token sin scope `access_as_user`                 |

Escenarios cubiertos:

- `200 OK` / `201 Created` con token valido (`access_as_user`).
- `401 Unauthorized` sin `Authorization` o token vencido.
- `403 Forbidden` si el token no porta el scope `access_as_user`.
- `404 Not Found` (id inexistente) y `409 Conflict` (transicion invalida).

Una vez con el token, ejecutar la coleccion completa en el Collection Runner.

## Variables de entorno (`.env`)

| Variable            | Uso                                |
|---------------------|------------------------------------|
| `POSTGRES_USER`     | Usuario de PostgreSQL              |
| `POSTGRES_PASSWORD` | Password de PostgreSQL             |
| `BFF_PUBLIC_HOST`   | `127.0.0.1` (local) / `0.0.0.0` (EC2) |
| `BFF_PORT`          | Puerto del BFF (`8080`)            |