# Docker Sandboxes (sbx) への移行ガイド

この構成（docker compose + iptables）でやっていた「プロジェクトごとの隔離・特定フォルダだけ見せる・
egress ホワイトリスト」を [Docker Sandboxes](https://docs.docker.com/ai/sandboxes/)（`sbx`）に任せ、
このリポジトリには **llama-server 向けの設定（kit）だけ**を残すためのガイド。

旧構成（`agent.sh` / `docker-compose.yml`）はそのまま動くので、並行運用しながら移れる。

> **状態**: 下の YAML は sbx の実機ではまだ動かしていない。spec.yaml は Docker 公式の
> spec ライブラリ（[docker/sbx-kits-contrib](https://github.com/docker/sbx-kits-contrib) の `spec/`）で
> 検証済みで、install スクリプトが生成する JSON も手元で確認してある。実機で確認すべき点は
> 「[未検証のところ](#未検証のところ)」にまとめた。kit と sbxenv.yaml は sbx 側でも Experimental 扱い。

## 何が変わるか

| 旧構成 | sbx |
|---|---|
| コンテナ（host とカーネル共有、`NET_ADMIN` 付与） | microVM（カーネルが別。sandbox ごとに専用の Docker daemon） |
| iptables + ipset。**起動時に DNS 解決した IP を固定** | host 側プロキシが**リクエストごとにドメイン単位**で判定 |
| `project-configs/<p>.env` | `project-configs/<p>.sbxenv.yaml` |
| `entrypoint.sh` が毎起動で設定を生成 | kit（`sbx/kits/*-llamacpp/spec.yaml`）が sandbox 作成時に生成 |
| `AGENT` / `./agent.sh <p> claude\|opencode\|pi` | `--env-arg agent=claude\|opencode\|pi` |
| `ALLOWED_DOMAINS` | `dev-registries` kit（＋ sbx のグローバルポリシー） |
| `FLAVOR`（node / python / go のイメージ） | [mise kit](https://github.com/docker/sbx-kits-contrib/tree/main/mise) ＋ プロジェクトの `.mise.toml` |
| `./agent.sh <p> up` / `down` | `sbx env run` / `sbx env rm` |
| `./agent.sh <p> shell` | `sbx exec -it <sandbox> bash` |
| llama-server は `--host 0.0.0.0` 必須 | `host.docker.internal` を sbx のプロキシが host の localhost に読み替える（127.0.0.1 待ち受けでよい見込み） |
| WSL2 では socat で中継 | Windows では sbx も llama-server もネイティブで動くので不要になる見込み |

## ファイル構成

```
sbx/
├── README.md                    このガイド
├── sbxenv.example.yaml          env.example の sbx 版。project-configs/ にコピーして使う
└── kits/
    ├── claude-llamacpp/         組み込み claude を extends して llama-server に向ける
    ├── opencode-llamacpp/       組み込み opencode を extends して llama-server に向ける
    ├── pi-llamacpp/             pi 入りイメージ（contrib の pi kit と同じもの）を llama-server に向ける
    └── dev-registries/          npm / PyPI / Go / GitHub を許可する mixin（旧 ALLOWED_DOMAINS）
```

3 つの `*-llamacpp` kit は**同じ引数**（`llama_host` / `llama_port` / `api_key` / `model` / `ctx` / `out` / `vision`）を
受け付ける。そのため sbxenv.yaml の `kits[].args` を書き換えずに、`--env-arg agent=...` だけでエージェントを切り替えられる。

## 前提

- sbx が入っていること（詳細は [sbx-releases](https://github.com/docker/sbx-releases)）
  ```bash
  brew install docker/tap/sbx            # macOS
  winget install -h Docker.sbx           # Windows
  sudo apt-get install docker-sbx        # Ubuntu（Docker の apt リポジトリを足したうえで）
  sbx login
  ```
- host で llama-server が起動していること（旧構成と同じ。`--ctx-size` は kit の `ctx` と揃える）
  ```bash
  llama-server -hf unsloth/Qwen3-Coder-30B-GGUF:Q4_K_M --host 127.0.0.1 --port 8080 --ctx-size 131072
  ```

## 手順

### 1. グローバルのネットワークポリシーを決める

sbx には全 sandbox に効くグローバルポリシーがあり、kit の `permissions.network.allow` はそこに**足される**。
旧構成と同じ「ホワイトリスト以外は全部遮断」にしたいなら、最初に一度だけ deny-all にする。

```bash
sbx policy init deny-all
```

既定の Balanced（よく使う開発系サイトを許可済み）のままでも動くが、その場合は `dev-registries` に書いていない
ドメインにも出られる。**これは全 sandbox に効く設定**なので、旧構成以外の用途で sbx を使っているなら影響を確認してから変える。

### 2. プロジェクトの sbxenv.yaml を作る

```bash
cp sbx/sbxenv.example.yaml project-configs/myapp.sbxenv.yaml
vi project-configs/myapp.sbxenv.yaml     # workspace と kits[0].args を編集
```

`project-configs/*.sbxenv.yaml` は `.gitignore` 済み（旧 `.env` と同じく、ローカルパスや鍵を含むため）。

### 3. 起動する

```bash
sbx env plan project-configs/myapp.sbxenv.yaml                      # 何が起きるかを見るだけ
sbx env run  project-configs/myapp.sbxenv.yaml                      # 既定（claude）
sbx env run  project-configs/myapp.sbxenv.yaml --env-arg agent=pi   # pi
sbx env run  project-configs/myapp.sbxenv.yaml --env-arg agent=opencode
```

初回は plan が表示されて承認を求められる。sandbox 名は `myapp-<agent>` になる（エージェントごとに別 sandbox）。

### 4. 動作確認

```bash
sbx ls                                     # sandbox 名を確認
sbx policy log myapp-claude                # どこへの通信が通った／弾かれたか
sbx exec -it myapp-pi bash                 # 中に入る
  pi --list-models                         #   llamacpp/<model> が出て、images 列が vision に合っている
  opencode models llamacpp --verbose       #   （opencode の sandbox で）
```

Claude Code は `/model` に `llama-server (local)` が出ていればつながっている。

### 5. 旧構成を片付ける（任意）

sbx 側で問題なく使えるようになったら `./agent.sh <p> down`。名前付きボリューム（`claude-config` など）は
`docker volume ls` で確認して消す。

## 設定の対応表（`.env` → sbxenv.yaml）

| 旧 `.env` | sbxenv.yaml | 備考 |
|---|---|---|
| `PROJECT` | `name:` | `myapp-${{ env.args.agent }}` |
| `WORKSPACE` | `workspace:` | 相対パスはこのファイルの場所基準 |
| `AGENT` | `args.agent.default` | 都度切り替えは `--env-arg agent=...` |
| `LLAMA_HOST` / `LLAMA_PORT` | `kits[0].args.llama_host` / `llama_port` | egress の許可も kit が自動で足す |
| `LLAMA_API_KEY` | `kits[0].args.api_key` | 旧構成と同じく sandbox 内に平文で渡る |
| `LLAMA_VISION` | `kits[0].args.vision` | `"1"` / `"0"`（文字列） |
| `CLAUDE_MODEL` / `OPENCODE_MODEL` / `PI_MODEL` | `kits[0].args.model` | 3 つ共通。エージェントごとに変えたいときは `--kit-arg model=...` |
| `CLAUDE_CTX` / `OPENCODE_CTX` / `PI_CTX` | `kits[0].args.ctx` | 3 つ共通 |
| `CLAUDE_OUT` / `OPENCODE_OUT` / `PI_OUT` | `kits[0].args.out` | 3 つ共通 |
| `OPENCODE_EXPERIMENTAL_OUTPUT_TOKEN_MAX` | `env:` | sandbox の環境変数として渡す |
| `ALLOWED_DOMAINS` | `kits:` に `dev-registries` | 足りないドメインは自分の mixin を作って並べる |
| `ALLOWED_DOMAINS=`（完全遮断） | `dev-registries` を外す | llama-server だけに出られる |
| `ENABLE_FIREWALL` | なし | sbx では外せない（`sbx policy` で調整） |
| `FLAVOR` | `kits:` に mise kit | |
| `HOST_UID` / `HOST_GID` | なし | sbx がマウントの所有者を扱う |

`kits[].args` を変えたら **sandbox を作り直す**（`sbx env rm` → `sbx env run`）。設定ファイルは sandbox 作成時の
`setup.install` で書かれるので、既存の sandbox には反映されない（plan にも「次の create まで保留」と出る）。

## 挙動の違い

### 承認プロンプト

| エージェント | 旧構成 | sbx |
|---|---|---|
| Claude Code | Read/Edit/Write は自動、Bash は都度確認、git の破壊的操作は deny | 組み込み claude が `--dangerously-skip-permissions` で起動する（全自動）。**deny だけ**を `/etc/claude-code/managed-settings.json` に残した |
| OpenCode | read/edit は自動、bash は都度確認、git の破壊的操作は deny | 同じ方針を kit が生成する opencode.json に書いている |
| pi | 承認の仕組みなし | 同じ |

sbx は「境界は sandbox、中のエージェントは全自動で動かす」という設計なので、旧構成の
`yolo` / `cc` / `oc` に相当する動きが既定になる。

### クラウドの LLM には出ない

組み込み claude は Anthropic の API・ログイン系ドメインを許可しているので、`claude-llamacpp` で
`permissions.network.deny` に入れて塞いでいる（sbx では deny が allow より優先される）。
`pi-llamacpp` は Anthropic の認証情報もドメインも最初から持たない。

### 何が永続するか

| エージェント | 停止→再開 | sandbox の作り直し / `sbx env rm` |
|---|---|---|
| Claude Code | 残る | 会話履歴・セッション・TODO は残る（組み込み claude がボリュームにしている） |
| OpenCode | 残る | 消える |
| pi | 残る | 消える |
| ワークスペース | host のフォルダそのもの | host のフォルダそのもの |

旧構成の `local-tools`（`~/.local`）に相当するものは無い。sandbox 内では `sudo` と apt が使えるが、
恒久的に要るツールは mise（`.mise.toml`）か、`setup.install` でインストールする自分の mixin に書く。

### Docker が使える

sandbox ごとに専用の Docker daemon があるので、エージェントが `docker build` や testcontainers を
そのまま使える（旧構成ではできなかった）。

## 未検証のところ

sbx の実機で確認していない点。動かなかったらここから疑う。

- **`host.docker.internal` の読み替え**: Docker の
  [Model Runner 連携ガイド](https://docs.docker.com/guides/claude-code-sandbox-model-runner/)に、
  sandbox のプロキシが `host.docker.internal` を host の localhost に読み替えるとある。これを前提に
  llama-server を `127.0.0.1` で待ち受ける手順にした。届かなければ `sbx policy log` を見て、
  llama-server を `--host 0.0.0.0` にするか、`llama_host` に host の IP を渡す。
- **組み込み claude / opencode の継承**: `extends: claude` / `extends: opencode` で組み込みの設定を引き継ぐ前提。
  組み込み側が Anthropic などの認証情報の設定を対話で聞いてきたら、使わないのでスキップしてよい。
- **pi イメージに npm があること**: contrib の pi kit と同じイメージ・同じ install を使っている。
- **managed settings の deny**: `--dangerously-skip-permissions` 下でも deny ルールは効くという Claude Code の仕様に頼っている。
- **OPENCODE_CONFIG のマージ**: 組み込み opencode が MCP gateway 用に書く `~/.config/opencode/opencode.json` と
  マージされる前提。
- **リモート kit の参照形式**: sbxenv.example.yaml の mise kit は `:latest` で書いている（contrib の README と同じ）。
  sbx がタグ参照を拒否するようになったら `@sha256:...` の digest で書く。

kit 単体は次で検証できる（sbx の CLI が入っていれば）。

```bash
sbx kit validate ./sbx/kits/claude-llamacpp
sbx kit inspect  ./sbx/kits/claude-llamacpp
```

## ライセンス

- sbx 本体: Docker の配布物（利用条件は Docker の規約に従う）
- docker/sbx-kits-contrib（pi 入りイメージ・mise kit・spec の参考元）: Apache-2.0
- エージェント・llama.cpp: 旧構成と同じ（README 末尾参照）
