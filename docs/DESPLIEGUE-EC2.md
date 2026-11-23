# Checklist de despliegue en EC2

Checklist operativo para desplegar AndesStay en una instancia **Amazon Linux 2023** con Docker, Docker Compose y swap.

> **Alcance:** este documento es para ejecución manual del operador. Incluye el frontend nginx en el puerto `80` y el BFF en `8080`. No se ejecutó ningún comando en AWS para prepararlo.
>
> **Regla de seguridad:** no guardar tokens, contraseñas ni el archivo `.env` en el repositorio. No mostrar tokens en capturas de pantalla.

---

## 1. Requisitos previos

- Instancia EC2 con **Amazon Linux 2023**, usuario `ec2-user`.
- Key pair `.pem` con permisos restringidos.
- Disco recomendado: **20 GB o más** (las imágenes y el build de Maven/Docker consumen espacio).
- Elastic IP recomendada. Si no se usa, la IP pública cambia al detener/iniciar la instancia y hay que actualizar el Gateway.
- Repositorios hermanos en el mismo directorio padre.
- AWS CLI configurado en el equipo desde donde se actualiza CloudFormation, o credenciales disponibles para ese paso.
- Acceso a los tokens de prueba de Entra ID: válido, Cliente y Auditor.

### Advertencia sobre `t3.micro`

`t3.micro` tiene **1 vCPU y 1 GB de RAM**. Este stack levanta PostgreSQL, Zookeeper, Kafka, dos nodos RabbitMQ, cinco microservicios Spring Boot, el BFF y el frontend nginx. El build de Docker y los JVM pueden agotar la memoria y provocar que Docker termine procesos por OOM.

Recomendación:

- **Mínimo recomendado:** `t3.small` (2 GB) para ejecutar el stack.
- **Recomendado para construir:** `t3.medium` (4 GB).
- Si el laboratorio obliga a usar `t3.micro`:
  - Agregar 2 GB de swap (incluido abajo).
  - Compilar con `COMPOSE_PARALLEL_LIMIT=1`, o construir un servicio a la vez.
  - Construir la imagen del frontend fuera de la instancia o hacerlo por separado.
  - Monitorear con `free -h` y `docker stats`.
  - Si aun así falla por OOM, usar `t3.medium` o publicar las imágenes desde otra máquina.

El swap evita algunos OOM, pero no reemplaza la RAM: Kafka y RabbitMQ pueden volverse lentos.

---

## 2. Security Group

Configurar el Security Group de la instancia con **solo** estas reglas de entrada:

| Tipo | Protocolo | Puerto | Origen | Uso |
|---|---|---|---|---|
| SSH | TCP | `22` | `<TU_IP_PUBLICA>/32` | Administración |
| HTTP frontend | TCP | `80` | `0.0.0.0/0` | Angular servido por nginx |
| HTTP API BFF | TCP | `8080` | `0.0.0.0/0` | Acceso del API Gateway al BFF |

Salida: dejar la regla por defecto (todo el tráfico saliente).

**No abrir** `5432`, `9092`, `5672` ni `15672` a Internet. `compose.yml` publica RabbitMQ solo en `127.0.0.1`; la UI se administra por túnel SSH.

Comandos opcionales con AWS CLI:

```bash
export AWS_REGION=us-east-1
export SG_ID=sg-xxxxxxxxxxxxxxxxx
MY_IP=$(curl -s https://checkip.amazonaws.com | tr -d '\n')

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp --port 22 --cidr "$MY_IP/32" \
  --region "$AWS_REGION"

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0 \
  --region "$AWS_REGION"

aws ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" \
  --protocol tcp --port 8080 --cidr 0.0.0.0/0 \
  --region "$AWS_REGION"
```

Equivalente semiautomático, previa confirmación del operador:

```bash
export AWS_REGION=us-east-1
export SG_ID=sg-xxxxxxxxxxxxxxxxx
./aws/api-gateway/configure-security-group.sh
```

> Para producción, restringir el acceso al BFF con NLB/VPC Link o un rango controlado. En el laboratorio se usa `0.0.0.0/0` porque el API Gateway HTTP no tiene una IP fija simple.

---

## 3. Preparar la instancia

Conectarse:

```bash
export EC2_PUBLIC_IP=<IP_PUBLICA_DE_LA_INSTANCIA>
ssh -i ~/.ssh/andesstay-key.pem ec2-user@"$EC2_PUBLIC_IP"
```

