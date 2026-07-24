# ai-agent-sandbox

Docker コンテナに Claude Code (llama.cpp バックエンド) を閉じ込め、
**プロジェクトごとに独立したコンテナ・特定フォルダのみアクセス・コンテナ別 egress ホワイトリスト**
を実現する構成。

## 前提

- host 側で llama-server が起動していること（Anthropic Messages API 対応版 = 2026/01 以降）
  ```
  llama-server -hf unsloth/Qwen3-Coder-30B-GGUF:Q4_K_M --host 0.0.0.0 --port 8080 --ctx-size 32768
  ```
  - Claude Code は最低 32K context 必要。8K/16K では実用にならない。
  - `--host 0.0.0.0` にしないとコンテナから届かない。
- Docker / Docker Compose v2

## 構成

| 要件 | 実現方法 |
|------|----------|
| プロジェクトごとに分離 | compose の `-p <project>` で別コンテナ・別ネットワーク |
| ファイルのやり取りは特定フォルダだけ | `WORKSPACE` を `/workspace` に bind mount。それ以外は一切見えない |
| Claude Code を llama.cpp で | entrypoint が `ANTHROPIC_BASE_URL` を host の llama-server に向け、`~/.claude/settings.json` を初期生成 |
| egress をコンテナごとに制御 | 起動時 `init-firewall.sh` が iptables でホワイトリスト以外を drop |
| 言語ごとにイメージを選択 | `Dockerfile` をマルチステージ化し、`FLAVOR` で build target を切替 |
| 後から入れたツールを残す | `~/.local` を名前付きボリューム化し、`PATH` に image の `ENV` として追加 |

## 言語(flavor)の選択

`Dockerfile` は共通土台 `base`（Claude Code + egress 制御）を各言語ステージが継承する
マルチステージ構成。`project-configs/<project>.env` の `FLAVOR` で使うステージを選ぶ。

