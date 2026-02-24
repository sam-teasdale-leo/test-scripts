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

# echo "$LOGIN_RESPONSE" | jq .

# Exract the passwordless login code and latest accepted terms of service version from response
USER_ID=$(echo "$LOGIN_RESPONSE" | jq -r '.user.id')
CODE=$(echo "$LOGIN_RESPONSE" | jq -r '.passwordless_login_code')

echo "User ID: $USER_ID"
echo "Passwordless code: $CODE"
echo "Accepted Terms of Service Version: $ACCEPTED_TERMS_OF_SERVICE_VERSION"
echo

# Try to login with bad password and show that account is not yet locked
echo "Step 2: Try to login with bad password"
echo

BAD_LOGIN_RESPONSE=$(curl -s -w '\n%{http_code}' -X 'POST' \
  'https://verus-auth-development.threatdeterrence.com/api/v2/login' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{
  "login_id": "sam.teasdale@leotechnologies.com",
  "password": "wrongpassword"
}')

HTTP_CODE=$(echo "$BAD_LOGIN_RESPONSE" | tail -1)
BODY=$(echo "$BAD_LOGIN_RESPONSE" | sed '$d')

echo "HTTP Status: $HTTP_CODE"
echo "$BODY" | jq .