#!/bin/bash

echo
echo "Step 1: Getting passwordless login code..."

CODE=$(curl -s -X 'POST' \
  'https://verus-auth-development.threatdeterrence.com/api/v2/login' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{
  "login_id": "sam.teasdale@leotechnologies.com",
  "password": "l!dzFL5kgOP4"
}' | jq -r .passwordless_login_code)

echo "Passwordless code: $CODE"
echo

# Step 2: Use that code to get authentication tokens
echo "Step 2: Exchanging code for tokens..."

RESPONSE=$(curl -s -X 'POST' 'https://verus-development.threatdeterrence.com/api/v2/authentication/token' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d "{\"passwordless_login_code\": \"$CODE\"}")

# echo "$RESPONSE" | jq .

TOKEN=$(echo "$RESPONSE" | jq -r .token)
REFRESH_TOKEN=$(echo "$RESPONSE" | jq -r .refresh_token)

echo
echo "Token: ${TOKEN:0:50}..."
echo "Refresh Token: ${REFRESH_TOKEN:0:50}..."
echo

# Step 3: Hit the /api/v1/audits endpoint
echo "Step 3: Using token to hit the audits endpoint..."

# AUDITS=$(curl -s -X 'POST' 'https://verus-development.threatdeterrence.com/api/v1/audits' \
#   -H "Authorization: Bearer ${TOKEN}" \
#   -H "Content-Type: application/json" \
#   -H "Accept: application/json" \
#   -d '{}')

AUDITS_RESPONSE=$(curl -s -X 'POST' 'https://verus-development.threatdeterrence.com/api/v1/audits' \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/vnd.api+json" \
  -H "Accept: application/vnd.api+json" \
  -d '{
    "filter": {
      "date_from": "2020-01-01T00:00:00Z",
      "date_to": "2025-12-31T23:59:59Z"
    },
    "page": {
      "page": 1,
      "size": 25
    },
    "sort": "date"
  }')


echo "Audits response:"
echo "$AUDITS_RESPONSE" | jq .
echo