#!/usr/bin/env bash
#
# 1) egress ファイアウォールを張る
# 2) Claude Code / OpenCode を llama.cpp(ホスト) に向ける設定を毎起動で整える
# 3) 渡されたコマンド（既定: bash）を実行
#
# どちらのエージェントを使うかは実行時に選ぶ（agent.sh のアクション、既定は env の AGENT）。
# 両方の設定を毎回書いておくので、片方しか使わなくても害はない。
#
set -euo pipefail

# --- 1) firewall（root 権限が要るので sudo 経由）---
if [ "${ENABLE_FIREWALL:-1}" = "1" ]; then
    sudo /usr/local/bin/init-firewall.sh || echo "[entrypoint] firewall init failed (continuing)"
fi

# --- 2) Claude Code を llama.cpp に向ける（Anthropic 互換エンドポイント）---
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

# --- 3) OpenCode を llama.cpp に向ける（OpenAI 互換エンドポイント = /v1）---
# OpenCode は Anthropic 互換ではなく OpenAI 互換で喋るので、同じ llama-server の
# /v1 を @ai-sdk/openai-compatible プロバイダとして登録する。
# プロバイダ id は llamacpp 固定 → モデル指定は "llamacpp/<model>" になる。
# （id を "llama" にすると models.dev の同名プロバイダ(Meta Llama API)とマージされ、
#   使えないモデルが候補に混ざるので避ける）
OPENCODE_MODEL="${OPENCODE_MODEL:-${CLAUDE_MODEL:-local-model}}"
OPENCODE_CTX="${OPENCODE_CTX:-32768}"
OPENCODE_OUT="${OPENCODE_OUT:-8192}"

# opencode.json は毎起動で env から作り直す（settings.json を同期するのと同じ理由で、
# LLAMA_HOST/PORT や OPENCODE_MODEL を変えたときに古い値が残らないようにする）。
# ディレクトリ自体は永続ボリュームだが、消さないのは opencode.json 以外
# ——実行時に npm から落ちるプロバイダ SDK(node_modules)——だけ。
# プロジェクト固有の上書きは /workspace/opencode.json に置けば OpenCode がマージする。
mkdir -p "$HOME/.config/opencode"
OPENCODE_CONF="$HOME/.config/opencode/opencode.json"
tmp="$(mktemp)"
jq -n \
  --arg base  "http://${LLAMA_HOST}:${LLAMA_PORT}/v1" \
  --arg model "$OPENCODE_MODEL" \
  --argjson ctx "$OPENCODE_CTX" \
  --argjson out "$OPENCODE_OUT" '
{
  "$schema": "https://opencode.ai/config.json",
  autoupdate: false,
  provider: {
    llamacpp: {
      npm: "@ai-sdk/openai-compatible",
      name: "llama-server (local)",
      options: {
        baseURL: $base,
        # ローカルサーバなのでダミーで良い（未設定だと SDK が認証を求めることがある）
        apiKey: "llamacpp-local"
      },
      models: {
        ($model): { name: $model, limit: { context: $ctx, output: $out } }
      }
    }
  },
  model: ("llamacpp/" + $model),
  # Claude Code 側(settings.json)と同じ方針に揃える。
  # bash は「最後にマッチしたルールが勝つ」ので deny を後ろに置く。
  permission: {
    "*": "ask",
    read: "allow",
    edit: "allow",
    bash: {
      "*": "ask",
      "git push --force*": "deny",
      "git push -f*": "deny",
      "git reset --hard*": "deny"
    }
  }
}' > "$tmp" && mv "$tmp" "$OPENCODE_CONF"
echo "[entrypoint] wrote opencode.json (provider llamacpp -> http://${LLAMA_HOST}:${LLAMA_PORT}/v1)"

echo "[entrypoint] Claude Code -> ${ANTHROPIC_BASE_URL}  (model: ${CLAUDE_MODEL:-local-model})"
echo "[entrypoint] OpenCode    -> http://${LLAMA_HOST}:${LLAMA_PORT}/v1  (model: llamacpp/${OPENCODE_MODEL})"
echo "[entrypoint] default agent: ${AGENT:-claude}"
echo "[entrypoint] workspace: $(pwd)"

exec "$@"
