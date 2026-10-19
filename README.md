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
                                  │ gateway-net :8080
                                  ▼
        ┌───────────────────────────────────────────────┐
        │        BFF (ms-bff:8080)                      │
        │   (RBAC: Admin, Operador, Cliente, Auditor)   │
        └───┬──────────┬──────────┬──────────┬──────────┘
            │          │          │          │
            ▼          ▼          ▼          ▼
     ┌────────────┐┌────────────┐┌────────────┐┌────────────┐
     │ ms-catalog ││ms-reserv.  ││ ms-audit   ││ ms-notify  │
     │   :8081    ││   :8082    ││   :8084    ││   :8083    │
     └─────┬──────┘└─────┬──────┘└─────┬──────┘└─────┬──────┘
           │             │             │             │
           ▼             ▼             ▼             ▼
   ╔══════════════════════════════════════════════════════════╗
   ║  backend-net (interna, sin salida a Internet)            ║
   ║                                                          ║
   ║  postgres-db:5432      zookeeper:2181                    ║
   ║  kafka:29092 (interno) / localhost:9092 (desde el host)  ║
   ║  rabbitmq-1 + rabbitmq-2 (clúster AMQP)                  ║
   ║  5672 (AMQP) / 15672 (management UI) desde el host        ║
   ╚══════════════════════════════════════════════════════════╝
```

### Principios de Seguridad y Ruteo

1. **Punto Único de Entrada:** El navegador únicamente interactúa con el API Gateway.
2. **Validación JWT en Gateway:** El Gateway valida la firma del token con Azure AD (Entra ID), verificando `issuer`, `audience` y requiriendo el scope `access_as_user`.
3. **Autorización RBAC en BFF:** El Gateway **no** emite respuestas `403` por roles. El **BFF** inspecciona el claim `roles` (Admin, Operador, Cliente, Auditor) y deniega el acceso si los permisos son insuficientes.

### Redes Docker

* `backend-net` (**interna**, `internal: true`): red de datos y de servicio. Aísla `postgres-db`, `zookeeper`, `kafka`, `rabbitmq-1`, `rabbitmq-2` y los microservicios `ms-reservations`, `ms-catalog`, `ms-audit` y `ms-notify`. **No tiene salida a Internet** y no es alcanzable desde el host, salvo por los puertos publicados explícitamente (`kafka:9092`, `rabbitmq-1:5672/15672`).
* `gateway-net` (**pública**): red de borde. `ms-bff` publica el `8080` y `rabbitmq-1` publica `5672`/`15672`; es el único punto de entrada para el **API Gateway** (en EC2) y para la Management UI de RabbitMQ.

> Nota: Docker solo publica puertos de contenedores que participan en al menos una red **no interna**. Por eso `rabbitmq-1` (el nodo que expone la UI) se conecta además a `gateway-net`; `rabbitmq-2` permanece solo en `backend-net`.

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

El archivo `apps/compose.yml` orquesta los componentes, aislando la persistencia y los microservicios en las redes `backend-net` (interna) y `gateway-net` (pública).

### Servicios Incluidos

| Servicio         | Puerto host | Red                                  | Notas                                      |
|------------------|-------------|--------------------------------------|--------------------------------------------|
| `postgres-db`    | interno     | `backend-net`                        | PostgreSQL 16, **no expuesto al host**    |
| `ms-reservations`| interno     | `backend-net`                        | Spring Boot, perfil `prod`, conecta a `postgres-db` y `kafka:29092`, depende de Kafka (service_healthy) |
| `ms-catalog`     | interno     | `backend-net`                        | Microservicio de catálogo (puerto `8081`)  |
| `ms-audit`       | interno     | `backend-net`                        | Microservicio de auditoría (puerto `8084`) |
| `ms-notify`      | interno     | `backend-net`                        | Microservicio de notificaciones (puerto `8083`), consume/produce en el clúster RabbitMQ (`backend-net`), depende de `rabbitmq-1`/`rabbitmq-2` (service_healthy) |
| `zookeeper`      | interno     | `backend-net`                        | Coordina el clúster Kafka (puerto `2181`)  |
| `kafka`          | `9092`      | `backend-net`                        | Broker Kafka dual: `kafka:29092` (interno) / `localhost:9092` (host) |
| `rabbitmq-1`     | `5672`, `15672` | `backend-net` + `gateway-net`    | Nodo **seed** del clúster RabbitMQ (`rabbit@rabbitmq-1`); expone AMQP `5672` + management UI `15672` |
| `rabbitmq-2`     | interno     | `backend-net`                        | Segundo nodo del clúster (`rabbit@rabbitmq-2`); se une a `rabbit@rabbitmq-1` al arrancar |
| `ms-bff`         | `8080`      | `backend-net` + `gateway-net`        | Único punto de entrada para el Gateway    |
| ~~`frontend`~~   | `4200`      | `gateway-net`                        | **Comentado** — se ejecuta con `ng serve`  |

> Los servicios de datos/mensajería (`postgres-db`, `zookeeper`, `kafka`, `rabbitmq-1`, `rabbitmq-2`) y los microservicios (`ms-reservations`, `ms-catalog`, `ms-audit`, `ms-notify`) viven en `backend-net` (red interna). `ms-bff` y `rabbitmq-1` participan además en `gateway-net` y exponen puertos al host.

### Topología de Red y Acceso a Kafka

Kafka se configura con **dos listeners** para separar el tráfico de la red interna del acceso desde el host local:

| Listener | Escucha | Anunciado (`advertised`) | Uso |
|---|---|---|---|
| `PLAINTEXT` | `0.0.0.0:29092` | `kafka:29092` | **Entre contenedores** (`backend-net`) |
| `PLAINTEXT_HOST` | `0.0.0.0:9092` | `localhost:9092` | **Desde el host** (dev local, herramientas) |

* **Desde dentro de Docker** (microservicios): `kafka:29092`. Así lo usan `ms-bff` y `ms-reservations` vía `KAFKA_BOOTSTRAP_SERVERS` (y `ms-reservations` espera a que Kafka esté `service_healthy` para iniciar).
* **Desde el host local** (KafkaTool, consolas, scripts): `localhost:9092`, mapeado por la regla `ports: "9092:9092"`.

```bash
# Desde un contenedor de backend-net
bootstrap=kafka:29092

