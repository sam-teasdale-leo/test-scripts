#!/bin/bash

# Step 1: Start passwordless login and get the code
echo
echo "Step 1: Getting passwordless login code..."
CODE=$(curl -s -X POST 'http://10.170.1.142:4000/api/v1/authentication/login' \
  -H 'Content-Type: application/json' \
  -d '{
    "application_id": "cb03c396-7c8c-402f-97fa-77354cfcce4c",
    "login_id": "testuser@localtest.com"
  }' | jq -r '.passwordless_login_code')

echo
echo "Passwordless code: $CODE"
echo

# Step 2: Use that code to get authentication tokens
echo "Step 2: Exchanging code for tokens..."
RESPONSE=$(curl -s -X POST 'http://10.170.1.142:4000/api/v1/authentication/token' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d "{
  \"passwordless_login_code\": \"$CODE\"
}")

# echo "$RESPONSE" | jq .

# Extract token and refresh_token from response
TOKEN=$(echo "$RESPONSE" | jq -r '.token')
REFRESH_TOKEN=$(echo "$RESPONSE" | jq -r '.refresh_token')

echo
echo "Token: ${TOKEN:0:100}..."
echo "Refresh Token: ${REFRESH_TOKEN:0:100}..."
echo

# Step 3: Refresh the token
echo "Step 3: Refreshing the token..."
RESPONSE=$(curl -s -X POST 'http://10.170.1.142:4000/api/v1/authentication/token-refresh' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d "{
  \"token\": \"$TOKEN\",
  \"refresh_token\": \"$REFRESH_TOKEN\"
}")

# echo "$RESPONSE" | jq .

# Extract updated token and refresh_token from response
TOKEN=$(echo "$RESPONSE" | jq -r '.token')
REFRESH_TOKEN=$(echo "$RESPONSE" | jq -r '.refresh_token')

echo
echo "Token: ${TOKEN:0:100}..."
echo "Refresh Token: ${REFRESH_TOKEN:0:100}..."
echo

