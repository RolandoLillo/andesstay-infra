# Configuración de API Gateway & EC2 Integration

- **URL Base API Gateway:** https://lmv59t05gg.execute-api.us-east-1.amazonaws.com/prod
- **Integración BFF:** http://3.87.83.6:8080/{proxy}
- **JWT Issuer:** https://login.microsoftonline.com/cb0b9f53-0ba7-4f09-8da2-c2f5ab4b73ee/v2.0
- **Audience:** 4cd6df9a-e2f7-4024-aea6-dd67c49709bc
- **CORS Configurado:** http://localhost:4200/
- **Comportamiento sin token:** Retorna HTTP 401 con respuesta `{"message":"Unauthorized"}`.