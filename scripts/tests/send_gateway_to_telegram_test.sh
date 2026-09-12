#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT

printf 'archive' > "$test_dir/gateway.tar.gz"
printf 'hash  gateway.tar.gz\n' > "$test_dir/gateway.tar.gz.sha256"

cat > "$test_dir/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
out=''
last=''
for arg in "$@"; do
  if [ "$last" = '--output' ]; then out="$arg"; fi
  case "$arg" in
    document=@*) printf '%s\n' "${arg#document=@}" >> "$MOCK_SEND_LOG" ;;
  esac
  last="$arg"
done
printf '{"ok":true}\n' > "$out"
EOF
chmod +x "$test_dir/curl"

PATH="$test_dir:$PATH" MOCK_SEND_LOG="$test_dir/sent" \
  PLANULIX_TELEGRAM_BOT_TOKEN=fake PLANULIX_TELEGRAM_CHAT_ID=-100123 \
  bash "$repo_dir/scripts/send_gateway_to_telegram.sh" "$test_dir/gateway.tar.gz"

test "$(wc -l < "$test_dir/sent")" -eq 2
test "$(sed -n '1p' "$test_dir/sent")" = "$test_dir/gateway.tar.gz"
test "$(sed -n '2p' "$test_dir/sent")" = "$test_dir/gateway.tar.gz.sha256"

if PATH="$test_dir:$PATH" PLANULIX_TELEGRAM_CHAT_ID=-100123 \
  bash "$repo_dir/scripts/send_gateway_to_telegram.sh" "$test_dir/gateway.tar.gz" \
  > /dev/null 2>&1; then
  echo 'Missing bot token should fail' >&2
  exit 1
fi

echo 'Telegram delivery checks passed'