# Desde el host local
bootstrap=localhost:9092
```

> ⚠️ Usar `kafka:9092` desde dentro de la red **no funciona**: el broker anuncia `localhost:9092` en ese listener y el cliente terminaría conectándose a su propio `localhost`.

### Clúster de RabbitMQ (2 nodos)

RabbitMQ se despliega como un **clúster de dos nodos** para dar alta disponibilidad al bus de eventos de `ms-notify`:

| Nodo | Nombre Erlang | Rol | Red(es) |
|---|---|---|---|
| `rabbitmq-1` | `rabbit@rabbitmq-1` | Nodo *seed* (arranca primero) | `backend-net` + `gateway-net` (publica `5672`/`15672`) |
| `rabbitmq-2` | `rabbit@rabbitmq-2` | Se une al clúster al iniciar | `backend-net` |

* Ambos nodos comparten la **cookie Erlang** (`RABBITMQ_ERLANG_COOKIE`) y son **nodos de disco** (`disc`), persistiendo metadatos en volúmenes dedicados (`rabbitmq1_data`, `rabbitmq2_data`).
* `rabbitmq-2` espera (`depends_on: service_healthy`) a `rabbitmq-1` y ejecuta en su `entrypoint`: `stop_app` → `reset` → `join_cluster rabbit@rabbitmq-1` → `start_app`. Es idempotente: si ya pertenece al clúster, solo arranca.
* Los microservicios se conectan al clúster con `SPRING_RABBITMQ_ADDRESSES=rabbitmq-1:5672,rabbitmq-2:5672` (failover automático entre nodos).

```bash
# Verificar el estado del clúster (debe listar los 2 nodos como "Running")
docker exec andesstay-rabbitmq-1 rabbitmqctl cluster_status

# Management UI: http://localhost:15672  (usuario/contraseña de RABBITMQ_USERNAME/PASSWORD)
#   Overview -> Nodes: rabbit@rabbitmq-1 y rabbit@rabbitmq-2
#   Exchanges: cmd.direct, cmd.topic, cmd.dead.dlx
#   Queues:    q.cmd.email, q.cmd.housekeeping, q.cmd.voucher (+ sus *.dlq)
```

### Ejecución Local

1. **Clonar/actualizar los repositorios hermanos** en el mismo directorio raíz (`../`):
   - `andesstay-infra`
   - `andesstay-ms-bff`
   - `andesstay-ms-catalog`
   - `andesstay-ms-reservations`
   - `andesstay-ms-notify`
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

5. **Iniciar Zookeeper/Kafka (validación):**
    ```bash
    docker compose logs -f zookeeper kafka
    # Esperar a que Kafka reporte estado healthy
    ```

6. **Ejecutar el Frontend Angular** (mientras esté comentado en compose):
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
| `RABBITMQ_USERNAME` | Usuario del clúster RabbitMQ (nodos `rabbitmq-1/2` + `ms-notify`/`ms-reservations` + UI management) | *(obligatorio)* |
| `RABBITMQ_PASSWORD` | Contraseña del clúster RabbitMQ                        | *(obligatorio)*         |
| `RABBITMQ_ERLANG_COOKIE` | Cookie Erlang compartida por los nodos del clúster (debe ser idéntica en `rabbitmq-1` y `rabbitmq-2`) | *(obligatorio)* |
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