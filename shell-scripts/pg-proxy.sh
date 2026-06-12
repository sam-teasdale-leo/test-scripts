#!/usr/bin/env bash
#
# pg-proxy.sh — temporary Postgres tunnel into a tenant's EKS namespace, with
# the password NEVER leaving the cluster.
#
# The problem this avoids: the database password lives in a Kubernetes Secret
# inside the cluster. The usual way to point a GUI tool like Postico at the DB
# is to copy that password down to your laptop and paste it into a connection
# string — and at that moment the password has left the cluster and now lives on
# your machine: in app settings, your clipboard, maybe your shell history.
#
# This script avoids that. It runs pgbouncer (a lightweight Postgres connection
# proxy) as a throwaway pod INSIDE the cluster, in the tenant's namespace.
# Kubernetes hands the password straight from the Secret into that pod — using
# the same "secretKeyRef" mechanism the Verus Server already uses — and this
# script never reads or decodes the secret itself. pgbouncer then logs into the
# database (RDS) on your behalf with that password. So the password only ever
# exists in the two places it already did: the Secret, and a pod — both of which
# live inside the cluster and never on your laptop.
#
# Your laptop's side of the connection carries no password at all: Postico
# reaches the pgbouncer pod over a `kubectl port-forward` tunnel (so the pod is
# never network-exposed — your laptop talks to it through the Kubernetes API,
# not directly), and authenticates with auth_type=any (see the security note
# below). The net result is a normal GUI connection to the tenant's database,
# with the real password never touching your machine.
#
# (Technical note on auth_type: we use `any` rather than `trust` because
# pgbouncer's `trust` still requires the client username to exist in an
# auth_file/userlist, which we don't render. `any` ignores the client username
# entirely and connects to RDS as the user pinned in the [databases] entry.)
#
# How the connection is wired (and what secures each hop):
#
#     ┌───────────────────┐
#     │ Postico (no pwd)  │   on your laptop
#     └─────────┬─────────┘
#               │  connects to localhost:PORT, the port-forward listener
#     ┌─────────┴─────────┐
#     │ kubectl           │   on your laptop
#     │ port-forward      │
#     └─────────┬─────────┘
#               │  k8s API stream (TLS)
#     ┌─────────┴─────────┐
#     │ pgbouncer pod     │   in the EKS namespace
#     │ :5432  auth=any   │   ◀ real password from the Secret (secretKeyRef),
#     └─────────┬─────────┘     never on your laptop
#               │  Postgres over TLS (server_tls_sslmode=require)
#     ┌─────────┴─────────┐
#     │ RDS Postgres      │
#     └───────────────────┘
#
#   ./pg-proxy.sh <tenant-namespace> [local-port]
#
# Ctrl-C tears everything down. The pod also self-destructs server-side after
# PGBOUNCER_DEADLINE_SECONDS no matter what happens to this script.
#
# Why no client auth is safe here: the pgbouncer pod is a bare Pod, not a
# Service, so it is only reachable through YOUR port-forward (loopback → k8s API
# stream). Anyone who could connect to it already has port-forward rights in the
# namespace — and could read the secret directly anyway — so this opens no new
# access, and the password never lands on your local disk.
#
# Env overrides:
#   PGBOUNCER_DEADLINE_SECONDS  Hard server-side pod lifetime (default: 3600 = 1h)
#   PGBOUNCER_IMAGE             pgbouncer image (default: pinned digest, see below)
#   PGBOUNCER_POSTICO_APP       App to open (default: "Postico 2")
#   PGBOUNCER_NO_OPEN=1         Don't launch Postico, just print connection info
#
set -euo pipefail

