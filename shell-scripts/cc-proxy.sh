#!/usr/bin/env bash
#
# cc-proxy.sh — reach a tenant's Verus Control Center (/control-center) through
# a kubectl port-forward, bypassing the edge routing that (by design) never
# exposes it to end users. An Origin-rewriting nginx container fronts the
# tunnel so LiveView websockets survive production's `check_origin: true`.
#
# Background: verus_server always mounts /control-center in its router; the
# nginx/ingress rules simply route no traffic to it in staging/production. That
# omission is defense-in-depth — the page also has its own login (LoginLive +
# LiveAuth) — so tunneling to the pod does not bypass authentication, only the
# edge routing.
#
# Why the local nginx: a bare port-forward works against staging (check_origin
# is false there) but on production the LiveView websocket is rejected — the
# browser sends `Origin: http://localhost:<port>` and Phoenix validates the
# origin against its configured url host. Rather than editing /etc/hosts (which
# can't fix the port/scheme in the browser's Origin anyway), this script puts a
# tiny local nginx between your browser and the kubectl port-forward and
# REWRITES the Origin/Host headers to exactly what the server expects.
#
# What the server expects: runtime.exs sets `url: [host: HOSTNAME, port: PORT]`.
# On Kubernetes, HOSTNAME defaults to the POD NAME unless the Deployment
# overrides it — so the expected origin is discovered live from the pod env at
# startup (no hardcoded domains, no per-environment mapping needed).
#
#     ┌───────────────────┐
#     │ Browser           │   http://<namespace>.localhost:LOCAL_PORT/control-center
#     └─────────┬─────────┘
#     ┌─────────┴─────────┐
#     │ nginx (docker)    │   rewrites Origin/Host → pod's HOSTNAME:PORT,
#     │ 127.0.0.1:LOCAL   │   passes websocket Upgrade/Connection through
#     └─────────┬─────────┘
#               │  host.docker.internal:PF_PORT
#     ┌─────────┴─────────┐
#     │ kubectl           │
#     │ port-forward      │   k8s API stream (TLS)
#     └─────────┬─────────┘
#     ┌─────────┴─────────┐
#     │ verus-server pod  │   /control-center login gate still applies
#     └───────────────────┘
#
#   ./cc-proxy.sh <tenant-namespace> [local-port]
#
# Ctrl-C tears down both the nginx container and the port-forward.
#
# The environment (staging vs production) is detected from the current kubectl
# context ARN — used only for the loud production confirmation prompt; the
# spoofed origin itself always comes from the pod env, which works on any
# cluster.
#
# The browser is pointed at http://<namespace>.localhost:<port> (Chrome
# resolves *.localhost to loopback by itself) so each tenant gets its own
# cookie jar — cookies are host-scoped and ignore ports, so plain localhost
# would replay one tenant's session cookie against another, producing an
# infinite login redirect loop. Chrome incognito is used on top as
# defense-in-depth.
#
# Credentials resolve PER ENVIRONMENT (staging and prod have separate auth
# backends, so their passwords differ). The environment comes from the cluster
# context: the prod cluster ARN → PROD, anything else → STAGING.
#
#   email:    --email  >  CC_LOGIN_EMAIL_<ENV>  >  CC_LOGIN_EMAIL     (required)
#   password: CC_LOGIN_PASSWORD_<ENV>  >  CC_LOGIN_PASSWORD  >
#             macOS keychain (service verus-cc-staging / verus-cc-prod,
#             account = the resolved email)                           (optional)
#
# The keychain fallback is the recommended home for passwords — nothing
# sensitive has to live in your shell env or .zshrc. One-time setup:
#   security add-generic-password -s verus-cc-staging -a <email> -w
#   security add-generic-password -s verus-cc-prod    -a <email> -w
#
# Env overrides:
#   CC_LOGIN_EMAIL[_STAGING|_PROD]     login email; pre-flight + form prefill
#   CC_LOGIN_PASSWORD[_STAGING|_PROD]  password for the login-form prefill
#                                      (never leaves your laptop except inside
#                                      the login POST itself)
#   CC_NO_OPEN=1                       Don't launch the browser, just print URL
#   CC_NGINX_IMAGE                     nginx image (default: nginx:1.27-alpine)
set -euo pipefail

