# Configuración de API Gateway & EC2 Integration

Valores a parametrizar por entorno; verificar con AWS CLI antes de aplicar cambios. No se ejecutaron comandos AWS al preparar esta documentación.

| Campo | Valor |
| --- | --- |
| API Gateway existente | `lmv59t05gg` (stage `prod`, no se crea uno nuevo) |
| URL base API Gateway usada por el frontend | `https://lmv59t05gg.execute-api.us-east-1.amazonaws.com/prod/api` |
| Integración BFF | `http://<EC2_PUBLIC_IP>:8080` (Elastic IP) |
| Frontend HTTPS en EC2 | `https://<FRONTEND_DOMAIN>` servido por Caddy |
| CORS permitidos | `https://<FRONTEND_DOMAIN>` exacto, sin barra final; `http://localhost:4200` para desarrollo local |
| JWT Issuer | `https://login.microsoftonline.com/cb0b9f53-0ba7-4f09-8da2-c2f5ab4b73ee/v2.0` |
| Audience | `4cd6df9a-e2f7-4024-aea6-dd67c49709bc` |
| Sin token | HTTP `401` |
| Preflight | Gestionado por la configuración CORS del HTTP API; no se define ruta `OPTIONS` propia. |
| Redirect URI / Logout URI Entra | `https://<FRONTEND_DOMAIN>` (idénticas en app registration y en el build del frontend) |

`BffUrl` / `IntegrationUri` debe ser solo `http://<IP>:8080`, sin `/{proxy}`. La integración reenvía la ruta completa mediante `overwrite:path: $request.path`.

El compose pasa siempre estos build args al frontend, por lo que el valor por defecto de `redirectUri` en `environment.prod.ts` ya no decide el despliegue:

- `ANDESSTAY_API_URL=https://lmv59t05gg.execute-api.us-east-1.amazonaws.com/prod/api`
- `ANDESSTAY_REDIRECT_URI=https://${FRONTEND_DOMAIN}`

Rutas protegidas incluidas: `/api/me`, `/api/catalog/**`, `/api/reservations/**` (incluye `PUT /api/reservations/{id}/preparation`) y `/api/audit/**`. Health público: `GET /api/health` y `GET /api/reservations/health`.

Para actualizar CORS y la integración del API existente:

```bash
export EC2_PUBLIC_IP=<ELASTIC_IP>
export FRONTEND_DOMAIN=<IP_CON_GUIONES>.sslip.io
./aws/api-gateway/deploy.sh
```

El script reutiliza `lmv59t05gg`, aplica `AllowOrigins=https://${FRONTEND_DOMAIN}` y actualiza la integración HTTP_PROXY a `http://${EC2_PUBLIC_IP}:8080`. No crea ni reemplaza el API.

Si la IP pública cambia, actualizar también la Elastic IP, `FRONTEND_DOMAIN`, el `.env`, el Security Group y las Redirect/Logout URI de Entra ID.

> Nota: sin Elastic IP, detener/iniciar la EC2 cambia la IP, rompe el nombre `sslip.io`, el certificado y el integration URI del Gateway.
