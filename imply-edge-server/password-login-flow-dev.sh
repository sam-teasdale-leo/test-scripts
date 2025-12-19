#!/bin/bash

# Step 1: Start passwordless login and get the code
echo
echo "Step 1: Getting passwordless login code..."
CODE=$(curl -s -X POST 'https://imply-edge-server.verus-development.development.threatdeterrence.com/api/v1/authentication/login' \
  -H 'Content-Type: application/json' \
  -d '{
    "application_id": "7bdbf776-76e5-4832-8192-af4446faae66",
    "login_id": "sam.teasdale@leotechnologies.com"
  }' | jq -r '.passwordless_login_code')

echo "Passwordless code: $CODE"
echo

# Step 2: Use that code to get authentication tokens
echo "Step 2: Exchanging code for tokens..."
RESPONSE=$(curl -s -X POST 'https://imply-edge-server.verus-development.development.threatdeterrence.com/api/v1/authentication/token' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d "{
  \"passwordless_login_code\": \"$CODE\"
}")

echo "$RESPONSE" | jq .

# Extract token and refresh_token from response
TOKEN=$(echo "$RESPONSE" | jq -r '.token')
REFRESH_TOKEN=$(echo "$RESPONSE" | jq -r '.refresh_token')

echo
echo "Token: ${TOKEN:0:50}..."
echo "Refresh Token: ${REFRESH_TOKEN:0:50}..."
echo

# Step 3: Refresh the token
echo "Step 3: Refreshing the token..."
curl -s -X POST 'https://imply-edge-server.verus-development.development.threatdeterrence.com/api/v1/authentication/token-refresh' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d "{
  \"token\": \"$TOKEN\",
  \"refresh_token\": \"$REFRESH_TOKEN\"
}" | jq .