usage() {
  cat >&2 <<USAGE
cc-proxy.sh — open a tenant's Verus Control Center through a kubectl
port-forward, with a local Origin-rewriting nginx so the control center's
LiveView websockets work through production's check_origin.

usage: $0 <tenant-namespace> [local-port] --email <login-email>

  <tenant-namespace>  EKS namespace of the tenant (e.g. prod-ca)
  [local-port]        local port your browser connects to (default: 4000);
                      the internal port-forward uses local-port + 1
  --email <email>     the login you'll use on the control center; checked
                      against the tenant's application registrations before
                      the browser opens (an unregistered login produces an
                      infinite redirect loop). May also come from
                      CC_LOGIN_EMAIL_STAGING / CC_LOGIN_EMAIL_PROD (picked by
                      cluster context) or CC_LOGIN_EMAIL; the flag wins over
                      all. One of them is REQUIRED. The password prefill
                      resolves similarly: CC_LOGIN_PASSWORD[_STAGING|_PROD],
                      then the macOS keychain (service verus-cc-staging /
                      verus-cc-prod) — see the script header.

See the comment block at the top of this script for the connection diagram.
USAGE
}

NS=""
LOCAL_PORT=""
EMAIL_FLAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --email)   EMAIL_FLAG="${2:-}"; shift 2 ;;
    --email=*) EMAIL_FLAG="${1#--email=}"; shift ;;
    -*)        echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *)
      if [ -z "$NS" ]; then NS="$1"
      elif [ -z "$LOCAL_PORT" ]; then LOCAL_PORT="$1"
      else echo "Unexpected argument: $1" >&2; usage; exit 1
      fi
      shift ;;
  esac
done

LOCAL_PORT="${LOCAL_PORT:-4000}"
PF_PORT=$((LOCAL_PORT + 1))
NGINX_IMAGE="${CC_NGINX_IMAGE:-nginx:1.27-alpine}"
CONTAINER="cc-proxy-${USER:-dev}"

if [ -z "$NS" ]; then
  usage
  exit 1
fi


command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
command -v jq      >/dev/null || { echo "jq not found (needed for pod/port discovery)" >&2; exit 1; }
command -v docker  >/dev/null || { echo "docker not found (needed for the Origin-rewriting nginx)" >&2; exit 1; }
docker info >/dev/null 2>&1   || { echo "docker daemon not running" >&2; exit 1; }

CTX="$(kubectl config current-context 2>/dev/null || echo '?')"

# --- resolve credentials per environment --------------------------------------
# Staging and production have separate auth backends, so their credentials
# differ. The environment is derived from the cluster context (prod cluster
# ARN → PROD, anything else → STAGING), and credentials resolve as:
#   email:    --email  >  CC_LOGIN_EMAIL_<ENV>  >  CC_LOGIN_EMAIL      (required)
#   password: CC_LOGIN_PASSWORD_<ENV>  >  CC_LOGIN_PASSWORD  >
#             macOS keychain item (service verus-cc-<env>, account = email)
#                                                                      (optional)
# The keychain fallback means nothing sensitive needs to live in your shell
# env at all. Store the items once with:
#   security add-generic-password -s verus-cc-staging -a <email> -w
#   security add-generic-password -s verus-cc-prod    -a <email> -w
PROD_CTX="arn:aws:eks:us-east-1:126427819807:cluster/verus"
if [ "$CTX" = "$PROD_CTX" ]; then
  CC_ENV="prod"; ENV_SUFFIX="PROD"
else
  CC_ENV="staging"; ENV_SUFFIX="STAGING"
fi

env_lookup() { eval "printf %s \"\${$1:-}\""; }

LOGIN_EMAIL="${EMAIL_FLAG:-$(env_lookup "CC_LOGIN_EMAIL_${ENV_SUFFIX}")}"
LOGIN_EMAIL="${LOGIN_EMAIL:-${CC_LOGIN_EMAIL:-}}"

if [ -z "$LOGIN_EMAIL" ]; then
  echo "Missing login email: pass --email <login-email> or set CC_LOGIN_EMAIL (or CC_LOGIN_EMAIL_${ENV_SUFFIX})." >&2
  echo >&2
  usage
  exit 1