Actualizar e instalar Docker:

```bash
sudo dnf update -y
sudo dnf install -y docker git
sudo systemctl enable --now docker
sudo usermod -aG docker ec2-user
exit
```

Reconectarse para que el grupo `docker` tome efecto y verificar:

```bash
docker version
```

### Instalar Docker Compose binario

```bash
COMPOSE_VERSION=v5.6.1
sudo curl -fSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
  -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
docker-compose version
```

> Si se prefiere el plugin `docker compose`, instalar el mismo binario en `~/.docker/cli-plugins/docker-compose` y usar `docker compose` en lugar de `docker-compose`.

### Crear swap de 2 GB

```bash
sudo dd if=/dev/zero of=/swapfile bs=1M count=2048 status=progress
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

sudo sysctl vm.swappiness=10
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf

free -h
swapon --show
```

> Si `swapon --show` ya muestra `/swapfile`, no volver a crearlo. Verificar que `/etc/fstab` no tenga una línea duplicada.

---

## 4. Clonar los repositorios hermanos

Crear el directorio raíz y clonar los repositorios requeridos por `apps/compose.yml`:

```bash
mkdir -p ~/andesstay
cd ~/andesstay

git clone https://github.com/RolandoLillo/andesstay-infra.git
git clone https://github.com/HeOlivares/andesstay-ms-bff.git
git clone https://github.com/HeOlivares/andesstay-ms-catalog.git
git clone https://github.com/RolandoLillo/andesstay-ms-reservations.git
git clone https://github.com/HeOlivares/andesstay-ms-notify.git
git clone https://github.com/RolandoLillo/andesstay-ms-audit.git
git clone https://github.com/HeOlivares/andesstay-ms-rabbit-admin.git
git clone https://github.com/cristianmonsalve14/andesstay-frontend.git
```

El frontend se sirve con el servicio `frontend` de `compose.yml` en el puerto `80`.

Verificar la estructura esperada:

```bash
ls -1 ~/andesstay
test -f ~/andesstay/andesstay-ms-reservations/reservations/Dockerfile && echo 'Dockerfile de reservas OK'
test -f ~/andesstay/andesstay-frontend/Dockerfile && echo 'Dockerfile del frontend OK'
```

Actualizar los repositorios:

```bash
for repo in \
  andesstay-infra \
  andesstay-ms-bff \
  andesstay-ms-catalog \
  andesstay-ms-reservations \
  andesstay-ms-notify \
  andesstay-ms-audit \
  andesstay-ms-rabbit-admin \
  andesstay-frontend
do
  git -C "$repo" switch main
  git -C "$repo" pull --ff-only
done
```

---

## 5. Crear y ajustar el archivo `.env`

```bash
cd ~/andesstay/andesstay-infra
cp .env.example .env
chmod 600 .env
nano .env
```

Ajustar como mínimo:

```dotenv
POSTGRES_PASSWORD=<CONTRASENA_FUERTE>
RABBITMQ_PASSWORD=<CONTRASENA_FUERTE>
RABBITMQ_ERLANG_COOKIE=<COOKIE_FUERTE_Y_UNICA>

BFF_PUBLIC_HOST=0.0.0.0
BFF_PORT=8080
FRONTEND_PUBLIC_HOST=0.0.0.0
FRONTEND_PORT=80
FRONTEND_PUBLIC_ORIGIN=http://<IP_PUBLICA_DE_LA_INSTANCIA>

AWS_REGION=us-east-1
AWS_EC2_PUBLIC_IP=<IP_PUBLICA_DE_LA_INSTANCIA>
AWS_API_ENDPOINT=https://<API_ID>.execute-api.us-east-1.amazonaws.com
```

Puntos importantes:

- `BFF_PUBLIC_HOST=0.0.0.0` es obligatorio en EC2. Con `127.0.0.1` el API Gateway no puede alcanzar el BFF.
- `FRONTEND_PUBLIC_ORIGIN` debe coincidir con el origen permitido en el Gateway y con la Redirect/Logout URI de Entra ID.
- `environment.prod.ts` trae los valores documentados en `docs/GATEWAY.md`; si la IP cambia, actualizarlo antes de construir el frontend.
- No reutilizar las contraseñas de ejemplo en el laboratorio.
- Mantener el `.env` con permisos `600`.
- No commitear el `.env` ni pegar su contenido en el chat o en capturas.

