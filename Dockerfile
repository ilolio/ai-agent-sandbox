# syntax=docker/dockerfile:1
#
# マルチステージ構成。プロジェクトの言語に応じて build target(=flavor) を選ぶ。
#
#   選び方: projects/<project>.env に FLAVOR を書く
#       FLAVOR=node     … Node.js プロジェクト（既定）
#       FLAVOR=python   … Python + uv
#       FLAVOR=go       … Go
#
#   compose が build.target に ${FLAVOR} を渡すので、env を変えるだけで切り替わる。
#   新しい言語を足したいときは、末尾に「FROM base AS <name>」のステージを追加するだけ。

# ============================================================
# base: 全 flavor 共通の土台
#   - Claude Code(要 Node) + egress 制御に使うツール + 非 root ユーザ + firewall
#   - 各言語ステージはこの base を継承して言語ツールだけ足す
# ============================================================
FROM node:22-bookworm-slim AS base

# --- 基本ツール + egress 制御に使う iptables/dnsutils ---
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git jq ripgrep \
        iptables ipset dnsutils iproute2 \
        sudo procps less \
    && rm -rf /var/lib/apt/lists/*

# --- Claude Code (Anthropic 公式 CLI) ---
RUN npm install -g @anthropic-ai/claude-code \
    && npm cache clean --force

# --- 非 root ユーザ。host の uid/gid に合わせて build 時に上書き可 ---
ARG UID=1000
ARG GID=1000
RUN if [ "$GID" != "1000" ]; then groupmod -g "$GID" node || true; fi \
    && if [ "$UID" != "1000" ]; then usermod -u "$UID" node || true; fi

# firewall スクリプトは root で実行する必要があるので sudo 経由を許可
COPY scripts/init-firewall.sh /usr/local/bin/init-firewall.sh
COPY scripts/entrypoint.sh    /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh \
    && { echo 'Defaults env_keep += "LLAMA_HOST LLAMA_PORT ALLOWED_DOMAINS"'; \
         echo 'node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh'; } > /etc/sudoers.d/firewall \
    && chmod 0440 /etc/sudoers.d/firewall

# Claude Code の設定/履歴用ディレクトリを node 所有で作っておく。
# 空の名前付きボリュームを初回マウントするとき、Docker はこの所有権ごと
# ボリュームへコピーするため、node ユーザが書き込めるようになる。
RUN mkdir -p /home/node/.claude && chown -R node:node /home/node/.claude

# 作業フォルダ。host の特定フォルダだけここに mount する
WORKDIR /workspace
USER node

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]

# ============================================================
# node: Node.js プロジェクト（既定）
#   base に Node が入っているので追加は不要
# ============================================================
FROM base AS node

# ============================================================
# python: Python + uv プロジェクト
#   uv (Astral, ライセンス: MIT or Apache-2.0) でパッケージ/実行を管理
# ============================================================
FROM base AS python
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-venv python3-pip \
    && rm -rf /var/lib/apt/lists/*
# uv を /usr/local/bin に入れて node ユーザからも使えるようにする
RUN curl -LsSf https://astral.sh/uv/install.sh \
        | env UV_INSTALL_DIR=/usr/local/bin sh
USER node

# ============================================================
# go: Go プロジェクト
#   apt の Go は古いので公式 tarball を入れる
# ============================================================
FROM base AS go
USER root
ARG GO_VERSION=1.22.4
RUN curl -LsSf "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tgz \
    && tar -C /usr/local -xzf /tmp/go.tgz \
    && rm /tmp/go.tgz
ENV PATH="/usr/local/go/bin:${PATH}"
ENV GOPATH=/home/node/go
USER node