fi

# Sanitized before interpolation into Elixir source (defense in depth; it's
# our own email but the rpc string must never become an injection point).
LOGIN_EMAIL="$(printf %s "$LOGIN_EMAIL" | tr -cd 'A-Za-z0-9@._+-')"

LOGIN_PASSWORD="$(env_lookup "CC_LOGIN_PASSWORD_${ENV_SUFFIX}")"
LOGIN_PASSWORD="${LOGIN_PASSWORD:-${CC_LOGIN_PASSWORD:-}}"
if [ -z "$LOGIN_PASSWORD" ] && command -v security >/dev/null; then
  LOGIN_PASSWORD="$(security find-generic-password -s "verus-cc-${CC_ENV}" -a "$LOGIN_EMAIL" -w 2>/dev/null || true)"
fi
if [ -n "$LOGIN_PASSWORD" ]; then
  PASSWORD_SRC="prefilled"
else
  PASSWORD_SRC="not prefilled (no CC_LOGIN_PASSWORD[_${ENV_SUFFIX}] and no keychain item verus-cc-${CC_ENV})"
fi
echo "environment=$CC_ENV  login=$LOGIN_EMAIL  password: $PASSWORD_SRC"

if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  echo "Namespace '$NS' not found on cluster '$CTX'." >&2
  echo "Check the name and that you're on the intended context (kubectl config get-contexts)." >&2
  exit 1
fi

# --- guard rail: warn loudly when this is the production cluster --------------
# (PROD_CTX / CC_ENV were resolved in the credentials block above.)
if [ "$CTX" = "$PROD_CTX" ]; then
  echo >&2
  echo "  ⚠  You're about to open the '$NS' PRODUCTION control center." >&2
  echo "     Release tasks launched there run against real production data." >&2
  echo >&2
  printf 'Are you sure you'\''d like to proceed? y/n ' >&2
  read -r reply </dev/tty
  case "$reply" in
    y|Y|yes|YES) ;;
    *) echo "Aborted." >&2; exit 1 ;;
  esac
fi

# --- find a running verus-server pod and its HTTP port ------------------------
POD_JSON="$(kubectl -n "$NS" get pods -o json)"

