#!/usr/bin/env bash
# Managed by Ansible (roles/scan_relay) — edits on the host are overwritten.
#
# Uploads finished scans from the SMB inbox to the Paperless API. Run by
# scan-relay.timer; configuration comes from /etc/scan-relay.env.
#
#   200          queued by Paperless; moved to sent/
#   400/413/415  rejected file; moved to failed/, never retried
#   anything else (network, 401/403, 429, 5xx)  left in the inbox for the next run
#
# Exits non-zero when any file is left behind, so the unit shows as failed.
#
# With SCAN_RELAY_PUSH_URL set, a clean run with an empty failed/ pushes "up"
# to an Uptime Kuma push monitor. Anything else skips the push, and Kuma alerts
# once no push has arrived within the monitor's interval.

set -uo pipefail

: "${PAPERLESS_URL:?}" "${PAPERLESS_TOKEN:?}"
inbox=${SCAN_RELAY_INBOX:?}
sent=${SCAN_RELAY_SENT:?}
failed=${SCAN_RELAY_FAILED:?}
min_age=${SCAN_RELAY_MIN_AGE:-60}
keep_days=${SCAN_RELAY_KEEP_DAYS:-7}
push_url=${SCAN_RELAY_PUSH_URL:-}
uploaded=0

endpoint="${PAPERLESS_URL%/}/api/documents/post_document/"
response=$(mktemp)
trap 'rm -f "$response"' EXIT
status=0

# Flattened into one directory with a timestamp prefix: scanners that create
# per-job subfolders reuse file names across jobs.
archive() {
  local file=$1 dest=$2
  mv -- "$file" "$dest/$(date +%Y%m%dT%H%M%S)-$(basename -- "$file")"
}

while IFS= read -r -d '' file; do
  name=${file#"$inbox"/}
  # curl -F treats ; and , in the filename as separators unless it is quoted.
  quoted=${file//\\/\\\\}
  quoted=${quoted//\"/\\\"}

  code=$(curl --silent --show-error --max-time 300 \
    --output "$response" --write-out '%{http_code}' \
    --header "Authorization: Token ${PAPERLESS_TOKEN}" \
    --form "document=@\"${quoted}\"" \
    "$endpoint") || code=000

  case $code in
    200)
      if (( keep_days > 0 )); then
        archive "$file" "$sent"
      else
        rm -f -- "$file"
      fi
      echo "uploaded ${name}"
      uploaded=$((uploaded + 1))
      ;;
    400|413|415)
      archive "$file" "$failed"
      echo "rejected ${name} (HTTP ${code}): $(head -c 300 "$response")" >&2
      status=1
      ;;
    *)
      echo "upload of ${name} failed (HTTP ${code}): $(head -c 300 "$response"), retrying next run" >&2
      status=1
      ;;
  esac
done < <(find "$inbox" -mindepth 1 -type f ! -name '.*' \
           ! -newermt "${min_age} seconds ago" -print0)

# Subfolders the scanner created, once emptied by the loop above.
find "$inbox" -mindepth 1 -type d -empty ! -newermt "${min_age} seconds ago" -delete

if (( keep_days > 0 )); then
  find "$sent" -mindepth 1 -type f -mtime "+${keep_days}" -delete
fi

if [[ -n $push_url ]]; then
  rejected=$(find "$failed" -mindepth 1 -type f | wc -l)
  if (( status == 0 && rejected == 0 )); then
    curl --silent --show-error --max-time 10 --get --output /dev/null \
      --data-urlencode "status=up" \
      --data-urlencode "msg=ok, ${uploaded} uploaded" \
      "$push_url" || echo "push to uptime kuma failed" >&2
  elif (( rejected > 0 )); then
    echo "${rejected} rejected file(s) in ${failed}, not reporting healthy" >&2
  fi
fi

exit "$status"
