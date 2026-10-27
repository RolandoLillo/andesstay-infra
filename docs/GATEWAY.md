# Configuración de API Gateway & EC2 Integration

- **URL Base API Gateway:** https://lmv59t05gg.execute-api.us-east-1.amazonaws.com/prod
- **Integración BFF:** `http://<EC2_PUBLIC_IP>:8080` (sin `/{proxy}`; la ruta original se reenvía mediante `overwrite:path: $request.path`)
- **JWT Issuer:** https://login.microsoftonline.com/cb0b9f53-0ba7-4f09-8da2-c2f5ab4b73ee/v2.0
- **Audience:** 4cd6df9a-e2f7-4024-aea6-dd67c49709bc
- **CORS Configurado:** http://localhost:4200
- **Comportamiento sin token:** Retorna HTTP 401 con respuesta `{"message":"Unauthorized"}`.
- **Manejo de Preflight (OPTIONS):** Ruta `OPTIONS /{proxy+}` pública sin JWT mapeada hacia la salud/BFF para permitir CORS preflight en clientes web (Angular).

> **Nota sobre IP dinámica:** La IP pública de la EC2 puede cambiar al reiniciar o recrear la instancia. No se fija en este documento: se obtiene del despliegue y se pasa como `BffUrl` en CloudFormation.