read -r POD REMOTE_PORT < <(printf %s "$POD_JSON" | jq -r '
  [ .items[]
    | select(.status.phase == "Running")
    | select(.metadata.name | test("verus-server"))
    | select(.metadata.name | test("backfill|-cg-") | not)
    | { name: .metadata.name,
        port: (.spec.containers[] | .env[]? | select(.name == "PORT") | .value) }
    | select(.port != null) ]
  | (.[0] // empty)
  | "\(.name) \(.port)"')

if [ -z "${POD:-}" ] || [ -z "${REMOTE_PORT:-}" ]; then
  echo "No running verus-server pod with a PORT env var found in '$NS'." >&2
  echo "Pods present:" >&2
  kubectl -n "$NS" get pods >&2
  exit 1
fi

# --- discover the origin the server actually validates against ----------------
# runtime.exs: url host = HOSTNAME env. On k8s that is the pod name unless the
# Deployment sets it explicitly, so read it from the live pod rather than
# guessing. Fall back to the pod name (the k8s default) if exec fails.
SPOOF_HOST="$(kubectl -n "$NS" exec "$POD" -- printenv HOSTNAME 2>/dev/null | tr -d '\r' || true)"
SPOOF_HOST="${SPOOF_HOST:-$POD}"

# Include the port and use plain http: Phoenix's check_origin compares the
# parts present in its url config, and runtime.exs configures host AND port
# (no https), so http://HOST:PORT satisfies the strictest reading while a
# host-only comparison ignores the extras.
SPOOF_ORIGIN="http://${SPOOF_HOST}:${REMOTE_PORT}"

echo "cluster=$CTX  namespace=$NS  pod=$POD  remote-port=$REMOTE_PORT"
echo "local-port=$LOCAL_PORT (browser)  pf-port=$PF_PORT (internal)  spoofed origin=$SPOOF_ORIGIN"

# --- pre-flight: is this user registered to the tenant's application? ----------
# The auth provider happily AUTHENTICATES a user with no registration for the
# tenant's application; the control center then bounces them in an infinite
# /control-center <-> /login redirect loop (LoginLive checks only exp,
# LiveAuth requires an active registration). Catch that here with a clear
# message instead.
#
# The lookup runs through the app's own release console (`verus_server rpc`)
# on the pod, calling the SAME Accounts.get_user seam LiveAuth uses — so the
# verdict cannot drift from what the control center will decide, and it
# automatically follows the auth-provider abstraction (verus auth server
# today, Cognito etc. tomorrow) instead of hard-coding any provider's API.
RPC_CODE="$(cat <<ELIXIR
app_id = VerusServer.Utilities.RuntimeConfigs.application_id()
verdict =
  case VerusServer.Accounts.get_user(username: "${LOGIN_EMAIL}") do
    {:ok, user} ->
      regs = Map.get(user, :registrations) || []
      if Enum.any?(regs, &(Map.get(&1, :application_id) == app_id)),
        do: "REGISTERED",
        else: "NOT_REGISTERED"
    {:error, _} ->
      "USER_NOT_FOUND"
  end
IO.puts("CC_PREFLIGHT=" <> verdict)
ELIXIR
)"

VERDICT="$(kubectl -n "$NS" exec "$POD" -- /opt/bin/verus_server rpc "$RPC_CODE" 2>/dev/null \
  | grep -o 'CC_PREFLIGHT=[A-Z_]*' | head -1 | cut -d= -f2 || true)"

case "${VERDICT:-}" in
  REGISTERED)
    echo "registration pre-flight: '$LOGIN_EMAIL' is registered to this tenant's application ✔"
    ;;
  NOT_REGISTERED|USER_NOT_FOUND)
    echo >&2
    if [ "$VERDICT" = "USER_NOT_FOUND" ]; then
      echo "⚠  No user '$LOGIN_EMAIL' exists in tenant '$NS' — logging in will fail. (Checking the wrong account? Pass --email with the login you'll use.)" >&2
    else
      echo "⚠  '$LOGIN_EMAIL' exists in tenant '$NS' but has no registration for its application — logging in will loop forever (ERR_TOO_MANY_REDIRECTS). Add the registration in the auth admin first, or pass --email with the login you'll use." >&2
    fi
    echo >&2
    exit 1
    ;;
  *)
    echo "  ℹ  Registration pre-flight inconclusive (rpc lookup failed) — continuing anyway." >&2
    ;;
esac

# --- bail early if either local port is taken ----------------------------------
for p in "$LOCAL_PORT" "$PF_PORT"; do
  if nc -z localhost "$p" 2>/dev/null; then
    echo "Local port $p is already in use — pass a different [local-port]." >&2
    exit 1
  fi
done

PF_PID=""
NGINX_DIR=""
cleanup() {
  trap - EXIT INT TERM HUP
  echo
  echo "Tearing down..."
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
  [ -n "$NGINX_DIR" ] && rm -rf "$NGINX_DIR" || true
}
trap cleanup EXIT INT TERM HUP

# --- port-forward (internal leg) -----------------------------------------------
kubectl -n "$NS" port-forward "pod/$POD" "${PF_PORT}:${REMOTE_PORT}" >/tmp/cc-proxy-pf.log 2>&1 &
PF_PID=$!

for _ in $(seq 1 40); do
  nc -z localhost "$PF_PORT" 2>/dev/null && break
  sleep 0.25
done
if ! nc -z localhost "$PF_PORT" 2>/dev/null; then
  echo "port-forward did not come up; see /tmp/cc-proxy-pf.log" >&2
  exit 1
fi

# --- Origin-rewriting nginx (browser-facing leg) --------------------------------
# host.docker.internal reaches the macOS host from inside the container, where
# the kubectl port-forward listens. The map{} keeps websocket upgrades working
# for plain HTTP requests too (Connection: close when no Upgrade header).
NGINX_DIR="$(mktemp -d /tmp/cc-proxy.XXXXXX)"

