#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
STACK_NAME="${STACK_NAME:-andesstay-api-gateway}"
TEMPLATE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/http-api.yml"

: "${EC2_PUBLIC_IP:?Definir EC2_PUBLIC_IP}"
: "${FRONTEND_PUBLIC_ORIGIN:?Definir FRONTEND_PUBLIC_ORIGIN}"

aws cloudformation deploy \
  --template-file "$TEMPLATE_FILE" \
  --stack-name "$STACK_NAME" \
  --parameter-overrides \
    BffUrl="http://${EC2_PUBLIC_IP}:8080" \
    AllowedOriginPublic="${FRONTEND_PUBLIC_ORIGIN}" \
  --capabilities CAPABILITY_IAM \
  --no-fail-on-empty-changeset \
  --region "$AWS_REGION"

aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='HttpApiEndpoint'].OutputValue" \
  --output text \
  --region "$AWS_REGION"
