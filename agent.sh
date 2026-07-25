#!/usr/bin/env bash
#
# プロジェクト単位で sandbox を操作するラッパー。
#
#   ./agent.sh <project> up          # ビルド & 起動
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

# コンテナ内でエージェントを起動する。
#   claude   … モデルは毎回 --model で渡す
#   opencode … モデルは entrypoint が opencode.json に書いた既定値(llamacpp/<model>)を使う。
#              ここで --model を足すと `opencode run ...` のようにサブコマンドを
#              渡したときにパースが壊れる（グローバル位置の --model は受け付けない）。
#              一時的に変えたいときは ./agent.sh <p> opencode --model llamacpp/<model>
run_claude() {
  "${COMPOSE[@]}" exec agent claude --model "${CLAUDE_MODEL:-local-model}" "$@"
}
run_opencode() {
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
  up)       "${COMPOSE[@]}" up -d --build ;;
  shell)    "${COMPOSE[@]}" exec agent bash ;;
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
