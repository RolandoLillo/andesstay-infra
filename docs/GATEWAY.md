# Configuración de API Gateway & EC2 Integration

- **URL Base API Gateway:** https://lmv59t05gg.execute-api.us-east-1.amazonaws.com/prod
- **Integración BFF:** http://3.87.83.6:8080/{proxy}
- **JWT Issuer:** https://login.microsoftonline.com/cb0b9f53-0ba7-4f09-8da2-c2f5ab4b73ee/v2.0
- **Audience:** 4cd6df9a-e2f7-4024-aea6-dd67c49709bc
- **CORS Configurado:** http://localhost:4200
- **Comportamiento sin token:** Retorna HTTP 401 con respuesta `{"message":"Unauthorized"}`.
- **Manejo de Preflight (OPTIONS):** Ruta `OPTIONS /{proxy+}` pública sin JWT mapeada hacia la salud/BFF para permitir CORS preflight en clientes web (Angular).

> **Nota sobre IP Dinámica:** La IP `3.87.83.6` corresponde a la instancia EC2 actual. En caso de reiniciar o recrear la EC2, se asignará una nueva IP pública y se deberán actualizar la integración `BffUrl` en CloudFormation y este documento.