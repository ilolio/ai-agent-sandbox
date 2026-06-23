# ai-agent-sandbox

Docker コンテナに Claude Code (llama.cpp バックエンド) を閉じ込め、
**プロジェクトごとに独立したコンテナ・特定フォルダのみアクセス・コンテナ別 egress ホワイトリスト**
を実現する構成。

## 前提

- Docker / Docker Compose v2
- llama-server の用意のしかたは 2 通り。どちらでもよい。

### モードA: ホスト版（既定）

host 側で自分で llama-server を起動しておき、コンテナはそこへ繋ぐ。

```
llama-server -hf unsloth/Qwen3-Coder-30B-GGUF:Q4_K_M --host 0.0.0.0 --port 8080 --ctx-size 32768
```
- Anthropic Messages API 対応版（= 2026/01 以降）が必要。
- Claude Code は最低 32K context 必要。8K/16K では実用にならない。
- `--host 0.0.0.0` にしないとコンテナから届かない。

### モードB: 同梱（バンドル）版

llama-server を agent と一緒に compose で起動する。host 側の準備は不要。
`project-configs/<project>.env` に `BUNDLED=1` を書くだけ（詳細は後述）。
GPU を使う場合は NVIDIA Container Toolkit が必要。

## 構成

| 要件 | 実現方法 |
|------|----------|
| プロジェクトごとに分離 | compose の `-p <project>` で別コンテナ・別ネットワーク |
| ファイルのやり取りは特定フォルダだけ | `WORKSPACE` を `/workspace` に bind mount。それ以外は一切見えない |
| Claude Code を llama.cpp で | entrypoint が `ANTHROPIC_BASE_URL` を host の llama-server に向け、`~/.claude/settings.json` を初期生成 |
| egress をコンテナごとに制御 | 起動時 `init-firewall.sh` が iptables でホワイトリスト以外を drop |
| 言語ごとにイメージを選択 | `Dockerfile` をマルチステージ化し、`FLAVOR` で build target を切替 |

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

## 同梱（バンドル）版 llama-server

host 側で llama-server を立てる代わりに、公式 llama.cpp イメージを compose の
サイドカーとして agent と一緒に起動する構成。`project-configs/<project>.env` に
`BUNDLED=1` を書くと、`agent.sh` が `docker-compose.llama.yml` を重ねて
`llama` サービスを起動し、agent をそこへ向ける。

```ini
# project-configs/myapp.env（同梱版）
BUNDLED=1
# 任意で上書き（未指定なら下が既定値）
# LLAMA_MODEL=unsloth/Qwen3-Coder-30B-GGUF:Q4_K_M
# LLAMA_CTX=32768
# LLAMA_IMAGE=ghcr.io/ggml-org/llama.cpp:server
```

```bash
./agent.sh myapp up        # agent と llama を両方起動（初回はモデルを取得）
./agent.sh myapp logs      # モデルのロード進捗はここで確認
./agent.sh myapp claude
```

| 項目 | 挙動 |
|------|------|
| 接続先 | overlay が `LLAMA_HOST=llama`(compose サービス名) に向ける。env の `LLAMA_HOST/PORT` は無視される |
| モデル取得 | `llama` サービスが `-hf` で取得。`llama-models` volume にキャッシュし再起動で再DLしない |
| egress 制御 | agent の firewall は `llama` を解決して自動許可。モデルの DL は firewall の無い `llama` 側で行われるので、agent は閉じたまま |
| 後始末 | `./agent.sh myapp down` で llama も一緒に停止（モデル volume は残る） |

### GPU(NVIDIA) で動かす

NVIDIA ドライバ + NVIDIA Container Toolkit が入った host で、env に以下を足す。
`agent.sh` が `docker-compose.llama-gpu.yml` も重ね、cuda イメージ＋GPU 割当に切り替わる。

```ini
BUNDLED=1
LLAMA_GPU=1
LLAMA_NGL=99                                          # GPU offload 層数
# LLAMA_IMAGE=ghcr.io/ggml-org/llama.cpp:server-cuda13 # CUDA13 等を使う場合のみ
```

> モデルや context 以外の細かい llama-server フラグを足したいときは
> `docker-compose.llama.yml` の `command:` を直接編集する。

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
- llama.cpp: MIT（同梱版で使う公式イメージ `ghcr.io/ggml-org/llama.cpp` も同じく MIT）
  - 取得するモデル（例: Qwen3-Coder）のライセンスは各モデル配布元の規約に従う
- ベースイメージ node:bookworm / 同梱ツール(iptables, ipset, jq, ripgrep 等): いずれも商用利用可（GPL系を含むがリンクではなく実行バイナリ利用のため通常問題なし）