| FLAVOR | 中身 |
|--------|------|
| `node`（既定） | Node.js（base のまま） |
| `python` | Python3 + [uv](https://github.com/astral-sh/uv) |
| `go` | Go 公式 tarball |

イメージは `ai-agent-sandbox:<flavor>` として flavor ごとに分かれる。
新しい言語を足すときは `Dockerfile` 末尾に `FROM base AS <name>` ステージを追加するだけ。

> パッケージ取得は実行時に egress 制御を受ける。`env.example` の `ALLOWED_DOMAINS` は
> npm / pip・uv / go mod / github の汎用ドメインをひと通り含むので、たいていの flavor は
> そのまま動く。より厳しく絞りたいときは不要な行を削る。

## 使い方

```bash
# 1. プロジェクト設定を作る
cp env.example project-configs/myapp.env
vi project-configs/myapp.env        # WORKSPACE と ALLOWED_DOMAINS を編集

# 2. 起動（初回はビルド）
./agent.sh myapp up

# 3. Claude Code を起動
./agent.sh myapp claude

# 全コマンドを自動承認（Dangerous モード）
./agent.sh myapp cc
# ./agent.sh myapp claude --dangerously-skip-permissions と同等。

# シェルに入りたいとき
./agent.sh myapp shell

# 別プロジェクトは同時並走できる
cp env.example project-configs/other.env && vi project-configs/other.env
./agent.sh other up
./agent.sh other claude

# 後始末
./agent.sh myapp down
```

## 何が永続して、何が消えるか

コンテナの書き込みレイヤは `stop`/`start` では残るが、**コンテナが作り直されると消える**
（`./agent.sh <p> down`、および `up` は `--build` 付きなのでイメージや compose 設定が
変わると再作成される）。永続するのは以下の3つだけ。

| パス | 実体 | 用途 |
|------|------|------|
| `/workspace` | host の `WORKSPACE` を bind mount | プロジェクトのソース。`.venv` / `node_modules` などもここに置けば確実に残る |
| `/home/node/.claude` | 名前付きボリューム `claude-config` | Claude Code の設定・履歴 |
| `/home/node/.local` | 名前付きボリューム `local-tools` | 実行時に入れたツール（`~/.local/bin` は `PATH` に入っている） |

これ以外（`/usr/local/bin`、`~/.bashrc`、`/tmp` など）に入れたものは再作成で消える。

### 実行時にツールを入れる

`~/.local` 配下に入れば、コンテナを作り直しても残り、`PATH` も通ったままになる。
主要なツールはそこへ向くよう Dockerfile 側で設定済み。

| 入れ方 | 行き先 | 備考 |
|--------|--------|------|
| `pip install --user <pkg>` | `~/.local/bin` | 既定でここ |
| `uv tool install <pkg>` | `~/.local/bin` | 既定でここ |
| `npm i -g <pkg>` | `~/.local/bin` | `NPM_CONFIG_PREFIX=/home/node/.local`。sudo 不要 |
| `go install <pkg>@latest` | `~/.local/bin` | `GOBIN` で明示（`$GOPATH/bin` は消えるため） |
| 単体バイナリを手で置く | `mv ./tool ~/.local/bin/` | |

> `PATH` はイメージの `ENV` で設定している。`docker compose exec` は entrypoint も
> `~/.profile` も通らないため、シェル内で `export PATH=...` しても**そのシェル限り**で消える。
> 恒久的に足したいパスは Dockerfile の `ENV PATH` か compose の `environment:` に書く。

**恒久的に必要なツールは Dockerfile の flavor ステージに書く**のが本筋（再現性がある）。
`~/.local` は「ad-hoc に入れたものが毎回消えるのを防ぐ」ための保険。

`cargo install`（`~/.cargo/bin`）など上表にないツールチェーンを使う場合は、
インストール先を `~/.local` 配下に向けるか、compose に別ボリュームを足す。

## Claude Code のパーミッション設定

`entrypoint.sh` が起動時に `~/.claude/settings.json` へ以下を書き込む。

| 区分 | 対象 | 動作 |
|------|------|------|
| `allow` | `Read` / `Edit` / `Write` | 自動承認（プロンプトなし） |
| `deny` | `git push --force` / `git push -f` / `git reset --hard` | 常にブロック |

> `deny` パターンはコマンド先頭からの前方一致。`git push origin --force`（`--force` が後置）など
> 引数順が異なるパターンは拾えない点に注意。

制限なしで動かしたい場合は `./agent.sh <project> cc`（上記「使い方」参照）。

## ネットワーク遮断の挙動

- `LLAMA_HOST:LLAMA_PORT`（llama-server）は常に許可。
- `ALLOWED_DOMAINS` に書いたドメインのみ追加で許可。
- 完全遮断（ローカル LLM のみ・パッケージ取得もさせない）にしたいときは
  `ALLOWED_DOMAINS=` を空にする。
- DNS(53) は名前解決のため許可。それ以外の OUTPUT は DROP。

### 注意
- ホワイトリストは **起動時点の DNS 解決結果(IP)** を ipset に固定する方式。
  CDN など IP が変わるサービスは、コンテナ再起動で再解決される。
  IP が頻繁に変わるサービスを厳密に絞りたい場合は、proxy 方式（Squid 等）の方が堅い。
- `cap_add: NET_ADMIN, NET_RAW` は iptables を張るために必要。
  これを与えたくない場合は別コンテナに proxy を立てて gateway にする構成にする。

## WSL2 + Windows 上の LLMサーバ(llama.cppなど) に届かないとき（中継）

Windows で llama-server を動かし、Docker は WSL2(Ubuntu) 内で動かしている構成
（`コンテナ → WSL → Windows`）では、コンテナから host の LLMサーバ に直接は届かないことがある。

**理由**: WSL2 の **ミラーネットワーク**モードだと、WSL からは `localhost` 経由でしか
Windows 上のサービスに到達できない（host 自身の LAN/Tailscale IP には WSL からは届かない）。
一方コンテナは `host.docker.internal`(= docker0 の `172.17.0.1` = WSL host) までしか届かず、
**コンテナ → Windows の直接経路が無い**。`docker → Windows` を直す手段は無いので、
両者がそれぞれ到達できる接続点（WSL host）に**中継**を1つ挟んで橋渡しする。

```bash
# WSL(Ubuntu) 側で常駐させる。docker0 から見えるポート(例:33030)で待ち受け、
# localhost 経由(ミラー)で Windows の LLMサーバ(例:8080)へ転送する。
sudo apt-get install -y socat
socat TCP-LISTEN:33030,fork,reuseaddr TCP:localhost:8080
```

```ini
# project-configs/<project>.env は中継ポートを指す
LLAMA_HOST=host.docker.internal
LLAMA_PORT=33030
```

これで `host.docker.internal:33030`(= `172.17.0.1:33030`) → socat → `localhost:8080` → Windows llama
と繋がる。`LLAMA_PORT` はファイアウォールのホワイトリストにも自動で反映される。
socat は手動起動だと WSL 再起動で消えるので、常用するなら systemd ユニット等で永続化する。

## ライセンス
- Claude Code: Anthropic 公式 CLI（商用ポリシーは Anthropic の利用規約に従う）
- llama.cpp: MIT
- ベースイメージ node:bookworm / 同梱ツール(iptables, ipset, jq, ripgrep 等): いずれも商用利用可（GPL系を含むがリンクではなく実行バイナリ利用のため通常問題なし）
