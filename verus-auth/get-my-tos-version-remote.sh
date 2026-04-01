#!/bin/bash

echo
echo "Step 1: Getting passwordless login code..."
echo

LOGIN_RESPONSE=$(curl -s -X 'POST' \
  'http://10.170.1.142:4000/api/v2/login' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{
  "login_id": "testuser",
  "password": "testuser"
}')

# echo "$LOGIN_RESPONSE" | jq .

# Exract the passwordless login code and latest accepted terms of service version from response
USER_ID=$(echo "$LOGIN_RESPONSE" | jq -r '.user.id')
CODE=$(echo "$LOGIN_RESPONSE" | jq -r '.passwordless_login_code')
ACCEPTED_TERMS_OF_SERVICE_VERSION=$(echo "$LOGIN_RESPONSE" | jq -r '.user.data.terms_of_service.version')

echo "User ID: $USER_ID"
echo "Passwordless code: $CODE"
echo "Accepted Terms of Service Version: $ACCEPTED_TERMS_OF_SERVICE_VERSION"
echo

