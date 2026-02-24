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
ACCEPTED_TERMS_OF_SERVICE_VERSION=$(echo "$LOGIN_RESPONSE" | jq -r '.user.data.terms_of_service.version')

echo "User ID: $USER_ID"
echo "Passwordless code: $CODE"
echo "Accepted Terms of Service Version: $ACCEPTED_TERMS_OF_SERVICE_VERSION"
echo
echo "Step 2: Get all terms of service versions..."
echo

TOS_RESPONSE=$(curl -s -X 'GET' \
  "https://verus-auth-development.threatdeterrence.com/api/v2/terms-of-service?passwordless_login_code=$CODE&user_id=$USER_ID" \
  -H 'accept: application/json')

echo "$TOS_RESPONSE" | jq .
