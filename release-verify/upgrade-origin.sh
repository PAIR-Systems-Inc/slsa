#!/usr/bin/env bash
#
# A local stand-in for get.goodmem.ai, used by the forward-upgrade release gate.
#
# `goodmem upgrade` discovers releases from a compile-time constant URL
# (UPGRADE_URL = https://get.goodmem.ai/tag/) and there is deliberately no
# override flag or environment variable — an update origin that a caller can
# repoint is a supply-chain footgun. So to ask the freshly built CLI "can you
# upgrade to a version newer than yourself?" before that version exists, we
# answer as get.goodmem.ai for the duration of the job: a local CA trusted only
# on this ephemeral runner, a hosts entry, and a tiny HTTPS server.
#
# What is faked is exactly one thing: the version number in the /fetch response.
# The tarball and provenance bundle served are this release's real, signed
# artifacts, so `goodmem upgrade` performs genuine SLSA verification against the
# production trust anchors. The CLI's own trust decisions are never weakened.
#
# Because the artifacts are the real ones, an upgrade that runs to completion
# installs this release's binary — the post-upgrade binary reports its true
# version, not the advertised one. The gate therefore asserts the upgrade
# decision and the upgrade mechanism, not a post-upgrade version string.
#
# Usage:
#   upgrade-origin.sh start <advertised-tag> <cli-tarball> <provenance-bundle>
#   upgrade-origin.sh advertise <advertised-tag>
#   upgrade-origin.sh stop
set -euo pipefail

HOST=get.goodmem.ai
STATE_DIR="${UPGRADE_ORIGIN_STATE:-/tmp/goodmem-upgrade-origin}"
# Deliberately outside STATE_DIR, which `start` wipes: it is the only handle on
# a server left behind by an earlier run, and :443 is not negotiable (the CLI
# hardcodes https://get.goodmem.ai).
PID_FILE="${UPGRADE_ORIGIN_PIDFILE:-/tmp/goodmem-upgrade-origin.pid}"
CA_INSTALLED=/usr/local/share/ca-certificates/goodmem-release-verify.crt
HOSTS_MARK="# goodmem-release-verify"

# Terminate a server left running by an earlier invocation, and wait for it to
# actually release the port; kill() returns as soon as the signal is queued.
kill_running_server() {
  [ -f "$PID_FILE" ] || return 0
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [ -n "$pid" ] || { sudo rm -f "$PID_FILE"; return 0; }
  sudo kill "$pid" 2>/dev/null || true
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

  # Local CA + leaf for get.goodmem.ai. Trusted only on this runner, removed by
  # `stop`; the runner is ephemeral regardless.
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$STATE_DIR/ca.key" -out "$STATE_DIR/ca.crt" \
    -subj "/CN=goodmem-release-verify-CA" >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes \
    -keyout "$STATE_DIR/srv.key" -out "$STATE_DIR/srv.csr" \
    -subj "/CN=$HOST" >/dev/null 2>&1
  openssl x509 -req -in "$STATE_DIR/srv.csr" -days 1 \
    -CA "$STATE_DIR/ca.crt" -CAkey "$STATE_DIR/ca.key" -CAcreateserial \
    -out "$STATE_DIR/srv.crt" \
    -extfile <(printf "subjectAltName=DNS:%s" "$HOST") >/dev/null 2>&1
  cat "$STATE_DIR/srv.crt" "$STATE_DIR/srv.key" > "$STATE_DIR/srv.pem"

  sudo cp "$STATE_DIR/ca.crt" "$CA_INSTALLED"
  sudo update-ca-certificates >/dev/null 2>&1

  if ! grep -q "$HOSTS_MARK" /etc/hosts; then
    echo "127.0.0.1 $HOST $HOSTS_MARK" | sudo tee -a /etc/hosts >/dev/null
  fi

  # Real signed artifacts, advertised under whatever version `advertise` says.
  cp "$tarball" "$STATE_DIR/www/tag/latest/goodmem-linux-amd64.tar.gz"
  cp "$bundle"  "$STATE_DIR/www/tag/latest/goodmem-linux-amd64.tar.gz.build.slsa"
  cmd_advertise "$tag"

  sudo -E env "STATE_DIR=$STATE_DIR" "PID_FILE=$PID_FILE" python3 - <<'PY' >"$STATE_DIR/server.log" 2>&1 &
import http.server, ssl, os, time
state = os.environ["STATE_DIR"]
os.chdir(os.path.join(state, "www"))
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(os.path.join(state, "srv.pem"))
class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
    # A client that closes mid-download is normal here; don't spam the log.
    def handle_one_request(self):
        try:
            super().handle_one_request()
        except (ConnectionResetError, BrokenPipeError):
            self.close_connection = True
class Server(http.server.HTTPServer):
    # Explicit, and retried below: a previous run's sockets can sit in TIME_WAIT
    # after its server exits, and an unlucky bind would otherwise fail the gate
    # for a reason that has nothing to do with the release.
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

  for _ in $(seq 1 60); do
    if curl -fsS "https://$HOST/tag/latest/fetch" >/dev/null 2>&1; then
      echo "upgrade origin up, advertising $(curl -fsS "https://$HOST/tag/latest/fetch")"
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
  # Teardown is best effort and must run to the end: a half-removed hosts entry
  # or a still-trusted test CA is worse than a noisy log line.
  set +e

  # By recorded pid, never by pattern: a shared runner may have unrelated python
  # processes.
  kill_running_server

  sudo rm -f "$CA_INSTALLED"
  sudo update-ca-certificates --fresh >/dev/null 2>&1

  # NOT `sed -i`: /etc/hosts is a bind mount both in containers and in the
  # Kubernetes pods the arc runners are, and sed -i renames a temp file over the
  # target, which fails there with "Device or resource busy" — leaving the entry
  # in place. Rewrite the existing inode instead.
  if grep -q "$HOSTS_MARK" /etc/hosts 2>/dev/null; then
    local tmp; tmp="$(mktemp)"
    grep -v "$HOSTS_MARK" /etc/hosts > "$tmp"
    sudo cp "$tmp" /etc/hosts
    rm -f "$tmp"
  fi

  rm -rf "$STATE_DIR"
  set -e
  echo "upgrade origin torn down"
}

case "${1:-}" in
  start)     shift; cmd_start "$@" ;;
  advertise) shift; cmd_advertise "$@" ;;
  stop)      cmd_stop ;;
  *) echo "usage: $0 {start <tag> <tarball> <bundle>|advertise <tag>|stop}" >&2; exit 2 ;;
esac
