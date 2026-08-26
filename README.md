# ai-agent-sandbox

Docker コンテナに コーディングエージェント CLI (llama.cpp バックエンド) を閉じ込め、
**プロジェクトごとに独立したコンテナ・特定フォルダのみアクセス・コンテナ別 egress ホワイトリスト**
を実現する構成。

エージェントは **Claude Code** / **OpenCode** / **pi** の 3 つがイメージに入っていて、起動時に選ぶ。

## 前提

- host 側で llama-server が起動していること（Anthropic Messages API 対応版 = 2026/01 以降）
  ```
  llama-server -hf unsloth/Qwen3-Coder-30B-GGUF:Q4_K_M --host 0.0.0.0 --port 8080 --ctx-size 131072
  ```
  - Claude Code は最低 32K context 必要（8K/16K では実用にならない）。エージェントは
    ツール結果やファイル内容を都度積むので、実用上は 128K 程度を既定にしておくとよい。
  - `--ctx-size` の値は `project-configs/<project>.env` の `CLAUDE_CTX` / `OPENCODE_CTX` /
    `PI_CTX` と揃えること。揃っていないとエージェント側が context 残量を誤認する。
  - `--host 0.0.0.0` にしないとコンテナから届かない。
  - Claude Code は Anthropic 互換の口、OpenCode と pi は OpenAI 互換の `/v1` を使う。
    llama-server は同じポートで両方出すので、追加の起動オプションは不要。
- Docker / Docker Compose v2

## 構成

| 要件 | 実現方法 |
|------|----------|
| プロジェクトごとに分離 | compose の `-p <project>` で別コンテナ・別ネットワーク |
| ファイルのやり取りは特定フォルダだけ | `WORKSPACE` を `/workspace` に bind mount。それ以外は一切見えない |
| Claude Code を llama.cpp で | entrypoint が `~/.claude/settings.json` に `ANTHROPIC_BASE_URL` とローカルモデル前提の設定（エイリアス解決先・context 上限・thinking / caching オフ等）を生成 |
| OpenCode を llama.cpp で | entrypoint が `~/.config/opencode/opencode.json` に OpenAI 互換プロバイダ `llamacpp` を生成 |
| pi を llama.cpp で | entrypoint が `~/.pi/agent/models.json` に OpenAI 互換プロバイダ `llamacpp` を、`settings.json` に既定モデル等を生成 |
| エージェントを選ぶ | 3 つともインストール済み。`AGENT` が既定値、`./agent.sh <p> claude\|opencode\|pi` で都度切替 |
| egress をコンテナごとに制御 | 起動時 `init-firewall.sh` が iptables でホワイトリスト以外を drop |
| 言語ごとにイメージを選択 | `Dockerfile` をマルチステージ化し、`FLAVOR` で build target を切替 |
| 後から入れたツールを残す | `~/.local` を名前付きボリューム化し、`PATH` に image の `ENV` として追加 |

## エージェント(CLI)の選択

イメージには **Claude Code** / **OpenCode** / **pi** の 3 つが入っている。ビルド時ではなく実行時に選ぶので、
イメージは flavor 単位のまま（`AGENT` を変えても再ビルドは起きない）。

| エージェント | 起動 | 全承認スキップ | llama-server の口 |
|---|---|---|---|
| Claude Code | `./agent.sh <p> claude` | `./agent.sh <p> cc` | Anthropic 互換 (`http://host:port`) |
| OpenCode | `./agent.sh <p> opencode` | `./agent.sh <p> oc` | OpenAI 互換 (`http://host:port/v1`) |
| pi | `./agent.sh <p> pi` | （不要・後述） | OpenAI 互換 (`http://host:port/v1`) |
| `AGENT` の既定 | `./agent.sh <p> run` | `./agent.sh <p> yolo` | — |

