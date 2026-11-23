#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
API_ID="${API_ID:-lmv59t05gg}"
STAGE_NAME="${STAGE_NAME:-prod}"
EC2_PUBLIC_IP="${EC2_PUBLIC_IP:-}"
FRONTEND_DOMAIN="${FRONTEND_DOMAIN:-}"

: "${EC2_PUBLIC_IP:?Definir EC2_PUBLIC_IP con la Elastic IP}"
: "${FRONTEND_DOMAIN:?Definir FRONTEND_DOMAIN, p. ej. 54-211-241-28.sslip.io}"

if [[ "$FRONTEND_DOMAIN" == http* || "$FRONTEND_DOMAIN" == */ ]]; then
  echo "FRONTEND_DOMAIN debe ser solo el host, sin https:// ni barra final" >&2
  exit 1
fi

ALLOWED_ORIGIN="https://${FRONTEND_DOMAIN}"

CORS_FILE="$(mktemp)"
trap 'rm -f "$CORS_FILE"' EXIT
cat > "$CORS_FILE" <<EOF
{
  "AllowOrigins": ["${ALLOWED_ORIGIN}", "http://localhost:4200"],
  "AllowMethods": ["GET", "POST", "PUT", "DELETE", "OPTIONS"],
  "AllowHeaders": ["Authorization", "Content-Type"],
  "AllowCredentials": false,
  "MaxAge": 3600
}
EOF

aws apigatewayv2 update-api \
  --api-id "$API_ID" \
  --cors-configuration "file://${CORS_FILE}" \
  --region "$AWS_REGION" >/dev/null

INTEGRATION_ID="$(aws apigatewayv2 get-integrations \
  --api-id "$API_ID" \
  --query "Items[?IntegrationType=='HTTP_PROXY'].IntegrationId | [0]" \
  --output text \
  --region "$AWS_REGION")"

if [[ -z "$INTEGRATION_ID" || "$INTEGRATION_ID" == "None" ]]; then
  echo "No se encontro una integracion HTTP_PROXY en el API $API_ID" >&2
  exit 1
fi

aws apigatewayv2 update-integration \
  --api-id "$API_ID" \
  --integration-id "$INTEGRATION_ID" \
  --integration-uri "http://${EC2_PUBLIC_IP}:8080" \
  --region "$AWS_REGION" >/dev/null

echo "API_BASE=https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com/${STAGE_NAME}/api"
echo "ALLOWED_ORIGIN=${ALLOWED_ORIGIN}"
echo "INTEGRATION_URI=http://${EC2_PUBLIC_IP}:8080"