Verificación sin imprimir secretos:

```bash
test -f .env && echo '.env existe'
grep -q '^BFF_PUBLIC_HOST=0.0.0.0$' .env && echo 'BFF_PUBLIC_HOST OK'
stat -c '%a %n' .env
```

---

## 6. Construir y arrancar

Los comandos se ejecutan desde `apps` y usan el `.env` de la raíz del repositorio:

```bash
cd ~/andesstay/andesstay-infra/apps
```

En una instancia con RAM suficiente:

```bash
docker-compose --env-file ../.env up --build -d --remove-orphans
```

En `t3.micro`, construir de forma secuencial:

```bash
COMPOSE_PARALLEL_LIMIT=1 docker-compose --env-file ../.env build
docker-compose --env-file ../.env up -d --remove-orphans
```

Esperar el arranque (Kafka y RabbitMQ tienen periodos de inicio de 60 segundos):

```bash
docker-compose --env-file ../.env ps
docker-compose --env-file ../.env logs -f --tail=100
```

Verificar que los servicios estén saludables:

```bash
docker-compose --env-file ../.env ps
```

Si algún servicio queda en `unhealthy`, revisar sus logs antes de continuar:

```bash
docker-compose --env-file ../.env logs --tail=100 ms-bff ms-reservations ms-catalog ms-audit ms-notify ms-rabbit-admin frontend
```

El servicio `frontend` compila Angular con `angular.json` → `environment.prod.ts` y sirve el resultado con nginx. Si la instancia tiene poca RAM, construirlo por separado:

```bash
docker-compose --env-file ../.env build frontend
docker-compose --env-file ../.env up -d --remove-orphans
```

---

## 7. Verificar servicios y RabbitMQ

### BFF y microservicios

```bash
curl -sS -o /dev/null -w 'BFF actuator: %{http_code}\n' http://127.0.0.1:8080/actuator/health
curl -sS -o /dev/null -w 'BFF api/health: %{http_code}\n' http://127.0.0.1:8080/api/health
curl -sS -o /dev/null -w 'Frontend health: %{http_code}\n' http://127.0.0.1/health

docker exec andesstay-ms-reservations wget -qO- http://localhost:8082/api/reservations/health
docker exec andesstay-ms-catalog wget -qO- http://localhost:8081/actuator/health
docker exec andesstay-ms-audit wget -qO- http://localhost:8084/api/audit/health
docker exec andesstay-ms-notify wget -qO- http://localhost:8083/api/notify/health
docker exec andesstay-ms-rabbit-admin wget -qO- http://localhost:8085/api/health
```