> pi は**承認プロンプトの仕組みそのものを持たない**（[設計方針](https://github.com/earendil-works/pi)として
> permission popup / MCP / サブエージェント等を入れていない）。つまり pi は常に「全承認スキップ」相当で動く。
> `./agent.sh <p> yolo`（AGENT=pi のとき）は `pi` と同じ起動になる。詳細は下の「パーミッション設定」参照。

`project-configs/<project>.env`:

```ini
AGENT=opencode        # run / yolo が使う既定エージェント（claude | opencode | pi）
# LLAMA_API_KEY=      # llama-server が --api-key 付きのときの鍵。空でよい（後述）
LLAMA_VISION=1        # llama-server が VLM（--mmproj 付き）かどうか。既定 1（後述）
CLAUDE_CTX=131072     # llama-server の --ctx-size に合わせる
CLAUDE_OUT=32000      # Claude Code の毎リクエスト max_tokens 上限
# OPENCODE_MODEL=     # 空なら CLAUDE_MODEL を使う
OPENCODE_CTX=131072   # llama-server の --ctx-size に合わせる
OPENCODE_OUT=32000    # 毎リクエストの max_tokens。OpenCode 内部の上限が ~32k なのでこれが実質上限
# PI_MODEL=           # 空なら CLAUDE_MODEL を使う
PI_CTX=131072         # llama-server の --ctx-size に合わせる
PI_OUT=32000          # 毎リクエストの max_tokens 兼 compaction.reserveTokens
```

### llama-server の API キー

`llama-server` を `--api-key <key>` 付きで動かしている場合は、`project-configs/<project>.env` に
`LLAMA_API_KEY` を書く。3 つのエージェント全部に同じ鍵が渡る。

```ini
LLAMA_API_KEY=sk-your-key
```

| エージェント | 渡り先 |
|---|---|
| Claude Code | `settings.json` の `ANTHROPIC_AUTH_TOKEN` |
| OpenCode | `opencode.json` の `provider.llamacpp.options.apiKey` |
| pi | `models.json` の `providers.llamacpp.apiKey` |

認証なしの llama-server なら空のままでよい。その場合 entrypoint が `llamacpp-local` という
ダミー値を入れる（空文字だと CLI / SDK が「認証未設定」とみなして落ちたり、pi のように
モデルを候補から外したりするため）。

`LLAMA_API_KEY` を書き換えたら `./agent.sh <p> up` でコンテナを作り直す（設定は毎起動で
再生成される）。実行中コンテナとのズレは `agent.sh` が警告するが、鍵そのものは表示しない。

### 画像入力（VLM）

`LLAMA_VISION` は llama-server が VLM（`--mmproj` 付き）かどうかを表す。**既定は 1**。
テキスト専用モデルを指しているプロジェクトだけ `project-configs/<project>.env` で 0 にする。

```ini
LLAMA_VISION=0
```

OpenCode と pi は**モデルカタログの「画像入力に対応している」という宣言を見て、画像を送るかどうかを
決める**。llamacpp プロバイダのモデルはカタログ（models.dev / pi の同梱カタログ）に無いので、
宣言しない限り「非対応」扱いになる。その状態だとサーバ側が VLM でもエージェントは画像を送らない
——エラーにもならず、単に見えていないように振る舞う。これが `LLAMA_VISION` の役割。

| エージェント | 渡り先 | 0 のときの挙動 |
|---|---|---|
| Claude Code | （使わない） | 画像はそのままリクエストに載る |
| OpenCode | `opencode.json` の `attachment` と `modalities.input` | 添付・画像パートを受け付けない |
| pi | `models.json` の `input` | `read` が画像を捨て「このモデルは画像に対応していない」という注記に差し替える |

反映は `./agent.sh <p> up`。効いているかは起動ログの `vision: 1` と、
`./agent.sh <p> shell` から次で確認できる。

```
pi --list-models          # images 列が yes
opencode models llamacpp --verbose | grep -A10 capabilities
```

テキスト専用モデルに 1 のままだと、画像付きリクエストを llama-server 側が弾く。

### Claude Code 側の設定

entrypoint が毎起動で `~/.claude/settings.json` の `env` ブロックを生成する。
Claude Code は本家 API（複数モデル・巨大 context・thinking / prompt caching あり）を前提に
動くので、**モデルが llama-server の 1 個だけ**という前提に合わせて次を書き込んでいる。

| 区分 | キー | なぜ要るか |
|------|------|-----------|
| 接続 | `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` | llama-server の Anthropic 互換の口に向ける。トークンは `LLAMA_API_KEY`（空ならダミー） |
| モデル解決 | `ANTHROPIC_MODEL` | 既定モデル。コンテナ内で直に `claude` を叩いたときに効く（`agent.sh` は `--model` も渡す） |
| モデル解決 | `ANTHROPIC_DEFAULT_HAIKU_MODEL` | **haiku エイリアスと「バックグラウンド処理」の解決先**。会話要約などが裏で走るので、向けておかないと存在しない `claude-haiku-...` を要求してしまう |
| モデル解決 | `ANTHROPIC_DEFAULT_OPUS_MODEL` / `_SONNET_MODEL` / `_FABLE_MODEL` | `/model` のエイリアスをすべてローカルモデルに寄せる |
| モデル解決 | `CLAUDE_CODE_SUBAGENT_MODEL` | サブエージェント / エージェントチームのモデル。定義側の `model` 指定より優先される |
| モデル解決 | `ANTHROPIC_CUSTOM_MODEL_OPTION`(+`_NAME`) | `/model` のピッカーに `llama-server (local)` として実名で出す |
| context | `CLAUDE_CODE_MAX_CONTEXT_TOKENS` = `CLAUDE_CTX` | 未知のモデル ID だと Claude Code は独自に仮定した context 幅（値は非公開）で compact する。実サイズを教えないと自動 compact の閾値が `--ctx-size` とズレる |
| context | `CLAUDE_CODE_MAX_OUTPUT_TOKENS` = `CLAUDE_OUT` | 毎リクエストの max_tokens。大きいほど自動 compact が早まる（プロンプト予算が減る） |
| 機能オフ | `MAX_THINKING_TOKENS=0` / `DISABLE_INTERLEAVED_THINKING` / `DISABLE_PROMPT_CACHING` | llama-server が解さない thinking パラメータ・beta ヘッダ・`cache_control` を送らない |
| タイムアウト | `API_TIMEOUT_MS` / `CLAUDE_CODE_STREAM_IDLE_TIMEOUT_MS` / `API_FORCE_IDLE_TIMEOUT=0` | ローカル推論は遅い。既定（1 リクエスト 10 分 / 無進捗 5 分）だと prompt 処理中に切られる |
| オフライン | `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` / `DISABLE_AUTOUPDATER` / `DISABLE_TELEMETRY` / `DISABLE_ERROR_REPORTING` | telemetry・エラー報告・自動更新・リリースノート取得を止める。egress を絞っている構成では無駄に叩かせない |
| オフライン | `DISABLE_COST_WARNINGS` | ローカルモデルは課金されないのでコスト警告が無意味 |

プロジェクトごとに変えたいのは実質 `CLAUDE_CTX` / `CLAUDE_OUT` だけなので、env に出しているのはこの 2 つ。
それ以外を変えたいときは `scripts/entrypoint.sh` の jq ブロックを編集して `./agent.sh <p> up`。

> `settings.json` は永続ボリューム上にあり、entrypoint は上記の管理キーだけを上書きする。
> `theme` など自分で足した設定は消えない。

### OpenCode 側の設定

entrypoint が毎起動で `~/.config/opencode/opencode.json` を生成し、llama-server を
`@ai-sdk/openai-compatible` プロバイダとして登録する。プロバイダ id は **`llamacpp`** 固定なので、
モデル名は `llamacpp/<model>` になり、これが設定の既定モデルとして書き込まれる。

> Claude Code と違い `agent.sh` は `--model` を渡さない。OpenCode はサブコマンド
> （`opencode run "..."` など）より前の `--model` を受け付けないため。設定側に既定を持たせることで
> `./agent.sh <p> opencode run "..."` がそのまま通る。一時的に変えたいときは
> `./agent.sh <p> opencode --model llamacpp/<model>`、恒久的には `OPENCODE_MODEL` を変えて
> `./agent.sh <p> up`（コンテナが作り直され、設定が再生成される）。

> id を `llama` にすると models.dev の同名プロバイダ (Meta Llama API) とマージされ、
> 実際には使えないモデルが `opencode models` の候補に混ざる。それを避けるための `llamacpp`。

生成される設定を上書きしたいときは `/workspace/opencode.json`（＝プロジェクト直下）に置く。
OpenCode はグローバル設定とプロジェクト設定をマージし、後者が勝つ。

> **注意**: OpenCode はプロバイダ SDK を実行時に npm から取得する（`~/.config/opencode/node_modules`）。
> 初回起動には `registry.npmjs.org` への egress が要る。モデルカタログの取得には `models.dev`。
> 取得後は `opencode-config` ボリュームに残るので、以降は完全遮断でも動く。

### pi 側の設定

[pi](https://github.com/earendil-works/pi)（npm: `@earendil-works/pi-coding-agent`、コマンド名 `pi`）は
カスタムプロバイダを **JSON で宣言的に足せる**ので、entrypoint が毎起動で 2 ファイルを整える。

| ファイル | 扱い | 中身 |
|---|---|---|
| `~/.pi/agent/models.json` | 毎起動で作り直す | llama-server を `llamacpp` プロバイダ（`openai-completions`）として登録。モデルは 1 個だけ |
| `~/.pi/agent/settings.json` | 管理キーだけ上書き | 既定モデル・thinking オフ・compaction・タイムアウト |

`models.json` に書いている主なキー:

| キー | 値 | なぜ要るか |
|------|----|-----------|
| `baseUrl` / `api` | `http://host:port/v1` / `openai-completions` | llama-server の OpenAI 互換の口に向ける |
| `apiKey` | `LLAMA_API_KEY`（空ならダミー） | pi は「認証が設定されていないモデル」を `/model` の候補から外すので、空にできない |
| `contextWindow` / `maxTokens` | `PI_CTX` / `PI_OUT` | 未知のモデルの既定は 128K / 16K。実サイズを教えないと compact の閾値がズレる |
| `input` | `LLAMA_VISION` に応じて `["text"]` / `["text","image"]` | 画像を受け付けるか。`text` だけだと `read` が画像を捨てる |
| `reasoning: false` | — | Claude Code 側の `MAX_THINKING_TOKENS=0` と同じ方針。thinking パラメータを送らない |
| `compat.supportsDeveloperRole: false` | — | system プロンプトを `developer` ロールではなく `system` ロールで送る（llama-server 向け） |
| `compat.supportsReasoningEffort: false` | — | `reasoning_effort` を送らない |
| `compat.supportsStore: false` | — | OpenAI のログ保存フラグ `store` を送らない |
| `compat.maxTokensField: max_tokens` | — | `max_completion_tokens` ではなく `max_tokens` で上限を渡す |

`settings.json` に書いている管理キー:

| キー | 値 | なぜ要るか |
|------|----|-----------|
| `defaultProvider` / `defaultModel` | `llamacpp` / `PI_MODEL` | 指定が無いと pi は auth が設定済みのモデルから自前の優先順で選ぶ。モデルを足したときに選択が変わらないよう決め打ちする |
| `defaultThinkingLevel` | `off` | `reasoning: false` と対 |
| `compaction.reserveTokens` | `PI_OUT` | 自動 compact のために空けておく分。`PI_CTX - PI_OUT` がプロンプト予算になる（他 2 つと同じ関係） |
| `httpIdleTimeoutMs` | `1800000` | HTTP の無進捗タイムアウト（既定 5 分）。ローカル推論は prompt 処理だけで超えることがある |
| `retry.provider.timeoutMs` | `1800000` | 1 リクエスト全体の上限。`httpIdleTimeoutMs` とは別物なので両方要る |
| `enableInstallTelemetry` | `false` | インストール/更新時の匿名 ping を止める |

さらに compose 側で `PI_OFFLINE=1` を渡し、起動時のバージョン確認・パッケージ更新確認・telemetry を止めている
（egress を絞った構成では、届かない先への接続がタイムアウトまで待たされるだけなので）。

> Claude Code と違い `agent.sh` は `--model` を渡さない。`pi install ...` のようなサブコマンドがあるため。
> 一時的に変えたいときは `./agent.sh <p> pi --model llamacpp/<model>`、恒久的には `PI_MODEL` を変えて
> `./agent.sh <p> up`。

> `models.json` は毎起動で丸ごと作り直す。reasoning モデルを使うなど中身を変えたいときは
> `scripts/entrypoint.sh` の jq ブロックを編集して `./agent.sh <p> up`。
> pi 自身が書く `auth.json` / `trust.json` / `models-store.json` / `sessions/` は触らないので消えない。

> プロジェクト固有の設定は `/workspace/.pi/settings.json`（＝プロジェクト直下）に置くとグローバル設定に
> マージされる。ただし pi は `.pi/` 配下の設定・拡張の読み込み前に **信頼するか確認する**
> （`~/.pi/agent/trust.json` に記録。非対話モードでは既定で読み込まない）。

## 言語(flavor)の選択

`Dockerfile` は共通土台 `base`（3 つのエージェント CLI + egress 制御）を各言語ステージが継承する
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

# 2. エージェントを起動（コンテナが落ちていれば自動で up される）
./agent.sh myapp run          # env の AGENT に従う（既定: claude）
./agent.sh myapp claude       # Claude Code を明示
./agent.sh myapp opencode     # OpenCode を明示
./agent.sh myapp pi           # pi を明示

# 全コマンドを自動承認（Dangerous モード）
./agent.sh myapp yolo         # AGENT に従う
./agent.sh myapp cc           # = claude --dangerously-skip-permissions
./agent.sh myapp oc           # = opencode --auto
                              # pi は承認プロンプト自体が無いので専用アクションは無し

# 追加の引数はそのまま CLI に渡る
./agent.sh myapp claude --resume

# シェルに入りたいとき
./agent.sh myapp shell

# 別プロジェクトは同時並走できる
cp env.example project-configs/other.env && vi project-configs/other.env
./agent.sh other run

# env や Dockerfile を変えて作り直したいとき（明示的な再ビルド・再作成）
./agent.sh myapp up

# 後始末
./agent.sh myapp down
```

### 自動 up について

`up` 以外のアクション（`shell` / `run` / `yolo` / `claude` / `cc` / `opencode` / `oc` / `pi`）は、
コンテナが起動していなければ自動で `up -d --build --wait` してから実行する。
ビルドはキャッシュが効くので、停止状態からでも数秒で立ち上がる。

- entrypoint（firewall 設定と各 CLI の設定生成）が終わるまで待ってから `exec` する。
  判定は compose の healthcheck で、entrypoint が最後に置く `/tmp/.sandbox-ready` を見ている。
- **既に起動しているときは up し直さない。** env を書き換えた直後だと compose が
  コンテナを作り直してしまい、別ターミナルで動いているセッションを巻き込むため。
  env や Dockerfile の変更を反映したいときは明示的に `./agent.sh <project> up` する。

## 何が永続して、何が消えるか

コンテナの書き込みレイヤは `stop`/`start` では残るが、**コンテナが作り直されると消える**
（`./agent.sh <p> down`、および `up` は `--build` 付きなのでイメージや compose 設定が
変わると再作成される）。永続するのは以下の5つだけ。

| パス | 実体 | 用途 |
|------|------|------|
| `/workspace` | host の `WORKSPACE` を bind mount | プロジェクトのソース。`.venv` / `node_modules` などもここに置けば確実に残る |
| `/home/node/.claude` | 名前付きボリューム `claude-config` | Claude Code の設定・履歴 |
| `/home/node/.local` | 名前付きボリューム `local-tools` | 実行時に入れたツール（`~/.local/bin` は `PATH` に入っている）。OpenCode のセッション履歴 `~/.local/share/opencode` もここ |
| `/home/node/.config/opencode` | 名前付きボリューム `opencode-config` | OpenCode の設定と、実行時に npm から取るプロバイダ SDK |
| `/home/node/.pi` | 名前付きボリューム `pi-config` | pi の設定（`models.json` / `settings.json`）・セッション履歴・`pi install` で入れたパッケージ |

これ以外（`/usr/local/bin`、`~/.bashrc`、`~/.cache`、`/tmp` など）に入れたものは再作成で消える。

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

## パーミッション設定

`entrypoint.sh` が起動時に Claude Code と OpenCode へ同じ方針を書き込む
（Claude Code は `~/.claude/settings.json`、OpenCode は `~/.config/opencode/opencode.json`）。

| 区分 | 対象 | 動作 |
|------|------|------|
| `allow` | ファイルの読み書き（Read / Edit / Write） | 自動承認（プロンプトなし） |
| `deny` | `git push --force` / `git push -f` / `git reset --hard` | 常にブロック |
| それ以外 | Bash など | 都度確認 |

> `deny` パターンはコマンド先頭からの前方一致。`git push origin --force`（`--force` が後置）など
> 引数順が異なるパターンは拾えない点に注意。
> OpenCode 側は「最後にマッチしたルールが勝つ」ので、`bash` の `deny` を `"*": "ask"` の後ろに置いている。

制限なしで動かしたい場合は `./agent.sh <project> yolo`（`cc` / `oc`。上記「使い方」参照）。

> **pi は対象外**。pi は承認プロンプト・deny リストの仕組みを持たず、read/bash/edit/write を
> 確認なしで実行する（「隔離はコンテナや VM の仕事であって、エージェント内の部分的な制限は
> 境界を誤解させる」という設計方針）。pi を使うときの安全側の境界は
> **このコンテナ（bind mount した `WORKSPACE` だけ・egress ホワイトリスト）だけ**になる。
> それで足りない場合は `./agent.sh <p> pi --exclude-tools bash` のようにツール自体を外すか、
> 承認が要る用途では Claude Code / OpenCode を使う。

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
- OpenCode: MIT
- pi (@earendil-works/pi-coding-agent): MIT
- llama.cpp: MIT
- ベースイメージ node:bookworm / 同梱ツール(iptables, ipset, jq, ripgrep 等): いずれも商用利用可（GPL系を含むがリンクではなく実行バイナリ利用のため通常問題なし）
