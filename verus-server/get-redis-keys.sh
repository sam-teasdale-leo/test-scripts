#!/bin/bash

usage() {
  echo "Usage: $(basename "$0") <namespace> [key-prefix]"
  echo ""
  echo "Scan Redis keys in a given Kubernetes namespace. This script reads the"
  echo "REDIS_HOST, REDIS_PORT, REDIS_USERNAME, and REDIS_PASSWORD values from"
  echo "the verus-server-secret in the specified namespace, then spins up a"
  echo "temporary redis-debug pod (redis:7-alpine) that connects to Redis over"
  echo "TLS using redis-cli --scan. The pod is automatically removed when the"
  echo "scan completes. If a key prefix is provided, only keys matching that"
  echo "prefix are returned; otherwise all keys are scanned."
  echo ""
  echo "Arguments:"
  echo "  namespace    Kubernetes namespace (e.g. development-ca, staging-ca)"
  echo "  key-prefix   Optional key prefix to filter by (e.g. user, device, etc)"
  echo ""
  echo "Examples:"
  echo "  $(basename "$0") development-ca"
  echo "  $(basename "$0") development-ca device"
  echo "  $(basename "$0") development-ca lexical_library"
  echo "  $(basename "$0") development-ca lexical_statistics"
  echo "  $(basename "$0") development-ca monitor"
  echo "  $(basename "$0") development-ca phone_station"
  echo "  $(basename "$0") development-ca receiver"
  echo "  $(basename "$0") development-ca resident"
  echo "  $(basename "$0") development-ca revoked_token"
  echo "  $(basename "$0") development-ca site"
  echo "  $(basename "$0") development-ca user"
  exit 1
}

if [ $# -eq 0 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
  usage
fi

if [ $# -gt 2 ]; then
  echo "ERROR: Too many arguments (expected 1-2, got $#)"
  echo ""
  usage
fi

NAMESPACE="$1"
KEY_PREFIX="${2:-}"

if [ -n "$KEY_PREFIX" ]; then
  PATTERN="${KEY_PREFIX}:*"
else
  PATTERN="*"
fi

echo "Reading Redis config from secret verus-server-secret in $NAMESPACE..."

REDIS_HOST=$(kubectl get secret verus-server-secret -n "$NAMESPACE" -o jsonpath='{.data.REDIS_HOST}' | base64 -d)
REDIS_PORT=$(kubectl get secret verus-server-secret -n "$NAMESPACE" -o jsonpath='{.data.REDIS_PORT}' | base64 -d)
REDIS_USERNAME=$(kubectl get secret verus-server-secret -n "$NAMESPACE" -o jsonpath='{.data.REDIS_USERNAME}' | base64 -d)
REDIS_PASSWORD=$(kubectl get secret verus-server-secret -n "$NAMESPACE" -o jsonpath='{.data.REDIS_PASSWORD}' | base64 -d)

if [ -z "$REDIS_HOST" ]; then
  echo "ERROR: Could not read REDIS_HOST from secret. Check that the secret exists:"
  echo "  kubectl get secret verus-server-secret -n $NAMESPACE"
  exit 1
fi

echo "Connecting to Redis at $REDIS_HOST:$REDIS_PORT as $REDIS_USERNAME (TLS enabled)"
echo "Scanning keys matching pattern: $PATTERN"
echo "Spinning up temporary redis pod..."

kubectl run redis-debug --rm -it --restart=Never \
  -n "$NAMESPACE" \
  --image=redis:7-alpine \
  -- redis-cli \
    -h "$REDIS_HOST" \
    -p "$REDIS_PORT" \
    --user "$REDIS_USERNAME" \
    -a "$REDIS_PASSWORD" \
    --tls \
    --scan --pattern "$PATTERN"