Los health checks deben responder `200` y estado `UP`. `ms-rabbit-admin` debe responder `status: UP`. No publica el puerto `8085` porque no tiene autenticación: se prueba solo con `docker exec`, nunca desde el host ni desde el Gateway. Ver [PRUEBAS-RABBIT-ADMIN.md](https://github.com/RolandoLillo/andesstay-infra/blob/7372c2f/docs/PRUEBAS-RABBIT-ADMIN.md) (PR #16).

Solo los puertos `80` y `8080` deben responder desde fuera de la instancia. Kafka y PostgreSQL no publican puertos; RabbitMQ publica `5672` y `15672` solo en `127.0.0.1`. Verificar con `docker-compose --env-file ../.env ps --format table`.

### Clúster RabbitMQ

```bash
docker exec andesstay-rabbitmq-1 rabbitmqctl cluster_status
docker exec andesstay-rabbitmq-2 rabbitmqctl cluster_status
docker exec andesstay-rabbitmq-1 rabbitmqctl list_queues name messages consumers
```

Deben aparecer los dos nodos `rabbit@rabbitmq-1` y `rabbit@rabbitmq-2` en ejecución, y las colas:

- `q.cmd.email`
- `q.cmd.housekeeping`
- `q.cmd.voucher`
- sus respectivas `.dlq`

### Acceso a la Management UI por túnel SSH

El puerto `15672` no se abre en el Security Group. Usar un túnel:

```bash
ssh -i ~/.ssh/andesstay-key.pem \
  -N -L 15672:127.0.0.1:15672 \
  ec2-user@"$EC2_PUBLIC_IP"
```

Mantener esa terminal abierta y visitar `http://localhost:15672`. Usar las credenciales `RABBITMQ_USERNAME`/`RABBITMQ_PASSWORD` del `.env`.

---

## 8. Actualizar el Gateway con la IP de EC2

Repetir este paso cada vez que cambie la IP pública de la instancia, salvo que se use Elastic IP.

Obtener la IP desde el equipo con AWS CLI:

```bash
export AWS_REGION=us-east-1
export INSTANCE_ID=i-xxxxxxxxxxxxxxxxx
EC2_PUBLIC_IP=$(aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' \
  --output text \
  --region "$AWS_REGION")
echo "$EC2_PUBLIC_IP"
```

Alternativa desde dentro de la instancia:

```bash
TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')
EC2_PUBLIC_IP=$(curl -s \
  -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4)
echo "$EC2_PUBLIC_IP"
```

Desplegar/actualizar el stack desde la raíz de `andesstay-infra`, previa confirmación del operador:

```bash
export AWS_REGION=us-east-1
export FRONTEND_PUBLIC_ORIGIN="http://${EC2_PUBLIC_IP}"
./aws/api-gateway/deploy.sh
```

El script usa `EC2_PUBLIC_IP`, aplica `BffUrl="http://${EC2_PUBLIC_IP}:8080"` y `AllowedOriginPublic="${FRONTEND_PUBLIC_ORIGIN}"`, y muestra el endpoint resultante.

Obtener el endpoint:

```bash
API=$(aws cloudformation describe-stacks \
  --stack-name andesstay-api-gateway \
  --query "Stacks[0].Outputs[?OutputKey=='HttpApiEndpoint'].OutputValue" \
  --output text \
  --region us-east-1)
API="${API%/}/prod"
echo "$API"
```

> `BffUrl` debe ser solo `http://<IP>:8080`, sin `/{proxy}`. La plantilla reenvía la ruta completa mediante `overwrite:path`.

Registrar `FRONTEND_PUBLIC_ORIGIN` como Redirect URI y Logout URI en la app registration de Entra ID. MSAL usa el mismo valor para ambas; debe ser idéntico al `redirectUri` de `environment.prod.ts`.

---

## 9. Pruebas por el API Gateway

Definir los tokens sin mostrarlos en pantalla ni en el historial:

```bash
read -r -s -p 'Token valido: ' TOKEN_VALIDO; echo
read -r -s -p 'Token Cliente: ' TOKEN_CLIENTE; echo
read -r -s -p 'Token Auditor: ' TOKEN_AUDITOR; echo
export TOKEN_AUDITOR
```

`read -s` no exporta la variable; `TOKEN_AUDITOR` debe exportarse para que el script de Python lo lea desde `os.environ`.

Comandos de estado (Bash/Git Bash/WSL):

```bash
curl -s -o /dev/null -w 'health sin token: %{http_code}\n' \
  "$API/api/health"

curl -s -o /dev/null -w 'me sin token: %{http_code}\n' \
  "$API/api/me"

curl -s -o /dev/null -w 'me con token valido: %{http_code}\n' \
  -H "Authorization: Bearer $TOKEN_VALIDO" \
  "$API/api/me"

curl -s -o /dev/null -w 'catalogo con Cliente: %{http_code}\n' \
  -H "Authorization: Bearer $TOKEN_CLIENTE" \
  "$API/api/catalog/units"

curl -s -o /dev/null -w 'auditoria con Auditor: %{http_code}\n' \
  -H "Authorization: Bearer $TOKEN_AUDITOR" \
  "$API/api/audit/events"

curl -s -o /dev/null -w 'ruta inexistente: %{http_code}\n' \
  "$API/api/ruta-inexistente"
```

En PowerShell usar `curl.exe` y reemplazar `-o /dev/null` por `-o NUL`.

Resultados esperados:

| Prueba | Token | Esperado |
|---|---|---|
| `GET /api/health` | Ninguno | `200` |
| `GET /api/me` | Ninguno | `401` |
| `GET /api/me` | Válido | `200` |
| `GET /api/catalog/units` | Cliente | `403` desde el BFF |
| `GET /api/audit/events` | Auditor | `200` |
| `GET /api/ruta-inexistente` | Ninguno | `404` |

Verificar que el `aud` sea el GUID sin `api://`, sin imprimir el token:

```bash
python3 - <<'PY'
import base64, json, os
payload = os.environ["TOKEN_AUDITOR"].split(".")[1]
payload += "=" * (-len(payload) % 4)
print(json.loads(base64.urlsafe_b64decode(payload))["aud"])
PY
```

PowerShell:

```powershell
$p = $env:TOKEN_AUDITOR.Split('.')[1].Replace('-','+').Replace('_','/')
$p += '=' * ((4 - $p.Length % 4) % 4)
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($p)) |
  ConvertFrom-Json |
  Select-Object -ExpandProperty aud
```

El resultado debe ser el Client ID en formato GUID, sin el prefijo `api://`.

---

## 10. Evidencia de publicación y consumo en RabbitMQ

Con la Management UI abierta por el túnel SSH:

1. Ir a **Exchanges** y abrir `cmd.direct`.
2. Usar **Publish message**.
3. Routing key: `email.send`.
4. Content type: `application/json`.
5. Publicar este payload de prueba:

```json
{
  "type": "email.send",
  "eventId": "ec2-evidence-email-001",
  "timestamp": "2026-10-27T12:00:00Z",
  "traceId": "ec2-evidence-trace-001",
  "correlationId": "ec2-evidence-corr-001",
  "payload": {
    "reservationId": "EC2-DEMO-001",
    "guestName": "Prueba EC2",
    "kind": "CONFIRMATION",
    "channel": "EMAIL",
    "guestEmail": "prueba@andesstay.cl"
  }
}
```

6. Volver a **Queues** y comprobar que `q.cmd.email` no acumula mensajes y tiene un consumidor activo.
7. Revisar el log del consumidor:

```bash
docker-compose --env-file ../.env logs --tail=100 ms-notify
```

Debe aparecer un mensaje similar a:

```text
Guest notification delivered reservationId=EC2-DEMO-001 channel=EMAIL kind=CONFIRMATION eventId=ec2-evidence-email-001
```

Capturar la pantalla donde se vea la publicación/consumo y el log o el estado de la cola.

---

## 11. Capturas requeridas

Guardar las capturas en `evidencias/` (o en el directorio indicado por el curso), sin tokens ni contraseñas visibles:

- `10-rabbit-cluster.png`: `cluster_status` mostrando `rabbit@rabbitmq-1` y `rabbit@rabbitmq-2`.
- `11-rabbit-queues.png`: Management UI o `rabbitmqctl list_queues` con las colas `q.cmd.*` y sus `.dlq`.
- `12-publish-consume.png`: publicación en `cmd.direct` (`email.send`) y consumo/cola vacía con consumidor activo.
- `20-pruebas-gateway.png`: resultados de las pruebas `200/401/403/404` por Gateway.
- `21-gateway-config.png`: API Gateway con rutas y JWT Authorizer configurados.
- `22-ec2-security-group.png`: instancia EC2 y Security Group con solo los puertos `22`, `80` y `8080` de entrada.
- `23-frontend-ec2.png`: frontend Angular cargado desde `http://<IP_PUBLICA>` y login MSAL completado.
- `24-entra-redirect.png`: Redirect URI y Logout URI de Entra ID con el mismo origen del frontend.

Antes de adjuntar:

- Ocultar el valor de `Authorization: Bearer ...`.
- Ocultar contraseñas de RabbitMQ, PostgreSQL y cookies Erlang.
- No mostrar el contenido del `.env`.
- No mostrar tokens en el historial del terminal ni en la barra de direcciones.

---

## 12. Checklist de aceptación

- [ ] Instancia Amazon Linux 2023 preparada con Docker y `docker-compose`.
- [ ] Swap creado y visible en `swapon --show`.
- [ ] Repositorios hermanos clonados en `~/andesstay`.
- [ ] `.env` creado desde `.env.example`, con permisos `600` y `BFF_PUBLIC_HOST=0.0.0.0`.
- [ ] Security Group con solo `22`, `80` y `8080` de entrada.
- [ ] Stack levantado, incluido el frontend, y servicios saludables.
- [ ] Frontend compilado con `environment.prod.ts` y sirviendo en el puerto `80`.
- [ ] Clúster RabbitMQ con dos nodos y colas declaradas.
- [ ] `ms-rabbit-admin` saludable vía `docker exec` y sin puerto publicado.
- [ ] Gateway actualizado con la IP pública y el origen del frontend.
- [ ] Redirect URI y Logout URI de Entra ID actualizadas.
- [ ] Pruebas por Gateway con los códigos esperados.
- [ ] Capturas `10` a `12` y `20` a `24` obtenidas y sanitizadas.
- [ ] Ningún comando de AWS ejecutado desde el agente.
