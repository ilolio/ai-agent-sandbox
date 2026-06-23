#!/usr/bin/env bash
#
# プロジェクト単位で sandbox を操作するラッパー。
#
#   ./agent.sh <project> up          # ビルド & 起動
#   ./agent.sh <project> shell       # コンテナに入る
#   ./agent.sh <project> claude      # Claude Code を起動
#   ./agent.sh <project> down        # 停止・削除
#   ./agent.sh <project> logs        # ログ
#
# 各プロジェクトの設定は project-configs/<project>.env に置く（env.example 参照）。
#
set -euo pipefail
cd "$(dirname "$0")"

PROJECT="${1:?usage: ./agent.sh <project> <up|shell|claude|down|logs>}"
ACTION="${2:?usage: ./agent.sh <project> <up|shell|claude|down|logs>}"

ENV_FILE="project-configs/${PROJECT}.env"
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE (cp env.example project-configs/$PROJECT.env)"; exit 1; }

# プロジェクト設定をこのスクリプト側でも読む（BUNDLED / LLAMA_GPU / CLAUDE_MODEL 判定用）。
# docker compose は別途 --env-file で同じファイルを読むので二重でも問題ない。
set -a; . "$ENV_FILE"; set +a

# uid/gid は実行ユーザに合わせる（UID は bash の readonly 変数なので別名を使う）
export HOST_UID HOST_GID
HOST_UID="$(id -u)"; HOST_GID="$(id -g)"

# llama-server 同梱モード: BUNDLED=1 なら overlay を重ねて llama サービスも一緒に起動する。
# さらに LLAMA_GPU=1 なら GPU 用 overlay も重ねる。
COMPOSE_FILES=(-f docker-compose.yml)
if [ "${BUNDLED:-0}" = "1" ]; then
    COMPOSE_FILES+=(-f docker-compose.llama.yml)
    [ "${LLAMA_GPU:-0}" = "1" ] && COMPOSE_FILES+=(-f docker-compose.llama-gpu.yml)
fi

COMPOSE=(docker compose --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" -p "$PROJECT")

case "$ACTION" in
  up)     "${COMPOSE[@]}" up -d --build ;;
  shell)  "${COMPOSE[@]}" exec agent bash ;;
  claude) "${COMPOSE[@]}" exec agent claude --model "${CLAUDE_MODEL:-local-model}" "${@:3}" ;;
  cc)     "${COMPOSE[@]}" exec agent claude --model "${CLAUDE_MODEL:-local-model}" --dangerously-skip-permissions "${@:3}" ;;
  down)   "${COMPOSE[@]}" down ;;
  logs)   "${COMPOSE[@]}" logs -f ;;
  *)      echo "unknown action: $ACTION"; exit 1 ;;
esac
