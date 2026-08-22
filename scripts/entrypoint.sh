#!/usr/bin/env bash
#
# 1) egress ファイアウォールを張る
# 2) Claude Code / OpenCode / pi を llama.cpp(ホスト) に向ける設定を毎起動で整える
# 3) 渡されたコマンド（既定: bash）を実行
#
# どのエージェントを使うかは実行時に選ぶ（agent.sh のアクション、既定は env の AGENT）。
# 3 つ分の設定を毎回書いておくので、1 つしか使わなくても害はない。
#
set -euo pipefail

# 準備完了マーカー。compose の healthcheck がこれを見る（agent.sh は healthy に
# なるまで exec を待つ）。コンテナ再起動時に前回の分が残らないよう最初に消す。
READY_FLAG=/tmp/.sandbox-ready
rm -f "$READY_FLAG"

# --- 1) firewall（root 権限が要るので sudo 経由）---
if [ "${ENABLE_FIREWALL:-1}" = "1" ]; then
    sudo /usr/local/bin/init-firewall.sh || echo "[entrypoint] firewall init failed (continuing)"
fi

# --- 2) Claude Code を llama.cpp に向ける（Anthropic 互換エンドポイント）---
LLAMA_HOST="${LLAMA_HOST:-host.docker.internal}"
LLAMA_PORT="${LLAMA_PORT:-8080}"
export ANTHROPIC_BASE_URL="http://${LLAMA_HOST}:${LLAMA_PORT}"
# llama-server が --api-key 付きで動いている場合に渡す鍵。3 エージェント共通。
# 認証なしのサーバでも、空文字だと CLI/SDK 側が認証未設定とみなして怒る
# （pi は認証の無いモデルを /model の候補から外す）ので、未指定ならダミーを入れる。
LLAMA_API_KEY="${LLAMA_API_KEY:-llamacpp-local}"
export ANTHROPIC_AUTH_TOKEN="$LLAMA_API_KEY"
# 実 API キーが環境に残っていると誤送信するので明示的に消す
unset ANTHROPIC_API_KEY || true

CLAUDE_MODEL="${CLAUDE_MODEL:-local-model}"
# Claude Code に伝えるモデルの context/output 上限。OPENCODE_CTX/OUT と同じ役割。
# CTX は llama-server の --ctx-size に合わせる。OUT は毎リクエストの max_tokens 上限で、
# CTX - OUT が残りプロンプト予算（自動 compact の閾値）になる。
CLAUDE_CTX="${CLAUDE_CTX:-131072}"
CLAUDE_OUT="${CLAUDE_OUT:-32000}"

