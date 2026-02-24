#!/bin/bash

# Step 1: Start passwordless login and get the code
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

# CODE=$(curl -s -X POST 'https://imply-edge-server.verus-development.development.threatdeterrence.com/api/v1/authentication/login' \
#   -H 'Content-Type: application/json' \
#   -d '{
#     "application_id": "7bdbf776-76e5-4832-8192-af4446faae66",
#     "login_id": "sam.teasdale@leotechnologies.com"
#   }' | jq -r '.passwordless_login_code')

# echo "Passwordless code: $CODE"
# echo

# Step 2a: Use that code to get authentication tokens
echo "Step 2a: Exchanging code for tokens..."
echo

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
echo "Token: ${TOKEN:0:100}..."
echo "Refresh Token: ${REFRESH_TOKEN:0:100}..."
echo

# Step 2b: Hit the token-refresh endpoint to refresh the token
echo "Step 2b: Refreshing token..."
echo

TOKEN_REFRESH_RESPONSE=$(curl -s -X POST 'https://imply-edge-server.verus-development.development.threatdeterrence.com/api/v1/authentication/token-refresh' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d "{
    \"token\": \"$TOKEN\",
    \"refresh_token\": \"$REFRESH_TOKEN\"
  }")

echo "$TOKEN_REFRESH_RESPONSE" | jq .

# Extract token and refresh_token from response
TOKEN=$(echo "$TOKEN_REFRESH_RESPONSE" | jq -r '.token')
REFRESH_TOKEN=$(echo "$TOKEN_REFRESH_RESPONSE" | jq -r '.refresh_token')

# Step 3: Try the /api/v1/common-receivers endpoint
echo "Step 3: Hitting the /api/v1/common-receivers endpoint..."
echo

