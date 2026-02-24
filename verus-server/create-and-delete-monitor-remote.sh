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

# Step 3: Hit the POST api/v2/monitors endpoint to create a monitor
echo "Step 3: Creating a monitor..."
echo

CREATE_MONITOR_RESPONSE=$(curl -s -X 'POST' 'http://10.170.1.142:24100/api/v2/monitors' \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -d '{
    "email_frequency": "disabled",
    "monitor_name": "Public Safety Monitor",
    "receiver_emails": [
      "admin@example.com"
    ],
    "receiver_full_names": [
      "Doe, John"
    ],
    "receiver_information": [
      "officer*",
      "supervisor~"
    ],
    "receiver_numbers": [
      "1234567890"
    ],
    "resident_data": [
      {
        "resident_full_name": "Smith, Jane",
        "resident_handle": "Smith, Jane (123456)",
        "resident_id": "123456"
      }
    ],
    "resident_full_names": [
      "Smith, Jane"
    ],
    "resident_ids": [
      "123456"
    ],
    "resident_information": [
      "floor*",
      "building~"
    ],
    "site_ids": [
      "SITE123"
    ],
    "starred": false,
    "station_names": [
      "Station A",
      "Station B"
    ],
    "transcription": [
      "incident",
      "emergency"
    ]
}')

echo "$CREATE_MONITOR_RESPONSE" | jq .
echo

MONITOR_ID=$(echo "$CREATE_MONITOR_RESPONSE" | jq -r .id)
echo "Created monitor with ID: $MONITOR_ID"
echo

# Step 4: Hit the DELETE api/v2/monitors/:monitor_id endpoint to delete the monitor
echo "Step 4: Deleting the monitor with ID: $MONITOR_ID..."
echo

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X 'DELETE' "http://10.170.1.142:24100/api/v2/monitors/$MONITOR_ID" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json')

echo "HTTP Response Code: $HTTP_CODE"
echo