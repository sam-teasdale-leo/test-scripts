#!/bin/bash
#
# Test script for the verus-report-renderer generate_translation_document API.
#
# This script tests the POST /api/v1/generate_translation_document endpoint by
# spinning up a temporary pod inside the verus-report-renderer Kubernetes
# namespace and sending a SigV4-signed request with fake conversation data.
#
# Why a temporary pod?
#   The service runs inside the cluster behind an internal ALB. Hitting it from
#   outside requires going through the ALB which also enforces AWS SigV4 auth.
#   By running a pod in the same namespace, we can reach the ClusterIP service
#   directly and only need to satisfy the application-level SigV4 check.
#
# How authentication works:
#   The verus-report-renderer is an Elixir/Phoenix app that uses a custom SigV4
#   verification plug (PlugExAwsSig4). It does NOT use standard AWS IAM for
#   request auth. Instead, it stores a static access_key/secret_key pair in an
#   ETS table (:ExAwsSig4_creds) and validates incoming requests against those
#   credentials using a custom region ("single-verus-region") and service name
#   ("verus-report-renderer"). This script pulls those credentials dynamically
#   from the running pod so they don't need to be hardcoded.
#

# ---- Configuration ----

NAMESPACE="verus-report-renderer"
SERVICE_URL="http://verus-report-renderer/api/v1/generate_translation_document"
POD_NAME="translation-doc-test"
POD_IMAGE="amazon/aws-cli:latest"

# These are the custom SigV4 region and service names that the app's
# PlugExAwsSig4 plug expects in the Credential scope of the Authorization
# header. They are NOT real AWS region/service values — they're application-
# specific identifiers baked into the VerusSig4Provider module.
SIGV4_REGION="single-verus-region"
SIGV4_SERVICE="verus-report-renderer"

# Default S3 bucket where generated PDFs are uploaded.
DEFAULT_BUCKET="verus-development-reports"

usage() {
  echo "Usage: $(basename "$0") [--bucket <bucket-name>] [--key <s3-key>]"
  echo ""
  echo "Sends a test request to the generate_translation_document endpoint"
  echo "from a temporary pod inside the $NAMESPACE namespace."
  echo ""
  echo "Options:"
  echo "  --bucket   S3 bucket for the generated PDF output (default: $DEFAULT_BUCKET)"
  echo "  --key      S3 key/path for the generated PDF output (default: auto-generated)"
  echo ""
  echo "Example:"
  echo "  $(basename "$0")"
  echo "  $(basename "$0") --bucket my-bucket --key custom/path/report.pdf"
  exit 1
}

# ---- Parse command-line arguments ----

BUCKET=""
KEY=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --bucket) BUCKET="$2"; shift 2 ;;
    --key)    KEY="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# Fall back to defaults if not provided. The key is auto-generated using the
# local username, a static test UUID, and a timestamped filename so that
# repeated runs don't collide with each other in S3.
BUCKET="${BUCKET:-$DEFAULT_BUCKET}"
KEY="${KEY:-$(whoami)/00000000-aaaa-bbbb-cccc-000000000000/reports/report_$(date +%Y%m%d_%H%M%S).pdf}"

echo ""
echo "=== Test: generate_translation_document ==="
echo "  Namespace: $NAMESPACE"
echo "  Bucket:    $BUCKET"
echo "  Key:       $KEY"
echo ""

# ---- Fetch SigV4 credentials from the running service ----
#
# The app's VerusSig4Provider GenServer loads credentials into an ETS table
# called :ExAwsSig4_creds on startup. Each entry is a {access_key, secret_key}
# tuple. We exec into the running pod and use the Elixir release's `rpc`
# command to read them from the live BEAM node, so the script stays in sync
# even if the credentials change.

echo "Fetching SigV4 credentials from the running service..."

# Find the first running pod that matches the app label.
APP_POD=$(kubectl get pods -n "$NAMESPACE" \
  -l app.kubernetes.io/name="$NAMESPACE" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -z "$APP_POD" ]]; then
  echo "Error: could not find a running $NAMESPACE pod."
  exit 1
fi