COMMON_RECEIVERS_RESPONSE=$(curl -s -X POST 'https://imply-edge-server.verus-development.development.threatdeterrence.com/api/v1/common-receivers' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Forwarded-For: $MY_IP" \
  -d "{
    \"country_codes\":[\"+1\"],
    \"date_filter\":\"2025-07-01 - 2025-12-31\",
    \"page\":1,
    \"per_page\":3,
    \"receiver_states\":[],
    \"sites\":[],
    \"tenant_names\":[\"aldoc\",\"blount-al\"]
}")

echo "$COMMON_RECEIVERS_RESPONSE" | jq .
echo

# Step 4: Try the /api/v1/common-receivers-calls endpoint
echo "Step 4: Hitting the /api/v1/common-receivers-calls endpoint..."
echo

COMMON_RECEIVERS_CALLS_RESPONSE=$(curl -s -X POST 'https://imply-edge-server.verus-development.development.threatdeterrence.com/api/v1/common-receivers-calls' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Forwarded-For: $MY_IP" \
  -d "{
    \"country_codes\":[\"+1\"],
    \"date_filter\":\"2025-07-01 - 2025-12-31\",
    \"page\":1,
    \"per_page\":3,
    \"receiver_states\":[],
    \"receiver_numbers\":[\"12055950567\"],
    \"sites\":[],
    \"tenant_names\":[\"aldoc\",\"blount-al\"]
}")

echo "$COMMON_RECEIVERS_CALLS_RESPONSE" | jq .
echo

# Step 5: Try the /api/v1/receiver-search endpoint
echo "Step 5: Hitting the /api/v1/receiver-search endpoint..."
echo

RECEIVER_SEARCH_RESPONSE=$(curl -s -X POST 'https://imply-edge-server.verus-development.development.threatdeterrence.com/api/v1/receiver-search' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Forwarded-For: $MY_IP" \
  -d "{
    \"country_codes\":[\"+1\"],
    \"date_filter\":\"2025-07-01 - 2025-12-31\",
    \"page\":1,
    \"per_page\":3,
    \"receiver_numbers\":[\"12055950567\"],
    \"receiver_states\":[],
    \"sites\":[],
    \"sort_by\": \"duration\",
    \"sort_order\": \"desc\",
    \"tenant_names\":[\"aldoc\",\"blount-al\"]
}")

echo "$RECEIVER_SEARCH_RESPONSE" | jq .
echo

# Step 6: Try the /api/v1/sites endpoint
echo "Step 6: Hitting the /api/v1/sites endpoint..."
echo

SITES_RESPONSE=$(curl -s -X POST 'https://imply-edge-server.verus-development.development.threatdeterrence.com/api/v1/sites' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Forwarded-For: $MY_IP" \
  -d "{
    \"page\":1,
    \"per_page\":2,
    \"site_sort_by\":\"site_name\",
    \"site_sort_order\":\"asc\",
    \"tenant_sort_by\":\"tenant_name\",
    \"tenant_sort_order\":\"asc\",
    \"tenant_names\":[\"blount-al\"]
}")

echo "$SITES_RESPONSE" | jq .
echo

# Step 7: Try the /api/v1/tenants endpoint
echo "Step 7: Hitting the /api/v1/tenants endpoint..."
echo

TENANTS_RESPONSE=$(curl -s -X POST 'https://imply-edge-server.verus-development.development.threatdeterrence.com/api/v1/tenants' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Forwarded-For: $MY_IP" \
  -d "{
    \"page\":1,
    \"per_page\":2,
    \"sort_by\":\"state\",
    \"sort_order\":\"asc\"
}")

echo "$TENANTS_RESPONSE" | jq .
echo

# Step 8: Try the /api/v1/receiver-states endpoint
echo "Step 8: Hitting the /api/v1/receiver-states endpoint..."
echo

RECEIVER_STATES_RESPONSE=$(curl -s -X POST 'https://imply-edge-server.verus-development.development.threatdeterrence.com/api/v1/receiver-states' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Forwarded-For: $MY_IP" \
  -d "{
    \"page\":1,
    \"per_page\":2,
    \"sort_by\":\"state\",
    \"sort_order\":\"asc\"
}")

echo "$RECEIVER_STATES_RESPONSE" | jq .
echo

# Step 9: Try the /api/v1/audits endpoint
echo "Step 9: Hitting the /api/v1/audits endpoint..."
echo

AUDITS_RESPONSE=$(curl -s -X POST 'https://imply-edge-server.verus-development.development.threatdeterrence.com/api/v1/search/audits?page=1&page_size=3' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Forwarded-For: $MY_IP" \
  -d "{
    \"filter\": {
      \"object\": \"common-receivers-calls\",
      \"operation\": \"search\"
    },
    \"sort\": \"date_desc\"
}")

# AUDITS_RESPONSE=$(curl -s -X POST 'https://imply-edge-server.verus-development.development.threatdeterrence.com/api/v1/search/audits?page=1&page_size=3' \
#   -H 'accept: application/json' \
#   -H 'Content-Type: application/json' \
#   -H "Authorization: Bearer $TOKEN" \
#   -H "X-Forwarded-For: $MY_IP" \
#   -d "{
#     \"filter\": {
#       \"date_from\": \"2026-02-05T20:40:00Z\",
#       \"date_to\": \"2026-02-05T23:59:59Z\",
#       \"object\": \"common-receivers-calls\",
#       \"operation\": \"search\",
#       \"ips\": [\"192.168.3.48\", \"192.168.20.254\"],
#       \"user_ids\": [\"550e8400-e29b-41d4-a716-446655440000\", \"00000000-0000-0000-0000-000000000001\"]
#     },
#     \"sort\": \"date_desc\"
# }")

echo "$AUDITS_RESPONSE" | jq .
echo

# Step 10: Try the /api/v1/autocomplete endpoint

echo "Step 10: Hitting the /api/v1/autocomplete endpoint..."
echo

AUTOCOMPLETE_RESPONSE=$(curl -s -X GET 'https://imply-edge-server.verus-development.development.threatdeterrence.com/api/v1/autocomplete?source=audit&entity=users&query=Te' \
  -H 'accept: application/json' \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Forwarded-For: $MY_IP"
)

echo "$AUTOCOMPLETE_RESPONSE" | jq .
echo