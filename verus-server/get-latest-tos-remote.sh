#!/bin/bash

echo
echo "Step 1: Getting passwordless login code..."
echo

LOGIN_RESPONSE=$(curl -s -X 'POST' \
  'https://verus-auth-development.threatdeterrence.com/api/v2/login' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{
  "login_id": "sam.teasdale@leotechnologies.com",
  "password": "l!dzFL5kgOP4"
}')

USER_ID=$(echo "$LOGIN_RESPONSE" | jq -r .user.id)
CODE=$(echo "$LOGIN_RESPONSE" | jq -r .passwordless_login_code)

echo "User ID: $USER_ID"
echo "Passwordless code: $CODE"
echo

# Step 2: Use that code to get authentication tokens
echo "Step 2: Exchanging code for tokens..."

TOKEN_EXCHANGE_RESPONSE=$(curl -s -X 'POST' 'http://10.170.1.142:24100/api/v2/authentication/token' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d "{\"passwordless_login_code\": \"$CODE\"}")

# echo "$TOKEN_EXCHANGE_RESPONSE" | jq .

TOKEN=$(echo "$TOKEN_EXCHANGE_RESPONSE" | jq -r .token)
REFRESH_TOKEN=$(echo "$TOKEN_EXCHANGE_RESPONSE" | jq -r .refresh_token)

echo
echo "Token: ${TOKEN:0:50}..."
echo "Refresh Token: ${REFRESH_TOKEN:0:50}..."
echo

# Step 3: Hit the /api/v1/:user_id/terms-of-service endpoint to get
# a presigned URL for the latest TOS version that I've accepted.

echo "Step 3: Getting presigned URL for my accepted Terms of Service..."
echo

USER_TOS_RESPONSE=$(curl -s -X 'GET' "http://10.170.1.142:24100/api/v1/users/${USER_ID}/terms-of-service" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/vnd.api+json" \
  -H "Accept: application/vnd.api+json" \
)

echo "$USER_TOS_RESPONSE" | jq .