# Login-form prefill: nginx injects a small script into the login page (and
# ONLY that page) that fills the email — and the password too when
# CC_LOGIN_PASSWORD is set. Values travel base64-encoded so no character in
# them can break out of the nginx config or the JS string. The values only
# ever exist in your shell env, this mode-700 temp config, and the login page
# DOM served over loopback — the password goes to the server only inside the
# same login POST it would ride in anyway. The filler re-applies for ~2.5s
# (LiveView's websocket connect re-renders the form once) and never overwrites
# a field you've already typed in.
EMAIL_B64="$(printf %s "$LOGIN_EMAIL" | base64)"
PASS_B64=""
[ -n "$LOGIN_PASSWORD" ] && PASS_B64="$(printf %s "$LOGIN_PASSWORD" | base64)"

PREFILL_JS="<script>(function(){var e=atob(\"${EMAIL_B64}\"),p=\"${PASS_B64}\"?atob(\"${PASS_B64}\"):\"\",n=0,t=setInterval(function(){var u=document.getElementById(\"login_id\"),w=document.getElementById(\"password\");if(u&&!u.value){u.value=e}if(w&&p&&!w.value){w.value=p}if(++n>10){clearInterval(t)}},250)})()</script>"

cat > "$NGINX_DIR/nginx.conf" <<CFG
events {}
http {
  map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
  }
  server {
    listen 80;
    location / {
      proxy_pass http://host.docker.internal:${PF_PORT};
      proxy_http_version 1.1;
      proxy_set_header Host       ${SPOOF_HOST}:${REMOTE_PORT};
      proxy_set_header Origin     ${SPOOF_ORIGIN};
      proxy_set_header Upgrade    \$http_upgrade;
      proxy_set_header Connection \$connection_upgrade;
      proxy_read_timeout  3600s;
      proxy_send_timeout  3600s;
    }
    location = /control-center/login {
      proxy_pass http://host.docker.internal:${PF_PORT};
      proxy_http_version 1.1;
      proxy_set_header Host       ${SPOOF_HOST}:${REMOTE_PORT};
      proxy_set_header Origin     ${SPOOF_ORIGIN};
      # sub_filter can't see inside gzip — ask the upstream for identity.
      proxy_set_header Accept-Encoding "";
      sub_filter '</body>' '${PREFILL_JS}</body>';
      sub_filter_once on;
    }
  }
}
CFG
chmod 600 "$NGINX_DIR/nginx.conf"

docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --rm --name "$CONTAINER" \
  -p "127.0.0.1:${LOCAL_PORT}:80" \
  -v "$NGINX_DIR/nginx.conf:/etc/nginx/nginx.conf:ro" \
  "$NGINX_IMAGE" >/dev/null

for _ in $(seq 1 40); do
  nc -z localhost "$LOCAL_PORT" 2>/dev/null && break
  sleep 0.25
done
if ! nc -z localhost "$LOCAL_PORT" 2>/dev/null; then
  echo "nginx did not come up; docker logs $CONTAINER:" >&2
  docker logs "$CONTAINER" >&2 || true
  exit 1
fi

# Browse via a PER-TENANT hostname, not plain localhost. Browsers scope
# cookies by host (NOT port), so two tenants visited at localhost — even on
# different ports, even both in incognito — replay each other's session
# cookie, and the control center answers a foreign session with an infinite
# /control-center <-> /login redirect loop. Chrome resolves any *.localhost
# name to loopback on its own (no /etc/hosts entry needed), and our nginx
# rewrites Host/Origin regardless of the inbound hostname, so
# <namespace>.localhost gives every tenant an isolated cookie jar for free.
URL="http://${NS}.localhost:${LOCAL_PORT}/control-center"

# Still open in incognito as defense-in-depth (fresh jar per session, and
# nothing from these tunnels lingers in the regular profile). `open -na ...
# --args` applies the flag even when Chrome is already running.
if [ "${CC_NO_OPEN:-}" = "1" ]; then
  echo "Tunnel up. Control center: $URL"
elif open -Ra "Google Chrome" 2>/dev/null; then
  open -na "Google Chrome" --args --incognito "$URL"
  echo "Opened Chrome (incognito) at $URL"
else
  echo "Google Chrome not found — opening default browser (clear localhost cookies if you hit a redirect loop)."
  open "$URL" 2>/dev/null || echo "Tunnel up. Control center: $URL"
fi

echo "Ctrl-C to tear down (nginx container + port-forward)."
wait "$PF_PID"
