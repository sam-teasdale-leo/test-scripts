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

echo "User ID: $USER_ID"
echo "Passwordless code: $CODE"
echo "Accepted Terms of Service Version: $ACCEPTED_TERMS_OF_SERVICE_VERSION"
echo

# Try to login with bad password and show that account is not yet locked
echo "Step 2: Try to login with bad password"
echo

BAD_LOGIN_RESPONSE_01=$(curl -s -w '\n%{http_code}' -X 'POST' \
  'http://10.170.1.142:4000/api/v2/login' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{
  "login_id": "testuser",
  "password": "testloser"
}')

HTTP_CODE=$(echo "$BAD_LOGIN_RESPONSE_01" | tail -1)
BODY=$(echo "$BAD_LOGIN_RESPONSE_01" | sed '$d')

echo "HTTP Status: $HTTP_CODE"
echo "$BODY" | jq .

# Try to login again with bad password and show that account is not yet locked
echo "Step 3: Try to login with bad password"
echo

BAD_LOGIN_RESPONSE_02=$(curl -s -w '\n%{http_code}' -X 'POST' \
  'http://10.170.1.142:4000/api/v2/login' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{
  "login_id": "testuser",
  "password": "testloser"
}')

HTTP_CODE=$(echo "$BAD_LOGIN_RESPONSE_02" | tail -1)
BODY=$(echo "$BAD_LOGIN_RESPONSE_02" | sed '$d')

echo "HTTP Status: $HTTP_CODE"
echo "$BODY" | jq .

# Try to login again with bad password and show that account is not yet locked
echo "Step 4: Try to login with bad password"
echo

BAD_LOGIN_RESPONSE_03=$(curl -s -w '\n%{http_code}' -X 'POST' \
  'http://10.170.1.142:4000/api/v2/login' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{
  "login_id": "testuser",
  "password": "testloser"
}')

HTTP_CODE=$(echo "$BAD_LOGIN_RESPONSE_03" | tail -1)
BODY=$(echo "$BAD_LOGIN_RESPONSE_03" | sed '$d')

echo "HTTP Status: $HTTP_CODE"
echo "$BODY" | jq .