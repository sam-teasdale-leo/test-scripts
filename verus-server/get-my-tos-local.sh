#!/bin/bash

echo
echo "Step 1: Getting passwordless login code..."

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

TOKEN_EXCHANGE_RESPONSE=$(curl -s -X 'POST' 'https://verus-development.threatdeterrence.com/api/v2/authentication/token' \
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

echo "Step 3: Getting my accepted Terms of Service..."








# Step 3: Hit the /api/v1/audits endpoint
# echo "Step 3: Using token to hit the audits endpoint..."

# AUDITS_RESPONSE=$(curl -s -X 'POST' 'https://verus-development.threatdeterrence.com/api/v1/audits' \
#   -H "Authorization: Bearer ${TOKEN}" \
#   -H "Content-Type: application/vnd.api+json" \
#   -H "Accept: application/vnd.api+json" \
#   -d '{
#     "filter": {
#       "date_from": "2020-01-01T00:00:00Z",
#       "date_to": "2025-12-31T23:59:59Z"
#     },
#     "page": {
#       "page": 1,
#       "size": 25
#     },
#     "sort": "date"
#   }')


# echo "Audits response:"
# echo "$AUDITS_RESPONSE" | jq .
# echo