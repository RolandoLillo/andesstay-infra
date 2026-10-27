# Pruebas de `ms-rabbit-admin`

`ms-rabbit-admin` vive únicamente en `backend-net` (`internal: true`) y **no publica el puerto `8085`**. Por eso las pruebas se ejecutan desde dentro del contenedor con `docker exec`, sin exponer el servicio al host ni al Gateway.

> El servicio no tiene autenticación. No se agrega a `gateway-net` ni se crea una ruta en AWS API Gateway.

## Prerrequisitos

```powershell
cd apps
docker compose --env-file ../.env up -d ms-rabbit-admin
docker compose --env-file ../.env ps ms-rabbit-admin
```

El contenedor debe aparecer como `healthy`.

## Health check

```powershell
docker exec andesstay-ms-rabbit-admin wget -qO- http://localhost:8085/api/health
```

Salida real:

```json
{"rabbitmq":"CONNECTED","service":"andesstay-ms-rabbit-admin","status":"UP"}
```

## CRUD de colas

Ejecutar desde PowerShell en Windows:

```powershell
@'
#!/bin/sh
queue="q.compose.test.$(date +%Y%m%d%H%M%S)"

request() {
  method="$1"; path="$2"; body="$3"
  if [ -n "$body" ]; then
    length=$(printf '%s' "$body" | wc -c | tr -d ' ')
    printf '%s %s HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s' \
      "$method" "$path" "$length" "$body" | nc -w 5 127.0.0.1 8085 | awk 'NR==1 { print $2 }'
  else
    printf '%s %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' \
      "$method" "$path" | nc -w 5 127.0.0.1 8085 | awk 'NR==1 { print $2 }'
  fi
}

echo "queue=$queue"
echo "GET_health=$(request GET /api/health '')"
echo "POST_valid=$(request POST /api/queues "{\"name\":\"$queue\",\"durable\":true,\"exclusive\":false,\"autoDelete\":false}")"
echo "POST_empty=$(request POST /api/queues '{"name":"","durable":true,"exclusive":false,"autoDelete":false}')"
echo "DELETE_missing=$(request DELETE /api/queues/q.no-existe-compose-test '')"
echo "DELETE_created=$(request DELETE /api/queues/$queue '')"
'@ | docker exec -i andesstay-ms-rabbit-admin sh
```

Salida real:

```text
queue=q.compose.test.20261027043524
GET_health=200
POST_valid=201
POST_empty=400
DELETE_missing=404
DELETE_created=204
```

## Resultado esperado

| Prueba | Resultado |
|---|---|
| `GET /api/health` | `200` |
| `POST /api/queues` con nombre válido | `201` |
| `POST /api/queues` con nombre vacío | `400` |
| `DELETE /api/queues/{nombre-inexistente}` | `404` |
| `DELETE /api/queues/{nombre-creado}` (limpieza) | `204` |
