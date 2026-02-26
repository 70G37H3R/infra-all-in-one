#!/bin/bash
set -e

ROLE_ARN="arn:aws:iam::590183708030:role/DevOps-Terraform-Role"
SESSION_NAME="terraform-session"
PROFILE_SOURCE="devops-user"

echo "Assuming role..."

CREDS=$(aws sts assume-role \
  --role-arn "$ROLE_ARN" \
  --role-session-name "$SESSION_NAME" \
  --profile "$PROFILE_SOURCE")

if [ -z "$CREDS" ]; then
  echo "Assume role failed"
  return 1
fi

echo "$CREDS"
export AWS_ACCESS_KEY_ID=$(echo "$CREDS" | jq -r '.Credentials.AccessKeyId')
export AWS_SECRET_ACCESS_KEY=$(echo "$CREDS" | jq -r '.Credentials.SecretAccessKey')
export AWS_SESSION_TOKEN=$(echo "$CREDS" | jq -r '.Credentials.SessionToken')

aws sts get-caller-identity