# Run an Elixir expression on the live node via `rpc`. This reads the single
# credential tuple from the ETS table and prints it as "access_key:secret_key".
# We grab just the last line of output to skip any Erlang/OTP log noise.
CREDS_RAW=$(kubectl exec "$APP_POD" -n "$NAMESPACE" -- \
  /opt/bin/verus_report_renderer rpc '
    [{ak, sk}] = :ets.tab2list(:ExAwsSig4_creds)
    IO.puts("#{ak}:#{sk}")
  ' 2>&1 | tail -1)

# Split on the first colon to separate access key from secret key.
SIGV4_ACCESS_KEY="${CREDS_RAW%%:*}"
SIGV4_SECRET_KEY="${CREDS_RAW#*:}"

if [[ -z "$SIGV4_ACCESS_KEY" || -z "$SIGV4_SECRET_KEY" ]]; then
  echo "Error: failed to retrieve SigV4 credentials from pod $APP_POD."
  echo "Raw output: $CREDS_RAW"
  exit 1
fi

echo "  Access Key: ${SIGV4_ACCESS_KEY:0:8}..."
echo ""

# ---- Build the test payload ----
#
# This constructs a minimal but valid GenerateTranslationDocumentRequest with:
#   - pdf_options:    controls PDF formatting (letter size, document type, etc.)
#   - upload_options: tells the service where to put the generated PDF in S3
#   - conversation:   fake conversation with two phrases (one per speaker)
#
# The conversation data is entirely synthetic — the service will render it
# into a PDF and upload it to the specified S3 location.

PAYLOAD=$(cat <<EOF
{
  "pdf_options": {
    "format": "letter",
    "customer_short_name": "test-customer",
    "type": "document",
    "customer_description": "Test Customer",
    "provider": "TEST",
    "source_language": "es",
    "source_file": "test-document.pdf"
  },
  "upload_options": {
    "bucket": "$BUCKET",
    "key": "$KEY"
  },
  "conversation": {
    "id": "00000000-0000-0000-0000-000000000001",
    "type": "document",
    "start_at": "2026-04-09T12:00:00Z",
    "phrases": [
      {
        "id": 1,
        "index": 0,
        "source": "resident",
        "body": "Esta es una frase de prueba traducida.",
        "start_at": "2026-04-09T12:00:00Z",
        "translation_id": "00000000-0000-0000-0000-000000000002"
      },
      {
        "id": 2,
        "index": 1,
        "source": "receiver",
        "body": "This is a test response phrase.",
        "start_at": "2026-04-09T12:00:01Z",
        "translation_id": "00000000-0000-0000-0000-000000000002"
      },
      {
        "id": 3,
        "index": 2,
        "source": "resident",
        "body": "El documento fue recibido el martes pasado.",
        "start_at": "2026-04-09T12:00:05Z",
        "translation_id": "00000000-0000-0000-0000-000000000002"
      },
      {
        "id": 4,
        "index": 3,
        "source": "receiver",
        "body": "Can you confirm the reference number listed on page three?",
        "start_at": "2026-04-09T12:00:08Z",
        "translation_id": "00000000-0000-0000-0000-000000000002"
      },
      {
        "id": 5,
        "index": 4,
        "source": "resident",
        "body": "Si, el numero de referencia es 4421-B. Tambien necesito una copia del formulario original.",
        "start_at": "2026-04-09T12:00:12Z",
        "translation_id": "00000000-0000-0000-0000-000000000002"
      },
      {
        "id": 6,
        "index": 5,
        "source": "receiver",
        "body": "Understood. I will send the original form along with the updated attachment.",
        "start_at": "2026-04-09T12:00:15Z",
        "translation_id": "00000000-0000-0000-0000-000000000002"
      },
      {
        "id": 7,
        "index": 6,
        "source": "resident",
        "body": "Perfecto, muchas gracias por la ayuda.",
        "start_at": "2026-04-09T12:00:20Z",
        "translation_id": "00000000-0000-0000-0000-000000000002"
      }
    ]
  }
}
EOF
)

# Base64-encode the payload so it can be safely passed into the pod as an
# environment variable without shell quoting issues (nested JSON + shell = pain).
PAYLOAD_B64=$(echo -n "$PAYLOAD" | base64)

# ---- Build the inner script that runs inside the temporary pod ----
#
# This is a small shell script that the pod executes on startup. It:
#   1. Decodes the base64 payload back into JSON
#   2. Sends it to the service using curl with --aws-sigv4 for SigV4 signing
#   3. Prints the HTTP status code and response body
#
# The single-quoted heredoc ('INNERSCRIPT') prevents any variable expansion
# here — the variables are resolved at runtime inside the pod from env vars.

SCRIPT=$(cat <<'INNERSCRIPT'
#!/bin/sh
exec 2>&1
echo "$PAYLOAD_B64" | base64 -d > /tmp/payload.json

echo "Sending request..."
echo ""

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
  --aws-sigv4 "aws:amz:$SIGV4_REGION:$SIGV4_SERVICE" \
  --user "$SIGV4_ACCESS_KEY:$SIGV4_SECRET_KEY" \
  -H "Content-Type: application/json" \
  -d @/tmp/payload.json \
  "$SERVICE_URL")

HTTP_STATUS=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

echo "HTTP Status: $HTTP_STATUS"
echo "Response:"
echo "$BODY"
INNERSCRIPT
)

