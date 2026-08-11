#!/usr/bin/env bash
#
# プロジェクト単位で sandbox を操作するラッパー。
#
#   ./agent.sh <project> up          # ビルドし直して起動（明示的な再ビルド用）
#   ./agent.sh <project> shell       # コンテナに入る
#   ./agent.sh <project> run         # 既定エージェント(env の AGENT)を起動
#   ./agent.sh <project> yolo        # 同上・全承認スキップ
#   ./agent.sh <project> claude      # Claude Code を起動
#   ./agent.sh <project> cc          # Claude Code・全承認スキップ
#   ./agent.sh <project> opencode    # OpenCode を起動
#   ./agent.sh <project> oc          # OpenCode・全承認スキップ
#   ./agent.sh <project> down        # 停止・削除
#   ./agent.sh <project> logs        # ログ
#
# up 以外のアクションは、コンテナが落ちていれば自動で起動してから実行する
# （初回はイメージのビルドも走る）ので、普段は up を打たなくてよい。
#
# エージェント CLI はイメージに両方入っている。AGENT はあくまで run/yolo の既定値で、
# claude / opencode を直に指定すればいつでも切り替えられる。
#
# 各プロジェクトの設定は project-configs/<project>.env に置く（env.example 参照）。
#
set -euo pipefail
cd "$(dirname "$0")"

USAGE="usage: ./agent.sh <project> <up|shell|run|yolo|claude|cc|opencode|oc|down|logs>"
PROJECT="${1:?$USAGE}"
ACTION="${2:?$USAGE}"

ENV_FILE="project-configs/${PROJECT}.env"
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE (cp env.example project-configs/$PROJECT.env)"; exit 1; }

# env ファイルはホスト側シェルにも読み込む（--env-file は compose 側にしか効かず、
# 下の ${CLAUDE_MODEL} などはこのシェルで展開されるため）。
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

# uid/gid は実行ユーザに合わせる（UID は bash の readonly 変数なので別名を使う）
export HOST_UID HOST_GID
HOST_UID="$(id -u)"; HOST_GID="$(id -g)"

COMPOSE=(docker compose --env-file "$ENV_FILE" -p "$PROJECT")

# コンテナに入るアクション(shell/run/claude/...)は、落ちていれば自動で起動する。
# --build も付ける：キャッシュが効けば数秒で、Dockerfile や scripts/ を触った
# ままの古いイメージで起動して healthcheck に落ちる、という事故を防げる。
#
# 既に走っているときは up し直さない：env を書き換えた直後だと compose が
# コンテナを作り直してしまい、別ターミナルで動いているセッションを巻き込むため。
# その場合は明示的に ./agent.sh <project> up する。
ensure_up() {
  local cid
  cid="$("${COMPOSE[@]}" ps -q --status running agent 2>/dev/null || true)"
  if [ -z "$cid" ]; then
    echo "[agent.sh] $PROJECT: コンテナが起動していないので up します"
    "${COMPOSE[@]}" up -d --build --wait   # --wait = healthy になるまで待つ
    return
  fi
  wait_healthy "$cid"
  warn_env_drift "$cid"
}

