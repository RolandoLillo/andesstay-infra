# Configuración de API Gateway & EC2 Integration

Valores a parametrizar por entorno; verificar con AWS CLI antes de aplicar cambios. No se ejecutaron comandos AWS al preparar esta documentación.

| Campo | Valor |
| --- | --- |
| URL base API Gateway | `https://lmv59t05gg.execute-api.us-east-1.amazonaws.com/prod` |
| Integración BFF | `http://<EC2_PUBLIC_IP>:8080` |
| Frontend nginx en EC2 | `http://<FRONTEND_PUBLIC_ORIGIN>` |
| CORS permitidos | `http://localhost:4200`, `http://<FRONTEND_PUBLIC_ORIGIN>` |
| JWT Issuer | `https://login.microsoftonline.com/cb0b9f53-0ba7-4f09-8da2-c2f5ab4b73ee/v2.0` |
| Audience | `4cd6df9a-e2f7-4024-aea6-dd67c49709bc` |
| Sin token | HTTP `401` |
| Preflight | Gestionado por la configuración CORS del HTTP API; no se define ruta `OPTIONS` propia. |
| Redirect URI / Logout URI Entra | `http://<FRONTEND_PUBLIC_ORIGIN>` (idénticas en app registration y `environment.prod.ts`) |

`BffUrl` debe ser solo `http://<IP>:8080`, sin `/{proxy}`. La plantilla reenvía la ruta completa mediante `overwrite:path: $request.path`.

Rutas protegidas incluidas: `/api/me`, `/api/catalog/**`, `/api/reservations/**` (incluye `PUT /api/reservations/{id}/preparation`) y `/api/audit/**`. Health público: `GET /api/health` y `GET /api/reservations/health`.

Para actualizar el stack:

```bash
export EC2_PUBLIC_IP=<IP_PUBLICA_EC2>
export FRONTEND_PUBLIC_ORIGIN="http://${EC2_PUBLIC_IP}"
./aws/api-gateway/deploy.sh
```

Si la IP pública cambia, actualizar también `.env`, `environment.prod.ts`, `AllowedOriginPublic`, el Security Group y las Redirect/Logout URI de Entra ID.

> Nota sobre IP dinámica: no fijar la IP en el repositorio. Sin Elastic IP, reiniciar o recrear la EC2 cambia la IP y requiere repetir este paso.