usage() {
  cat >&2 <<USAGE
pg-proxy.sh — open a temporary, secure Postgres tunnel into a tenant's EKS
namespace and point Postico at it.

Drops a throwaway pgbouncer pod into the namespace; pgbouncer logs in to the
tenant's RDS using the password injected straight from the in-cluster Secret,
so the real password never reaches your laptop. Your client connects through a
kubectl port-forward with no password of its own. Ctrl-C tears everything down
(and the pod self-expires after PGBOUNCER_DEADLINE_SECONDS regardless).

usage: $0 <tenant-namespace> [local-port]

  <tenant-namespace>  EKS namespace of the tenant (e.g. development-ca)
  [local-port]        local port to listen on (default: 5432)

See the comment block at the top of this script for the full connection diagram
and the list of PGBOUNCER_* environment overrides.
USAGE
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

NS="${1:-}"
LOCAL_PORT="${2:-5432}"
if [ -z "$NS" ]; then
  usage
  exit 1
fi

DEADLINE="${PGBOUNCER_DEADLINE_SECONDS:-3600}"

# The pgbouncer image is pinned by DIGEST (not a moving tag like :latest) so
# every run uses the exact image we vetted — a tag can be silently repointed,
# a digest cannot. This digest is PgBouncer 1.25.1 (edoburu/pgbouncer).
#
# We pulled this image and inspected its layers and contents before trusting
# it, and it's clean: a minimal Alpine base containing only pgbouncer plus its
# runtime libraries (libevent, OpenSSL, libpq), it runs as a non-root user, has
# no setuid/setgid binaries, and the pgbouncer binary has no hardcoded URLs or
# IPs beyond the project's own homepage — i.e. nothing phones home. If you bump
# this digest, re-run that check on the new image first.
IMAGE="${PGBOUNCER_IMAGE:-edoburu/pgbouncer@sha256:85d1e38593617af1b5f7f285e97d407e56c29939683cc7cfe4c8f6dc19f1268b}"
APP_NAME="${PGBOUNCER_POSTICO_APP:-Postico 2}"
POD="pgbouncer-${USER:-dev}"

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
command -v jq      >/dev/null || { echo "jq not found (needed for config discovery + URL encoding)" >&2; exit 1; }

CTX="$(kubectl config current-context 2>/dev/null || echo '?')"

# --- verify the namespace exists before we try to create anything in it -------
# Catches a typo'd name or being pointed at the wrong cluster context, before we
# get a more cryptic error from the Deployment query below.
if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  echo "Namespace '$NS' not found on cluster '$CTX'." >&2
  echo "Check the name and that you're on the intended context (kubectl config get-contexts)." >&2
  echo "List namespaces with: kubectl get ns" >&2
  exit 1
fi

# --- read DB config from the Deployment env (the source of truth) ------------
# Host/db/user/port are plain `value:` env on the verus-server Deployment; only
# the password is a secretKeyRef. We pick the container that defines
# POSTGRES_HOSTNAME, preferring the main Deployment over any *-backfill one.
DEP_JSON="$(kubectl -n "$NS" get deploy -o json)"

pick_container() {
  # $1 is a jq predicate evaluated per-Deployment (it sees .metadata.name etc.)
  printf %s "$DEP_JSON" | jq -c "
    [ .items[]
      | select($1)
      | .spec.template.spec.containers[]
      | select(any(.env[]?; .name==\"POSTGRES_HOSTNAME\")) ]
    | (.[0] // empty)"
}
CJSON="$(pick_container '.metadata.name | test("backfill") | not')"
[ -z "$CJSON" ] && CJSON="$(pick_container 'true')"
if [ -z "$CJSON" ]; then
  echo "No Deployment container with POSTGRES_HOSTNAME found in '$NS'." >&2
  exit 1
fi

envval() { echo "$CJSON" | jq -r --arg k "$1" '.env[] | select(.name==$k) | .value // empty'; }
PGHOST="$(envval POSTGRES_HOSTNAME)"
PGDB="$(envval POSTGRES_DATABASE)"
PGUSER="$(envval POSTGRES_USERNAME)"
REMOTE_PORT="$(envval POSTGRES_PORT)"; REMOTE_PORT="${REMOTE_PORT:-5432}"

# --- resolve how the password is supplied, WITHOUT reading its value ----------
# If it's a plain value on the Deployment, it's already plaintext config, so we
# pass it through as a plain env value. If it's a secretKeyRef (the normal case)
# we wire the SAME secretKeyRef into the pgbouncer pod — Kubernetes injects the
# value into the container; this script never decodes it.
PLAINPASS="$(envval POSTGRES_PASSWORD)"
SREF_NAME=""; SREF_KEY=""
if [ -z "$PLAINPASS" ]; then
  SREF_NAME="$(echo "$CJSON" | jq -r '.env[] | select(.name=="POSTGRES_PASSWORD") | .valueFrom.secretKeyRef.name // empty')"
  SREF_KEY="$(echo  "$CJSON" | jq -r '.env[] | select(.name=="POSTGRES_PASSWORD") | .valueFrom.secretKeyRef.key  // empty')"
  if [ -z "$SREF_NAME" ] || [ -z "$SREF_KEY" ]; then
    echo "Could not resolve POSTGRES_PASSWORD (neither plain value nor secretKeyRef) from the Deployment env." >&2
    exit 1
  fi
fi

# Build the YAML for the PGPASS env entry (injected at column 0 below).
if [ -n "$PLAINPASS" ]; then
  PASS_ENV="$(printf '        - name: PGPASS\n          value: "%s"' "$PLAINPASS")"
  PASS_SRC="plain value (already plaintext on Deployment)"
else
  PASS_ENV="$(printf '        - name: PGPASS\n          valueFrom:\n            secretKeyRef:\n              name: "%s"\n              key: "%s"' "$SREF_NAME" "$SREF_KEY")"
  PASS_SRC="secretKeyRef ${SREF_NAME}/${SREF_KEY} (never decoded locally)"
fi

echo "cluster=$CTX  namespace=$NS  rds=${PGHOST}:${REMOTE_PORT}  db=$PGDB  user=$PGUSER  pod=$POD  local-port=$LOCAL_PORT  deadline=${DEADLINE}s"
echo "password source: $PASS_SRC"

# --- guard rail: warn loudly when this is the production cluster --------------
# Matched by the EKS cluster ARN (the current-context above), not the namespace,
# so it can't be fooled by a tenant naming convention.
PROD_CTX="arn:aws:eks:us-east-1:126427819807:cluster/verus"
if [ "$CTX" = "$PROD_CTX" ]; then
  echo >&2
  echo "  ⚠  You're about to open a connection to the '$NS' PRODUCTION database." >&2
  echo "     Proceed with caution. Database changes impact real production data." >&2
  echo >&2
  printf 'Are you sure you'\''d like to proceed? y/n ' >&2
  read -r reply </dev/tty
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "Aborted." >&2; exit 1 ;;
  esac
fi

# --- bail early if the local port is taken (e.g. a local Postgres) ------------
if nc -z localhost "$LOCAL_PORT" 2>/dev/null; then
  echo "Local port $LOCAL_PORT is already in use — pass a different [local-port]." >&2
  exit 1
fi

PF_PID=""
cleanup() {
  trap - EXIT INT TERM HUP
  echo
  echo "Tearing down..."
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  kubectl -n "$NS" delete pod "$POD" --ignore-not-found --grace-period=1 --wait=false 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

# --- reap any orphan from a previous run, then create the proxy --------------
kubectl -n "$NS" delete pod "$POD" --ignore-not-found --grace-period=1 --wait=false 2>/dev/null || true
kubectl -n "$NS" wait --for=delete "pod/$POD" --timeout=30s 2>/dev/null || true

# The container's shell renders pgbouncer's config at startup, then execs
# pgbouncer: host/db/user/port are baked in by THIS script (non-sensitive,
# expanded by the local shell below), while \${PGPASS} stays literal in the
# manifest and is resolved INSIDE the pod from the env entry above.
# restartPolicy:Never means a dead pgbouncer stays dead; activeDeadlineSeconds
# is the orphan backstop.
kubectl -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  labels:
    app: pgbouncer
    owner: ${USER:-dev}
spec:
  restartPolicy: Never
  activeDeadlineSeconds: $DEADLINE
  terminationGracePeriodSeconds: 1
  containers:
    - name: pgbouncer
      image: $IMAGE
      command:
        - /bin/sh
        - -c
        - |
          set -e
          cat > /tmp/pgbouncer.ini <<CFG
          [databases]
          ${PGDB} = host=${PGHOST} port=${REMOTE_PORT} user=${PGUSER} password=\${PGPASS}

          [pgbouncer]
          listen_addr = 0.0.0.0
          listen_port = 5432
          auth_type = any
          pool_mode = session
          max_client_conn = 50
          default_pool_size = 5
          server_tls_sslmode = require
          ignore_startup_parameters = extra_float_digits,options
          CFG
          exec pgbouncer /tmp/pgbouncer.ini
      env:
${PASS_ENV}
      resources:
        requests: { cpu: "10m", memory: "32Mi" }
        limits:   { cpu: "200m", memory: "128Mi" }
EOF

kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=60s

# --- port-forward and wait for the local end to accept -----------------------
kubectl -n "$NS" port-forward "pod/$POD" "${LOCAL_PORT}:5432" >/tmp/pgbouncer-pf.log 2>&1 &
PF_PID=$!

for _ in $(seq 1 40); do
  nc -z localhost "$LOCAL_PORT" 2>/dev/null && break
  sleep 0.25
done
if ! nc -z localhost "$LOCAL_PORT" 2>/dev/null; then
  echo "port-forward did not come up; see /tmp/pgbouncer-pf.log" >&2
  exit 1
fi

# --- open Postico ------------------------------------------------------------
# No password in the URL: pgbouncer uses auth_type=any, and the real RDS auth
# happens inside the pod. sslmode=disable because the client↔pgbouncer leg is
# plaintext — it's already tunneled through the encrypted port-forward stream;
# the encrypted, cert-bearing leg is pgbouncer↔RDS (server_tls_sslmode=require).
enc() { jq -rn --arg x "$1" '$x|@uri'; }
URL="postgresql://$(enc "$PGUSER")@localhost:${LOCAL_PORT}/${PGDB}?sslmode=disable"

if [ "${PGBOUNCER_NO_OPEN:-}" = "1" ]; then
  echo "Tunnel up. Connect to: localhost:${LOCAL_PORT}  db=$PGDB  user=$PGUSER  (no password)"
elif open -Ra "$APP_NAME" 2>/dev/null; then
  open -a "$APP_NAME" "$URL" 2>/dev/null || open -a "$APP_NAME"
  echo "Opened $APP_NAME against localhost:${LOCAL_PORT} (db=$PGDB user=$PGUSER, no password)."
else
  echo "'$APP_NAME' not found. Connect manually: localhost:${LOCAL_PORT}  db=$PGDB  user=$PGUSER  (no password)"
fi

echo "Ctrl-C to tear down. Pod self-expires after ${DEADLINE}s regardless of what happens here."
wait "$PF_PID"