# settings.json の管理キーを毎起動で同期する。
# settings.json は永続ボリューム上にあるので、env(LLAMA_HOST/PORT)を変えても
# 古い ANTHROPIC_BASE_URL が残り続ける。既存の他キー(theme 等)は保持しつつ、
# env ブロックだけを現在値で上書きする（jq は base イメージに同梱）。
#
# ここで書く env は「ローカルモデル 1 個しか居ない」前提の設定。素の Claude Code は
# 本家 API のモデル群を前提に動くので、そのままだと llama-server に存在しないモデル名を
# 要求したり、本家の context/機能を前提にした値を使ってしまう。
mkdir -p "$HOME/.claude"
SETTINGS="$HOME/.claude/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
tmp="$(mktemp)"
jq --arg base  "$ANTHROPIC_BASE_URL" \
   --arg token "$ANTHROPIC_AUTH_TOKEN" \
   --arg model "$CLAUDE_MODEL" \
   --arg ctx   "$CLAUDE_CTX" \
   --arg out   "$CLAUDE_OUT" '
  .env = (.env // {}) + {
    ANTHROPIC_BASE_URL: $base,
    ANTHROPIC_AUTH_TOKEN: $token,

    # --- モデル解決: 全エイリアスをローカルモデルに寄せる ---
    # 既定モデル。agent.sh は --model も渡すが、コンテナ内で直に `claude` を
    # 叩いたとき（shell 経由など）はこちらが効く。
    ANTHROPIC_MODEL: $model,
    # opus/sonnet/haiku/fable の各エイリアスの解決先。特に HAIKU は
    # /model の選択肢だけでなく「バックグラウンド処理」(会話要約など)にも使われるので、
    # ここを向けておかないと裏で claude-haiku-... を要求して 404 になる。
    ANTHROPIC_DEFAULT_OPUS_MODEL:   $model,
    ANTHROPIC_DEFAULT_SONNET_MODEL: $model,
    ANTHROPIC_DEFAULT_HAIKU_MODEL:  $model,
    ANTHROPIC_DEFAULT_FABLE_MODEL:  $model,
    # サブエージェント/エージェントチームのモデル。定義側の model 指定より優先される。
    CLAUDE_CODE_SUBAGENT_MODEL: $model,
    # /model のピッカーに実名で 1 行出す（BASE_URL 差し替え時は表示名も効く）
    ANTHROPIC_CUSTOM_MODEL_OPTION: $model,
    ANTHROPIC_CUSTOM_MODEL_OPTION_NAME: "llama-server (local)",

    # --- context / 出力トークン ---
    # 未知のモデル ID だと Claude Code は独自に仮定した context 幅で compact する
    # （仮定値は非公開）。llama-server の実サイズと食い違うので明示的に教える。
    CLAUDE_CODE_MAX_CONTEXT_TOKENS: $ctx,
    # 未知のモデル ID のときの Claude Code 既定と同じ 32000。大きいほど自動 compact が
    # 早まる（= プロンプトに使える残りが減る）ので、CTX が小さいサーバでは下げること。
    CLAUDE_CODE_MAX_OUTPUT_TOKENS: $out,

    # --- llama-server が解さない機能を切る ---
    # thinking パラメータを送らない（0 = 思考オフ）
    MAX_THINKING_TOKENS: "0",
    # interleaved thinking の beta ヘッダを送らない
    DISABLE_INTERLEAVED_THINKING: "1",
    # cache_control ブロックを送らない（Anthropic のプロンプトキャッシュ用）
    DISABLE_PROMPT_CACHING: "1",

    # --- ローカル推論は遅いのでタイムアウトを伸ばす ---
    API_TIMEOUT_MS: "1800000",                   # 1 リクエストの上限 30 分（既定 10 分）
    CLAUDE_CODE_STREAM_IDLE_TIMEOUT_MS: "1800000",  # 無進捗の監視 30 分（上限値。既定 5 分）
    API_FORCE_IDLE_TIMEOUT: "0",                 # 5 分無バイトで中断する挙動を無効化

    # --- オフライン前提（egress はホワイトリストで塞いである）---
    # telemetry / エラー報告 / 自動更新チェック / リリースノート取得をまとめて止める
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
    DISABLE_AUTOUPDATER: "1",
    CLAUDE_CODE_ATTRIBUTION_HEADER: "0",
    DISABLE_TELEMETRY: "1",
    DISABLE_ERROR_REPORTING: "1",
    # ローカルモデルは課金されないのでコスト警告は無意味
    DISABLE_COST_WARNINGS: "1"
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
OPENCODE_CTX="${OPENCODE_CTX:-131072}"
# limit.output は OpenCode が毎リクエストの max_tokens に使う。小さいと出力が
# 途中で切れる。OpenCode は内部的に 32k 程度で頭打ちにするので 32000 が実質上限。
# ただし context - output が残りプロンプト予算（自動 compact の閾値）になるので、
# ctx が小さいサーバでは OUT も下げること。
OPENCODE_OUT="${OPENCODE_OUT:-32000}"

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
  --arg key   "$LLAMA_API_KEY" \
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
        apiKey: $key
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

# --- 4) pi を llama.cpp に向ける（OpenCode と同じく OpenAI 互換の /v1）---
# pi は「カスタムプロバイダ」を ~/.pi/agent/models.json で宣言的に足せる。
# provider id は OpenCode 側と揃えて llamacpp 固定 → モデル指定は "llamacpp/<model>"。
PI_MODEL="${PI_MODEL:-${CLAUDE_MODEL:-local-model}}"
PI_CTX="${PI_CTX:-131072}"
# maxTokens は pi が毎リクエストの max_tokens に使う。OpenCode のような内部クランプは無い。
PI_OUT="${PI_OUT:-32000}"

mkdir -p "$HOME/.pi/agent"

# models.json は毎起動で env から作り直す（opencode.json と同じ理由）。
# pi 自身が書くのは models-store.json / auth.json / trust.json / sessions なので、
# このファイルを丸ごと上書きしても pi 側の状態は壊れない。
PI_MODELS="$HOME/.pi/agent/models.json"
tmp="$(mktemp)"
jq -n \
  --arg base  "http://${LLAMA_HOST}:${LLAMA_PORT}/v1" \
  --arg key   "$LLAMA_API_KEY" \
  --arg model "$PI_MODEL" \
  --argjson ctx "$PI_CTX" \
  --argjson out "$PI_OUT" '
{
  providers: {
    llamacpp: {
      baseUrl: $base,
      api: "openai-completions",
      apiKey: $key,
      # llama-server が解さない／要らない OpenAI 拡張を送らないための互換フラグ。
      compat: {
        # system プロンプトを developer ロールではなく system ロールで送る
        supportsDeveloperRole: false,
        # reasoning_effort を送らない（下の reasoning:false と対）
        supportsReasoningEffort: false,
        # store フィールド（OpenAI のログ保存）を送らない
        supportsStore: false,
        # max_completion_tokens ではなく max_tokens を使う
        maxTokensField: "max_tokens"
      },
      models: [
        {
          id: $model,
          name: "llama-server (local)",
          # Claude Code 側の MAX_THINKING_TOKENS=0 と同じ方針で thinking は使わない
          reasoning: false,
          input: ["text"],
          contextWindow: $ctx,
          maxTokens: $out,
          # ローカルモデルは課金されないので全部 0（pi のコスト表示が 0 になる）
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }
        }
      ]
    }
  }
}' > "$tmp" && mv "$tmp" "$PI_MODELS"