# Base64-encode the inner script as well, for the same quoting reasons.
SCRIPT_B64=$(echo "$SCRIPT" | base64)

# ---- Launch the temporary pod ----
#
# We use `kubectl run` with --overrides to customize the pod spec:
#   - serviceAccountName: uses the verus-report-renderer service account so
#     the pod gets IRSA credentials (needed by the service for S3 uploads)
#   - The entrypoint decodes and runs the base64-encoded inner script
#   - All config (credentials, payload, URLs) is passed via environment
#     variables to avoid shell escaping nightmares
#   - --restart=Never makes this a one-shot pod that exits when the script ends
#
# Any leftover pod from a previous run is cleaned up first.

kubectl delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found > /dev/null 2>&1

echo "Spinning up temporary pod..."
echo ""

kubectl run "$POD_NAME" --restart=Never \
  -n "$NAMESPACE" \
  --overrides="{
    \"spec\": {
      \"serviceAccountName\": \"$NAMESPACE\",
      \"containers\": [{
        \"name\": \"$POD_NAME\",
        \"image\": \"$POD_IMAGE\",
        \"command\": [\"sh\", \"-c\", \"echo \$SCRIPT_B64 | base64 -d > /tmp/run.sh && sh /tmp/run.sh\"],
        \"env\": [
          {\"name\": \"SCRIPT_B64\",       \"value\": \"$SCRIPT_B64\"},
          {\"name\": \"PAYLOAD_B64\",      \"value\": \"$PAYLOAD_B64\"},
          {\"name\": \"SIGV4_ACCESS_KEY\", \"value\": \"$SIGV4_ACCESS_KEY\"},
          {\"name\": \"SIGV4_SECRET_KEY\", \"value\": \"$SIGV4_SECRET_KEY\"},
          {\"name\": \"SIGV4_REGION\",     \"value\": \"$SIGV4_REGION\"},
          {\"name\": \"SIGV4_SERVICE\",    \"value\": \"$SIGV4_SERVICE\"},
          {\"name\": \"SERVICE_URL\",      \"value\": \"$SERVICE_URL\"}
        ]
      }]
    }
  }" \
  --image="$POD_IMAGE" > /dev/null 2>&1

# ---- Wait for the pod to finish and collect results ----
#
# The pod will either succeed (exit 0) or fail (non-zero exit). We wait for
# either outcome with a 120-second timeout, then grab the logs regardless.

kubectl wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$POD_NAME" \
  -n "$NAMESPACE" --timeout=120s > /dev/null 2>&1 || \
kubectl wait --for=jsonpath='{.status.phase}'=Failed "pod/$POD_NAME" \
  -n "$NAMESPACE" --timeout=120s > /dev/null 2>&1 || true

echo "=== Results ==="
echo ""
kubectl logs "$POD_NAME" -n "$NAMESPACE" 2>&1
echo ""

# ---- Clean up ----
#
# Delete the temporary pod so we don't leave clutter in the namespace.

kubectl delete pod "$POD_NAME" -n "$NAMESPACE" --ignore-not-found > /dev/null 2>&1
echo "Temporary pod cleaned up."
