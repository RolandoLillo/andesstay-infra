# andesstay-infra

> Infraestructura y orquestacion del ecosistema **AndesStay** (Fase 4).

Repositorio de soporte que contiene la capa de entrada (AWS API Gateway), la
orquestacion de contenedores (Docker Compose) y las pruebas HTTP del Gateway.

## Arquitectura (Fase 4)

```
Internet
   │
   ├── Angular (frontend :4200) ────────────────┐
   │                                            │
   ▼                              CORS / JWT   ▼
AWS HTTP API Gateway ───────────────────▶ ms-bff (:8080)
   │  (JWT Authorizer:                          │
   │   Azure AD / Entra ID)                     │
   │                                            │
   └── GET /api/reservations/health  (publica)  └──▶ ms-reservations (:8082)
       Rutas /api/reservations*       (JWT)    └──▶ ms-catalog    (:8081)
                                                      │
                                                      ▼ (interna)
                                              postgres-db (:5432, andesstay_db)
```

- `andesstay-net`: red Docker **interna** que aísla microservicios y BD. Solo
  accesible desde el Gateway/BFF, sin salida a Internet.
- `andesstay-public`: red para el frontend y el puerto del BFF.
- La autenticacion es **JWT centralizada** en el API Gateway: el microservicio
  no valida el token, el Gateway se encarga (401/403) antes de reenviar.

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
| `frontend`      | `andesstay/frontend:latest`        | `4200:4200`         | `andesstay-public` |

> `ms-catalog`, `ms-bff` y `frontend` estan en construccion: ajustar el `context`
> del `build:` en `compose.yml` cuando existan sus repositorios.

## 2. AWS API Gateway (HTTP API)

La plantilla `aws/api-gateway/http-api.yml` crea el HTTP API con:

| Config         | Valor                                                              |
|----------------|--------------------------------------------------------------------|
| Protocolo      | HTTP (V2)                                                          |
| Publica        | `GET /api/reservations/health`                                     |
| Protegidas     | `GET`/`POST` `/api/reservations`, `GET/{id}`, `PUT/{id}/status`, `GET /api/me`, `GET /api/catalog/{proxy+}` |
| Authorizer     | JWT — Issuer `https://login.microsoftonline.com/<TENANT_ID>/v2.0`  |
| Audience       | `api://<API_CLIENT_ID>`                                            |
| Scopes         | `access_as_user` (todas las rutas protegidas, definido en la App Registration) |
| CORS           | Origins `http://localhost:4200` y `http://<EC2_PUBLIC_IP>`         |
| Metodos        | `GET, POST, PUT, DELETE, OPTIONS`                                  |
| Headers        | `Authorization, Content-Type`                                      |

Respuestas del authorizer (antes de llegar al backend):

- `401` sin header `Authorization` o token no valido/expirado.
- `403` cuando el token no contiene el scope exigido por la ruta.

### Despliegue

```bash
aws cloudformation deploy \
  --template-file aws/api-gateway/http-api.yml \
  --stack-name andesstay-api-gateway \
  --parameter-overrides \
      TenantId=<TU_TENANT_ID> \
      ApiClientId=<CLIENT_ID_AD> \
      BffUrl=http://<EC2_PUBLIC_IP>:8080 \
      AllowedOriginPublic=http://<EC2_PUBLIC_IP> \
  --capabilities CAPABILITY_IAM
```

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
| `validToken`      | Access Token valido (con scopes reservados)      |
| `invalidToken`    | token vencido/invalido                           |
| `noScopeToken`    | token sin scope `reservations:*`                 |

Escenarios cubiertos:

- `200 OK` / `201 Created` con token valido.
- `401 Unauthorized` sin `Authorization` o token vencido.
- `403 Forbidden` si el claim `scp` no incluye los scopes exigidos.
- `404 Not Found` (id inexistente) y `409 Conflict` (transicion invalida).

Una vez con el token, ejecutar la coleccion completa en el Collection Runner.

## Variables de entorno (`.env`)

| Variable            | Uso                                |
|---------------------|------------------------------------|
| `POSTGRES_USER`     | Usuario de PostgreSQL              |
| `POSTGRES_PASSWORD` | Password de PostgreSQL             |
| `BFF_PUBLIC_HOST`   | `127.0.0.1` (local) / `0.0.0.0` (EC2) |
| `BFF_PORT`          | Puerto del BFF (`8080`)            |