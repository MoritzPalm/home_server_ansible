#!/usr/bin/env bash
# Runs Ollama on a borrowed GPU host as an ephemeral tailnet node, without root.
#
# Ollama binds to localhost only. tailscaled runs in userspace-networking mode,
# which delivers inbound tailnet connections to localhost, so the API is
# reachable from the tailnet and nowhere else. Requests arrive there with the
# tailnet IP as Host, which Ollama's DNS-rebinding check rejects with 403 while
# it listens on loopback; a small proxy on $PORT rewrites Host and forwards to
# Ollama on $OLLAMA_PORT. The node state lives in memory
# and the auth key must be ephemeral: when this script exits the node logs out
# and disappears from the tailnet.
#
# Intended for paperless' initial backlog, not as a permanent service.
#
# Usage, inside tmux or screen so it survives logout:
#   TS_AUTHKEY=tskey-auth-... ./ollama-tailnet.sh
# Ctrl-C stops everything.
#
# Tailnet policy needed (tag owner + the only rule that reaches this node):
#   "tagOwners": { "tag:gpu": ["autogroup:admin"] }
#   { "action": "accept", "src": ["tag:server"], "dst": ["tag:gpu:11434"] }
#
# Everything is downloaded into $BASE and verified
# against the pinned SHA-256. Overriding a version requires overriding its hash.

set -euo pipefail

TAILSCALE_VERSION=${TAILSCALE_VERSION:-1.104.1}
TAILSCALE_SHA256=${TAILSCALE_SHA256:-108d1d96ecf410d305571e173516f27038f870919a9b89c914a167c6d33a4528}
OLLAMA_VERSION=${OLLAMA_VERSION:-v0.40.2}
OLLAMA_SHA256=${OLLAMA_SHA256:-726bee78706c281b0eeef00746efe51a044d71c592c3f0b195820707f31fdf04}

# Chosen from free VRAM below unless set. Both are non-thinking models:
# reasoning output only slows down classification.
MODEL_LARGE=qwen3:30b-a3b-instruct-2507-q4_K_M  # 18.6 GB, wants ~21 GB free
MODEL_SMALL=gemma3:12b                          # 8.2 GB, wants ~10.5 GB free
MODEL=${MODEL:-}
# Matches paperless' default PAPERLESS_AI_LLM_CONTEXT_SIZE.
CONTEXT_LENGTH=${CONTEXT_LENGTH:-8192}
PORT=${PORT:-11434}
OLLAMA_PORT=${OLLAMA_PORT:-11435}
TS_HOSTNAME=${TS_HOSTNAME:-gpu-llm}
TS_TAG=${TS_TAG:-tag:gpu}
# Large: Ollama itself is ~4 GB unpacked, plus the model. Not $HOME, which is
# small on the university host.
BASE=${BASE:-/data_slow/ih26ykel/ollama}
# Free space required in $BASE: extracted Ollama plus the model.
MIN_FREE_GB=${MIN_FREE_GB:-30}

: "${TS_AUTHKEY:?set TS_AUTHKEY to an ephemeral, pre-approved auth key tagged ${TS_TAG}}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "error: $*"; exit 1; }

for cmd in curl tar sha256sum df; do
  command -v "$cmd" >/dev/null || die "$cmd is required"
done
# The GPU may be shared, so the model is sized to what is free right now. A
# model that does not fit is split onto the CPU and runs several times slower.
free_mib=0
if command -v nvidia-smi >/dev/null; then
  nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader >&2
  free_mib=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -n1 | tr -d ' ')
  log "${free_mib} MiB VRAM free on the first GPU"
else
  log "warning: nvidia-smi not found, Ollama will fall back to CPU"
fi
if [[ -z $MODEL ]]; then
  if (( free_mib >= 21000 )); then MODEL=$MODEL_LARGE; else MODEL=$MODEL_SMALL; fi
fi
if [[ $MODEL == "$MODEL_SMALL" ]] && (( free_mib < 10500 )); then
  log "warning: ${MODEL} needs ~10.5 GB VRAM, only ${free_mib} MiB free; part of it will run on the CPU"
fi
log "using ${MODEL}"

