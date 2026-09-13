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
              │           AWS API Gateway (HTTP)         │
              │       (JWT Authorizer - Entra ID)        │
              └────────────────────┬─────────────────────┘
                                   │ Red Interna / Proxy
                                   ▼
              ┌──────────────────────────────────────────┐
              │       BFF (andesstay-ms-bff:8080)        │
              │   (RBAC: Admin, Operador, Auditor, etc.) │
              └──────────┬────────────────────┬──────────┘
                         │                    │
          ┌──────────────┘                    └──────────────┐
          ▼                                                  ▼
┌───────────────────────────┐                      ┌───────────────────────────┐
│       ms-catalog          │                      │      ms-reservations      │
│      (Puerto 8081)        │                      │       (Puerto 8082)       │
└───────────────────────────┘                      └─────────────┬─────────────┘
                                                                 │
                                                                 ▼
┌───────────────────────────┐
│    postgres-db (5432)     │
└───────────────────────────┘
```

### Principios de Seguridad y Ruteo:
1. **Punto Único de Entrada:** El navegador únicamente interactúa con el API Gateway.
2. **Validación JWT en Gateway:** El Gateway valida la firma del token con Azure AD (Entra ID), verificando `issuer`, `audience` y requiriendo el scope `access_as_user`.
3. **Autorización RBAC en BFF:** El Gateway **no** emite respuestas `403` por roles. El **BFF** es el encargado de inspeccionar el claim `roles` (Admin, Operador, Auditor, Cliente) y denegar el acceso si los permisos son insuficientes.

---

## 🔑 Configuración de Identidad (Azure AD / Entra ID)

La autenticación se realiza mediante **OAuth 2.0 / OIDC** integrado con Microsoft Entra ID.

* **Tenant ID:** `cb0b9f53-0ba7-4f09-8da2-c2f5ab4b73ee`
* **Client ID:** `4cd6df9a-e2f7-4024-aea6-dd67c49709bc`
* **Issuer:** [https://login.microsoftonline.com/cb0b9f53-0ba7-4f09-8da2-c2f5ab4b73ee/v2.0](https://login.microsoftonline.com/cb0b9f53-0ba7-4f09-8da2-c2f5ab4b73ee/v2.0)
* **Audience:** `api://4cd6df9a-e2f7-4024-aea6-dd67c49709bc`
* **Scope Requerido:** `access_as_user` (URI completa: `api://4cd6df9a-e2f7-4024-aea6-dd67c49709bc/access_as_user`)
* **Roles de Aplicación:** `Admin`, `Operador`, `Auditor`, `Cliente`.

> ⚠️ **Nota de Seguridad:** No se almacenan ni suben credenciales, secretos ni archivos `.env` al repositorio. Los valores listados arriba corresponden a identificadores públicos de la App Registration.

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

*CORS configurado para permitir solicitudes desde `http://localhost:4200` y la IP pública asignada a la instancia.*

---

## 🐳 Orquestación con Docker Compose

El archivo `apps/compose.yml` orquesta los componentes aislándolos en la red interna `andesstay-net`.

### Servicios Incluidos:
- **`postgres-db`**: PostgreSQL 16 (Alpine) en el puerto `5432`.
- **`ms-reservations`**: Microservicio Spring Boot (puerto `8082`, perfil `prod` con conexión a `postgres-db`).
- **`ms-catalog`**: Microservicio de catálogo (puerto `8081`).
- **`ms-bff`**: Backend-for-Frontend (puerto `8080`).
- **`frontend`** *(Comentado)*: La aplicación Angular se ejecuta localmente mediante CLI (`ng serve`) mientras el repo hermano `andesstay-frontend` incorpora su `Dockerfile`.

### Ejecución Local:

1. **Clonar/actualizar los repositorios hermanos** en el mismo directorio raíz (`../`):
   - `andesstay-infra`
   - `andesstay-ms-bff`
   - `andesstay-ms-catalog`
   - `andesstay-ms-reservations`
   - `andesstay-frontend`

2. **Levantar la infraestructura:**
   ```bash
   cd apps
   docker compose up --build -d
   ```

3. **Verificar estado de los contenedores:**
   ```bash
   docker compose ps
   ```

4. **Ejecutar el Frontend Angular** (mientras esté comentado en compose):
   ```bash
   cd ../../andesstay-frontend
   npm install
   ng serve --proxy-config proxy.conf.json
   ```

---

## 🧪 Validaciones y Pruebas Postman

En la carpeta `docs/postman/` se encuentra la colección unificada:

`andesstay-gateway.collection.json`

### Casos de Prueba Incluidos:

- **Health Checks (200 OK):** Verificación de endpoints públicos y estado de los microservicios.
- **Unauthenticated (401 Unauthorized):** Intentos de consumo de rutas protegidas sin encabezado `Authorization`.
- **Forbidden (403 Forbidden):** Validación de RBAC donde el BFF rechaza acciones de escritura a usuarios con rol Cliente u Operador.
- **Flow Completions (200 OK / 201 Created):** Consultas de catálogo y creación de reservas persistidas en PostgreSQL con tokens válidos con el scope `access_as_user`.