# 実行中コンテナの env と現在の env ファイルのズレを検知して警告する。
# ensure_up は実行中コンテナを作り直さない（上のコメント参照）ので、env を
# 編集してもコンテナには反映されない。黙って古い設定（entrypoint が古い env で
# 書いた opencode.json / settings.json）のまま動き続けると気づけないため、
# ここで知らせる。up はしない——直すかどうかはユーザの判断に任せる。
warn_env_drift() {
  local cid="$1" cenv spec var want have drift=""
  cenv="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid" 2>/dev/null)" || return 0

  # compose の environment: に渡している変数と、その既定値（compose 側と揃えること）。
  # WORKSPACE(bind mount) は Docker Desktop がパスを書き換えるので比較できず、対象外。
  for spec in \
    LLAMA_HOST=host.docker.internal \
    LLAMA_PORT=8080 \
    CLAUDE_MODEL=local-model \
    CLAUDE_CTX=131072 \
    CLAUDE_OUT=32000 \
    AGENT=claude \
    OPENCODE_MODEL= \
    OPENCODE_CTX=131072 \
    OPENCODE_OUT=32000 \
    OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX= \
    ALLOWED_DOMAINS= \
    ENABLE_FIREWALL=1
  do
    var="${spec%%=*}"
    want="${!var:-${spec#*=}}"                            # env ファイル側（compose と同じ既定値で補完）
    have="$(sed -n "s/^${var}=//p" <<<"$cenv")"           # コンテナ側
    [ "$have" = "$want" ] || drift+="  ${var}: コンテナ='${have}' / env='${want}'"$'\n'
  done

  [ -z "$drift" ] && return 0
  {
    echo "[agent.sh] warning: $PROJECT: $ENV_FILE がコンテナ起動時から変わっています:"
    printf '%s' "$drift"
    echo "[agent.sh] 反映するには ./agent.sh $PROJECT up でコンテナを作り直してください"
  } >&2
}

# 起動中(entrypoint 実行中)に割り込んだ場合に備えて healthy を待つ。
wait_healthy() {
  local cid="$1" status i
  for i in $(seq 1 60); do
    # healthcheck を持たない古いコンテナでは空になる → 待たずに進む
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid" 2>/dev/null || true)"
    case "$status" in
      healthy|"") return 0 ;;
    esac
    [ "$i" = 1 ] && echo "[agent.sh] $PROJECT: 準備中(entrypoint)を待っています…"
    sleep 1
  done
  echo "[agent.sh] warning: $PROJECT がまだ healthy になりません（このまま続行します）" >&2
}

# コンテナ内でエージェントを起動する。
#   claude   … モデルは毎回 --model で渡す
#   opencode … モデルは entrypoint が opencode.json に書いた既定値(llamacpp/<model>)を使う。
#              ここで --model を足すと `opencode run ...` のようにサブコマンドを
#              渡したときにパースが壊れる（グローバル位置の --model は受け付けない）。
#              一時的に変えたいときは ./agent.sh <p> opencode --model llamacpp/<model>
run_claude() {
  ensure_up
  "${COMPOSE[@]}" exec agent claude --model "${CLAUDE_MODEL:-local-model}" "$@"
}
run_opencode() {
  ensure_up
  "${COMPOSE[@]}" exec agent opencode "$@"
}

# 承認スキップのフラグも CLI ごとに違う
CLAUDE_YOLO=--dangerously-skip-permissions
OPENCODE_YOLO=--auto

# run/yolo が使う既定エージェント。ここで一度だけ検証しておく。
AGENT="${AGENT:-claude}"
case "$AGENT" in
  claude)   run_default() { run_claude   "$@"; }; DEFAULT_YOLO="$CLAUDE_YOLO"   ;;
  opencode) run_default() { run_opencode "$@"; }; DEFAULT_YOLO="$OPENCODE_YOLO" ;;
  *)        echo "unknown AGENT in $ENV_FILE: $AGENT (claude|opencode)"; exit 1 ;;
esac

case "$ACTION" in
  up)       "${COMPOSE[@]}" up -d --build --wait ;;
  shell)    ensure_up; "${COMPOSE[@]}" exec agent bash ;;
  run)      run_default "${@:3}" ;;
  yolo)     run_default "$DEFAULT_YOLO" "${@:3}" ;;
  claude)   run_claude "${@:3}" ;;
  cc)       run_claude "$CLAUDE_YOLO" "${@:3}" ;;
  opencode) run_opencode "${@:3}" ;;
  oc)       run_opencode "$OPENCODE_YOLO" "${@:3}" ;;
  down)     "${COMPOSE[@]}" down ;;
  logs)     "${COMPOSE[@]}" logs -f ;;
  *)        echo "unknown action: $ACTION"; echo "$USAGE"; exit 1 ;;
esac
