#!/usr/bin/env bash
#
# Local stand-in for get.goodmem.ai, used by the forward-upgrade release gate.
#
# The CLI's update origin is a compile-time constant with no override flag, so the
# gate answers as that host for the duration of the job: a local CA trusted only on
# the ephemeral runner, a hosts entry, and an HTTPS server on :443.
#
# Only the version in the /fetch response is synthetic. The tarball and bundle
# served are the release's real signed artifacts, so the upgrade still performs
# genuine SLSA verification against the production trust anchors.
#
#   upgrade-origin.sh start <tag> <cli-tarball> <provenance-bundle>
#   upgrade-origin.sh advertise <tag>
#   upgrade-origin.sh stop
set -euo pipefail

HOST=get.goodmem.ai
STATE_DIR="${UPGRADE_ORIGIN_STATE:-/tmp/goodmem-upgrade-origin}"
# Outside STATE_DIR, which start wipes: the only handle on a server left by an
# earlier run, and :443 is not negotiable.
PID_FILE="${UPGRADE_ORIGIN_PIDFILE:-/tmp/goodmem-upgrade-origin.pid}"
CA_INSTALLED=/usr/local/share/ca-certificates/goodmem-release-verify.crt
HOSTS_MARK="# goodmem-release-verify"

kill_running_server() {
  [ -f "$PID_FILE" ] || return 0
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [ -n "$pid" ] || { sudo rm -f "$PID_FILE"; return 0; }
  # Only signal our own server: the pid file sits in a world-writable directory.
  case "$(cat "/proc/$pid/comm" 2>/dev/null)" in
    python3|python) ;;
    *) sudo rm -f "$PID_FILE"; return 0 ;;
  esac
  sudo kill "$pid" 2>/dev/null || true
  # kill returns once the signal is queued; the port stays held until it exits.
  for _ in $(seq 1 40); do
    sudo kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
  sudo kill -0 "$pid" 2>/dev/null && sudo kill -9 "$pid" 2>/dev/null
  sudo rm -f "$PID_FILE"
  return 0
}

cmd_start() {
  local tag="$1" tarball="$2" bundle="$3"
  test -f "$tarball" || { echo "::error::CLI tarball not found: $tarball" >&2; exit 1; }
  test -f "$bundle"  || { echo "::error::provenance bundle not found: $bundle" >&2; exit 1; }

  kill_running_server
  rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR/www/tag/latest"

  # From here on the CA store and /etc/hosts get mutated, so any later failure
  # must undo them rather than leave the runner trusting a private CA. EXIT, not
  # ERR: the readiness probe gives up with an explicit `exit`, which ERR misses.
  trap 'cmd_stop || true' EXIT

  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$STATE_DIR/ca.key" -out "$STATE_DIR/ca.crt" \
    -subj "/CN=goodmem-release-verify-CA" \
    -addext "nameConstraints=critical,permitted;DNS:$HOST" >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes \
    -keyout "$STATE_DIR/srv.key" -out "$STATE_DIR/srv.csr" \
    -subj "/CN=$HOST" >/dev/null 2>&1
  openssl x509 -req -in "$STATE_DIR/srv.csr" -days 1 \
    -CA "$STATE_DIR/ca.crt" -CAkey "$STATE_DIR/ca.key" -CAcreateserial \
    -out "$STATE_DIR/srv.crt" \
    -extfile <(printf "subjectAltName=DNS:%s" "$HOST") >/dev/null 2>&1
  (umask 077; cat "$STATE_DIR/srv.crt" "$STATE_DIR/srv.key" > "$STATE_DIR/srv.pem")

  sudo cp "$STATE_DIR/ca.crt" "$CA_INSTALLED"
  sudo update-ca-certificates >/dev/null 2>&1
  grep -q "$HOSTS_MARK" /etc/hosts \
    || echo "127.0.0.1 $HOST $HOSTS_MARK" | sudo tee -a /etc/hosts >/dev/null

  cp "$tarball" "$STATE_DIR/www/tag/latest/goodmem-linux-amd64.tar.gz"
  cp "$bundle"  "$STATE_DIR/www/tag/latest/goodmem-linux-amd64.tar.gz.build.slsa"
  cmd_advertise "$tag"

  sudo env "STATE_DIR=$STATE_DIR" "PID_FILE=$PID_FILE" python3 - <<'PY' >"$STATE_DIR/server.log" 2>&1 &
import http.server, ssl, os, time
state = os.environ["STATE_DIR"]
os.chdir(os.path.join(state, "www"))
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(os.path.join(state, "srv.pem"))

class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
    def handle_one_request(self):
        # A client closing mid-download is normal here.
        try:
            super().handle_one_request()
        except (ConnectionResetError, BrokenPipeError):
            self.close_connection = True

class Server(http.server.HTTPServer):
    allow_reuse_address = True

httpd = None
for _ in range(40):
    try:
        httpd = Server(("127.0.0.1", 443), Handler)
        break
    except OSError:
        time.sleep(0.25)
if httpd is None:
    raise SystemExit("could not bind 127.0.0.1:443")

httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
with open(os.environ["PID_FILE"], "w") as fh:
    fh.write(str(os.getpid()))
httpd.serve_forever()
PY

  local server_pid=$!
  for _ in $(seq 1 60); do
    if ! kill -0 "$server_pid" 2>/dev/null && [ ! -f "$PID_FILE" ]; then
      break
    fi
    if curl -fsS --connect-timeout 2 --max-time 5 "https://$HOST/tag/latest/fetch" >/dev/null 2>&1; then
      trap - EXIT
      echo "upgrade origin up, advertising $(curl -fsS --max-time 10 "https://$HOST/tag/latest/fetch")"
      return 0
    fi
    sleep 0.5
  done
  echo "::error::local upgrade origin did not come up" >&2
  cat "$STATE_DIR/server.log" >&2 || true
  exit 1
}

cmd_advertise() {
  printf '%s' "$1" > "$STATE_DIR/www/tag/latest/fetch"
  echo "advertising: $1"
}

cmd_stop() {
  set +e
  kill_running_server
  sudo rm -f "$CA_INSTALLED"
  sudo update-ca-certificates >/dev/null 2>&1
  # Not `sed -i`: /etc/hosts is a bind mount in containers and in Kubernetes pods,
  # where the rename sed does fails with EBUSY and silently leaves the entry.
  if grep -q "$HOSTS_MARK" /etc/hosts 2>/dev/null; then
    local tmp; tmp="$(mktemp)"
    grep -v "$HOSTS_MARK" /etc/hosts > "$tmp"
    sudo cp "$tmp" /etc/hosts
    rm -f "$tmp"
  fi
  rm -rf "$STATE_DIR"

  local leaked=""
  [ -f "$CA_INSTALLED" ] && leaked="$leaked trusted-CA"
  grep -q "$HOSTS_MARK" /etc/hosts 2>/dev/null && leaked="$leaked hosts-entry"
  set -e
  if [ -n "$leaked" ]; then
    echo "::error::upgrade origin teardown incomplete, still present:$leaked" >&2
    return 1
  fi
  echo "upgrade origin torn down"
}

case "${1:-}" in
  start)     shift; cmd_start "$@" ;;
  advertise) shift; cmd_advertise "$@" ;;
  stop)      cmd_stop ;;
  *) echo "usage: $0 {start <tag> <tarball> <bundle>|advertise <tag>|stop}" >&2; exit 2 ;;
esac
