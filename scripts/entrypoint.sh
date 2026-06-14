#!/usr/bin/env bash
#
# 1) egress ファイアウォールを張る
# 2) Claude Code を llama.cpp(ホスト) に向ける環境を初期実行で整える
# 3) 渡されたコマンド（既定: bash）を実行
#
set -euo pipefail

# --- 1) firewall（root 権限が要るので sudo 経由）---
if [ "${ENABLE_FIREWALL:-1}" = "1" ]; then
    sudo /usr/local/bin/init-firewall.sh || echo "[entrypoint] firewall init failed (continuing)"
fi

# --- 2) Claude Code を llama.cpp に向ける ---
LLAMA_HOST="${LLAMA_HOST:-host.docker.internal}"
LLAMA_PORT="${LLAMA_PORT:-8080}"
export ANTHROPIC_BASE_URL="http://${LLAMA_HOST}:${LLAMA_PORT}"
# ローカルサーバなのでトークンはダミーで良い（空だと CLI が怒る）
export ANTHROPIC_AUTH_TOKEN="${ANTHROPIC_AUTH_TOKEN:-llamacpp-local}"
# 実 API キーが環境に残っていると誤送信するので明示的に消す
unset ANTHROPIC_API_KEY || true

# settings.json の管理キーを毎起動で同期する。
# settings.json は永続ボリューム上にあるので、env(LLAMA_HOST/PORT)を変えても
# 古い ANTHROPIC_BASE_URL が残り続ける。既存の他キー(theme 等)は保持しつつ、
# env ブロックだけを現在値で上書きする（jq は base イメージに同梱）。
mkdir -p "$HOME/.claude"
SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
tmp="$(mktemp)"
jq --arg base "$ANTHROPIC_BASE_URL" --arg token "$ANTHROPIC_AUTH_TOKEN" '
  .env = (.env // {}) + {
    ANTHROPIC_BASE_URL: $base,
    ANTHROPIC_AUTH_TOKEN: $token,
    CLAUDE_CODE_ATTRIBUTION_HEADER: "0",
    DISABLE_TELEMETRY: "1",
    DISABLE_ERROR_REPORTING: "1"
  } |
  .permissions = {
    "allow": ["Read", "Edit", "Write"],
    "deny": [
      "Bash(git push --force:*)",
      "Bash(git push -f:*)",
      "Bash(git reset --hard:*)"
    ]
  }' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
echo "[entrypoint] synced settings.json (ANTHROPIC_BASE_URL=${ANTHROPIC_BASE_URL})"

echo "[entrypoint] Claude Code -> ${ANTHROPIC_BASE_URL}  (model: ${CLAUDE_MODEL:-local-model})"
echo "[entrypoint] workspace: $(pwd)"

exec "$@"
