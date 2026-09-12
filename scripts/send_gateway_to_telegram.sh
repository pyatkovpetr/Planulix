#!/usr/bin/env bash
# Send a gateway archive and its checksum to the Telegram admin channel.
set -euo pipefail

: "${PLANULIX_TELEGRAM_BOT_TOKEN:?missing PLANULIX_TELEGRAM_BOT_TOKEN Actions secret}"
: "${PLANULIX_TELEGRAM_CHAT_ID:?missing PLANULIX_TELEGRAM_CHAT_ID Actions secret}"

archive="${1:?missing gateway archive path}"
checksum="${archive}.sha256"
test -s "$archive"
test -s "$checksum"

response="$(mktemp)"
trap 'rm -f "$response"' EXIT

send_document() {
  local file="$1" caption="$2"
  curl --silent --show-error --fail --retry 3 --retry-delay 2 --retry-all-errors \
    --output "$response" \
    --form-string "chat_id=${PLANULIX_TELEGRAM_CHAT_ID}" \
    --form-string "caption=${caption}" \
    --form "document=@${file}" \
    "https://api.telegram.org/bot${PLANULIX_TELEGRAM_BOT_TOKEN}/sendDocument"
  jq -e '.ok == true' "$response" >/dev/null
}

name="$(basename "$archive")"
ref="${GITHUB_REF_NAME:-local}"
sha="${GITHUB_SHA:-unknown}"
send_document "$archive" "Planulix Gateway ${ref} (${sha:0:12}): ${name}"
send_document "$checksum" "SHA-256 for ${name}"