mkdir -p "$BASE"
chmod 700 "$BASE"
free_gb=$(( $(df -Pk "$BASE" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
(( free_gb >= MIN_FREE_GB )) || die "${BASE} has ${free_gb} GB free, needs ${MIN_FREE_GB}"

# Downloads $1 to $3 unless a file with checksum $2 is already there.
fetch() {
  local url=$1 sha=$2 dest=$3
  if [[ -f $dest ]] && echo "${sha}  ${dest}" | sha256sum --check --status; then
    return
  fi
  log "downloading ${url}"
  curl --fail --location --silent --show-error --output "${dest}.part" "$url"
  echo "${sha}  ${dest}.part" | sha256sum --check --status \
    || die "checksum mismatch for ${url}"
  mv "${dest}.part" "$dest"
}

# Ollama ships only .tar.zst. Without a zstd binary (and without root to install
# one), Python decompresses it: the standard library can from 3.14, older
# versions get the zstandard package in a venv under $BASE.
# 0.23.0 is the last release that still installs on Python 3.8.
ZSTANDARD_VERSION=${ZSTANDARD_VERSION:-0.23.0}
unzstd_to_stdout() {
  local src=$1 py
  if command -v zstd >/dev/null; then
    zstd -dc "$src"
    return
  fi
  command -v python3 >/dev/null || die "neither zstd nor python3 is available"
  py=python3
  if ! python3 -c 'import compression.zstd' 2>/dev/null; then
    # Checked by import, not by the venv existing: a failed install leaves an
    # empty venv behind.
    if ! "$BASE/zstd-venv/bin/python" -c 'import zstandard' 2>/dev/null; then
      log "no zstd binary, installing zstandard ${ZSTANDARD_VERSION} into ${BASE}/zstd-venv"
      python3 -m venv "$BASE/zstd-venv" || die "python3 -m venv failed (python3-venv missing?)"
      "$BASE/zstd-venv/bin/python" -m pip install --quiet "zstandard==${ZSTANDARD_VERSION}" \
        || die "installing zstandard failed"
    fi
    py="$BASE/zstd-venv/bin/python"
  fi
  "$py" - "$src" <<'PY'
import shutil, sys
try:
    from compression import zstd
    with zstd.open(sys.argv[1]) as f:
        shutil.copyfileobj(f, sys.stdout.buffer, 1 << 20)
except ImportError:
    import zstandard
    with open(sys.argv[1], "rb") as f:
        zstandard.ZstdDecompressor().copy_stream(f, sys.stdout.buffer)
PY
}

ts_dir="$BASE/tailscale_${TAILSCALE_VERSION}_amd64"
if [[ ! -x $ts_dir/tailscaled ]]; then
  fetch "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_amd64.tgz" \
    "$TAILSCALE_SHA256" "$BASE/tailscale.tgz"
  tar -xzf "$BASE/tailscale.tgz" -C "$BASE"
fi

ollama_dir="$BASE/ollama-${OLLAMA_VERSION}"
if [[ ! -x $ollama_dir/bin/ollama ]]; then
  fetch "https://github.com/ollama/ollama/releases/download/${OLLAMA_VERSION}/ollama-linux-amd64.tar.zst" \
    "$OLLAMA_SHA256" "$BASE/ollama.tar.zst"
  rm -rf "$ollama_dir.part"
  mkdir -p "$ollama_dir.part"
  unzstd_to_stdout "$BASE/ollama.tar.zst" | tar -x -C "$ollama_dir.part"
  mv "$ollama_dir.part" "$ollama_dir"
  rm -f "$BASE/ollama.tar.zst"
fi

sock="$BASE/tailscaled.sock"
ts() { "$ts_dir/tailscale" --socket="$sock" "$@"; }

ts_pid="" ollama_pid="" proxy_pid=""
# shellcheck disable=SC2317  # only ever called through the trap below
cleanup() {
  trap - EXIT INT TERM
  log "shutting down"
  if [[ -n $proxy_pid ]]; then
    kill "$proxy_pid" 2>/dev/null || true
  fi
  if [[ -n $ollama_pid ]]; then
    kill "$ollama_pid" 2>/dev/null || true
  fi
  # Logging out removes the ephemeral node at once instead of after its
  # inactivity timeout.
  if [[ -n $ts_pid ]]; then
    ts logout 2>/dev/null || true
    kill "$ts_pid" 2>/dev/null || true
  fi
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# --port=0 picks a free UDP port, so this coexists with other users' tailscaled.
"$ts_dir/tailscaled" \
  --tun=userspace-networking \
  --state=mem: \
  --socket="$sock" \
  --port=0 \
  >"$BASE/tailscaled.log" 2>&1 &
ts_pid=$!

for _ in $(seq 30); do
  [[ -S $sock ]] && break
  kill -0 "$ts_pid" 2>/dev/null || die "tailscaled exited, see ${BASE}/tailscaled.log"
  sleep 1
done
ts up \
  --auth-key="$TS_AUTHKEY" \
  --hostname="$TS_HOSTNAME" \
  --advertise-tags="$TS_TAG" \
  --accept-dns=false \
  --accept-routes=false
unset TS_AUTHKEY
tailnet_ip=$(ts ip -4)
log "joined the tailnet as ${TS_HOSTNAME} (${tailnet_ip})"

export OLLAMA_HOST="127.0.0.1:${OLLAMA_PORT}"
export OLLAMA_MODELS="$BASE/models"
export OLLAMA_CONTEXT_LENGTH="$CONTEXT_LENGTH"
# paperless runs one task worker by default; one slot keeps all VRAM for the
# model and its context.
export OLLAMA_NUM_PARALLEL=1
export OLLAMA_KEEP_ALIVE=1h

"$ollama_dir/bin/ollama" serve >"$BASE/ollama.log" 2>&1 &
ollama_pid=$!

for _ in $(seq 60); do
  curl --silent --fail "http://${OLLAMA_HOST}/api/version" >/dev/null && break
  kill -0 "$ollama_pid" 2>/dev/null || die "ollama exited, see ${BASE}/ollama.log"
  sleep 1
done

# Standard library only, so it runs on the host's python3 (3.8 here). Each
# response is relayed as it arrives, so streamed replies keep working.
cat >"$BASE/host-proxy.py" <<'PY'
import http.client
import http.server
import sys

listen_port, upstream_port = int(sys.argv[1]), int(sys.argv[2])
# Host is dropped so http.client sends 127.0.0.1:<upstream_port> instead.
HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "host", "content-length",
}


class Proxy(http.server.BaseHTTPRequestHandler):
    def _forward(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP_BY_HOP}
        upstream = http.client.HTTPConnection("127.0.0.1", upstream_port, timeout=900)
        try:
            upstream.request(self.command, self.path, body=body, headers=headers)
            resp = upstream.getresponse()
            self.send_response(resp.status, resp.reason)
            for k, v in resp.getheaders():
                if k.lower() not in HOP_BY_HOP:
                    self.send_header(k, v)
            # HTTP/1.0 handler: the body ends when the connection closes.
            self.send_header("Connection", "close")
            self.end_headers()
            read = getattr(resp, "read1", resp.read)
            while True:
                chunk = read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except OSError as exc:
            self.log_error("upstream error: %r", exc)
            try:
                self.send_error(502)
            except OSError:
                pass
        finally:
            upstream.close()

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = _forward


http.server.ThreadingHTTPServer(("127.0.0.1", listen_port), Proxy).serve_forever()
PY

python3 "$BASE/host-proxy.py" "$PORT" "$OLLAMA_PORT" >"$BASE/proxy.log" 2>&1 &
proxy_pid=$!

# Same Host header a tailnet client sends; 403 here means the rewrite failed.
for _ in $(seq 10); do
  code=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --header "Host: ${tailnet_ip}:${PORT}" "http://127.0.0.1:${PORT}/api/version" || true)
  [[ $code == 200 ]] && break
  kill -0 "$proxy_pid" 2>/dev/null || die "host proxy exited, see ${BASE}/proxy.log"
  sleep 1
done
[[ $code == 200 ]] || die "host proxy answered HTTP ${code}, see ${BASE}/proxy.log"

log "pulling ${MODEL}"
"$ollama_dir/bin/ollama" pull "$MODEL"

# Loads the model now, so the first paperless request does not wait for it.
"$ollama_dir/bin/ollama" run "$MODEL" "Antworte mit OK." >/dev/null
"$ollama_dir/bin/ollama" ps >&2

cat >&2 <<EOF

Ready. In paperless, Configuration -> AI:
  LLM backend   ollama
  LLM endpoint  http://${tailnet_ip}:${PORT}
  LLM model     ${MODEL}

Check from mserver:  curl http://${tailnet_ip}:${PORT}/api/version
Logs: ${BASE}/ollama.log, ${BASE}/proxy.log, ${BASE}/tailscaled.log. Ctrl-C to stop.
EOF

# Either process dying leaves paperless without a working endpoint.
while kill -0 "$ollama_pid" 2>/dev/null && kill -0 "$proxy_pid" 2>/dev/null; do
  sleep 5
done
die "ollama or the host proxy exited, see ${BASE}/ollama.log and ${BASE}/proxy.log"