# settings.json は Claude Code 側と同じく「管理キーだけ上書き」。
# theme や自分で入れた packages/extensions の設定は消さない。
PI_SETTINGS="$HOME/.pi/agent/settings.json"
[ -f "$PI_SETTINGS" ] || echo '{}' > "$PI_SETTINGS"
tmp="$(mktemp)"
jq --arg model "$PI_MODEL" \
   --argjson out "$PI_OUT" '
  . + {
    # 既定のモデル。指定が無いと pi は「auth が設定済みのモデル」から自前の優先順で
    # 選ぶ。今は llamacpp しか auth が無いので結果は同じだが、モデルを足したときに
    # 選択が変わらないよう決め打ちする。
    defaultProvider: "llamacpp",
    defaultModel: $model,
    # models.json の reasoning:false と対。thinking レベルを送らない
    defaultThinkingLevel: "off",
    # インストール/更新時の匿名 ping を止める（PI_OFFLINE でも止まるが明示しておく）
    enableInstallTelemetry: false,
    # HTTP の無進捗タイムアウト（既定 5 分）。ローカル推論では prompt 処理だけで
    # 超えることがある。下の retry.provider.timeoutMs はリクエスト全体の上限で、
    # こちらは undici の headersTimeout/bodyTimeout なので両方要る。
    httpIdleTimeoutMs: 1800000
  } |
  # 自動 compact のために空けておく分。CLAUDE_OUT / OPENCODE_OUT と同じ考え方で
  # contextWindow - reserveTokens が実質のプロンプト予算になる。
  .compaction = ((.compaction // {}) + { reserveTokens: $out }) |
  # ローカル推論は遅いので 1 リクエストの上限を 30 分に伸ばす（既定は SDK 任せ）
  .retry = ((.retry // {}) + { provider: ((.retry.provider // {}) + { timeoutMs: 1800000 }) })
  ' "$PI_SETTINGS" > "$tmp" && mv "$tmp" "$PI_SETTINGS"
echo "[entrypoint] wrote pi models.json / synced settings.json (provider llamacpp -> http://${LLAMA_HOST}:${LLAMA_PORT}/v1)"

echo "[entrypoint] Claude Code -> ${ANTHROPIC_BASE_URL}  (model: ${CLAUDE_MODEL}, ctx: ${CLAUDE_CTX}, out: ${CLAUDE_OUT})"
echo "[entrypoint] OpenCode    -> http://${LLAMA_HOST}:${LLAMA_PORT}/v1  (model: llamacpp/${OPENCODE_MODEL}, ctx: ${OPENCODE_CTX}, out: ${OPENCODE_OUT})"
echo "[entrypoint] pi          -> http://${LLAMA_HOST}:${LLAMA_PORT}/v1  (model: llamacpp/${PI_MODEL}, ctx: ${PI_CTX}, out: ${PI_OUT})"
echo "[entrypoint] default agent: ${AGENT:-claude}"
echo "[entrypoint] workspace: $(pwd)"

: > "$READY_FLAG"

exec "$@"
