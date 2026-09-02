#!/usr/bin/env node
//
// DuckDuckGo 検索をエージェントから使えるようにする小さなツール。
//
// なぜ要るか:
//   Claude Code の組み込み WebSearch は「Anthropic の API サーバ側で実行される
//   server tool」なので、ANTHROPIC_BASE_URL を llama-server に向けた時点で機能しない
//   （llama-server は web_search ツールを実行できない）。OpenCode / pi も既定では
//   Web 検索ツールを持たない。そこで DuckDuckGo を叩くツールをこちら側で用意する。
//
// 2 つのモードを持つ:
//   1) CLI     : websearch "query" [-n 5] [--json]        … bash から使う（pi 用）
//   2) MCP     : websearch --mcp                          … stdio の MCP サーバ
//                                                            （Claude Code / OpenCode 用）
//
// 依存パッケージは無し（Node 22 の global fetch のみ）。npm から何も取らないので、
// egress を絞った状態でもインストールが要らない。
//
// 環境変数（既定値は下の定数）:
//   WEB_SEARCH_RESULTS      既定の件数
//   WEB_SEARCH_REGION       DuckDuckGo の kl パラメータ（例: wt-wt / jp-jp）
//   WEB_SEARCH_SAFE         off | moderate | strict
//   WEB_SEARCH_TIMEOUT_MS   1 リクエストのタイムアウト
//   WEB_SEARCH_MAX_CHARS    web_fetch が返す本文の最大文字数
//   WEB_SEARCH_USER_AGENT   User-Agent（既定は一般的なブラウザのもの）

import { pathToFileURL } from "node:url";

const VERSION = "1.0.0";

const num = (v, d) => {
  const n = Number.parseInt(v ?? "", 10);
  return Number.isFinite(n) && n > 0 ? n : d;
};

const DEFAULT_RESULTS = num(process.env.WEB_SEARCH_RESULTS, 5);
const DEFAULT_REGION = process.env.WEB_SEARCH_REGION || "wt-wt";
const DEFAULT_SAFE = process.env.WEB_SEARCH_SAFE || "moderate";
const TIMEOUT_MS = num(process.env.WEB_SEARCH_TIMEOUT_MS, 15000);
const MAX_CHARS = num(process.env.WEB_SEARCH_MAX_CHARS, 10000);
const USER_AGENT =
  process.env.WEB_SEARCH_USER_AGENT ||
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36";

// DuckDuckGo には公開 API が無いので HTML 版の口を使う。lite は返る HTML が
// 小さく壊れにくいので先に試し、駄目なら html 版に落ちる（どちらも同じパーサで読める）。
// ここに出てくるホストは init-firewall.sh のホワイトリストと揃えること。
const ENDPOINTS = [
  "https://lite.duckduckgo.com/lite/",
  "https://html.duckduckgo.com/html/",
];

// safesearch は cookie の p で渡す（-2=off / -1=moderate / 1=strict）
const SAFE_COOKIE = { off: "-2", moderate: "-1", strict: "1" };

// Node の fetch はネットワーク層の失敗を全部 "fetch failed" に丸めてしまい、
// 実際の理由（cause）が消える。このサンドボックスでは egress をホワイトリストで
// 絞っている都合上、失敗のほとんどは「そのホストが ALLOWED_DOMAINS に無い」
// ——iptables の DROP なので接続タイムアウトになる——なので、そこまで書いて返す。
const DNS_CODES = new Set(["ENOTFOUND", "EAI_AGAIN"]);
const UNREACHABLE_CODES = new Set([
  "UND_ERR_CONNECT_TIMEOUT",
  "ETIMEDOUT",
  "ENETUNREACH",
  "EHOSTUNREACH",
  "ECONNREFUSED",
]);

function describeFetchError(e, host) {
  if (e.name === "TimeoutError" || e.name === "AbortError") {
    return `no response from ${host} within ${TIMEOUT_MS}ms`;
  }
  const code = e.cause?.code || e.cause?.name;
  if (DNS_CODES.has(code)) return `cannot resolve ${host} (${code})`;
  if (UNREACHABLE_CODES.has(code)) {
    return (
      `cannot connect to ${host} (${code}). This sandbox only allows the hosts ` +
      `listed in ALLOWED_DOMAINS, so this address is probably blocked by the egress firewall`
    );
  }
  return code ? `${e.message} (${code})` : e.message;
}

// ---------------------------------------------------------------- HTML 処理

const ENTITIES = {
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ",
  hellip: "…", mdash: "—", ndash: "–", rsquo: "’", lsquo: "‘",
  ldquo: "“", rdquo: "”", middot: "·", times: "×", raquo: "»", laquo: "«",
};

function decodeEntities(s) {
  return s
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => safeCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => safeCodePoint(parseInt(d, 10)))
    .replace(/&([a-z]+);/gi, (m, name) => ENTITIES[name.toLowerCase()] ?? m);
}

function safeCodePoint(cp) {
  try {
    return String.fromCodePoint(cp);
  } catch {
    return "";
  }
}

// タグを落として 1 行のテキストにする（検索結果のタイトル/スニペット用）
function stripTags(html) {
  return decodeEntities(html.replace(/<[^>]*>/g, "")).replace(/\s+/g, " ").trim();
}

// DuckDuckGo のリンクは //duckduckgo.com/l/?uddg=<encoded>&rut=... という
// リダイレクタ経由のことがあるので、実 URL を取り出す。
function unwrapDdgLink(href) {
  const raw = href.startsWith("//") ? `https:${href}` : href;
  try {
    const u = new URL(raw, "https://duckduckgo.com/");
    if (/(^|\.)duckduckgo\.com$/.test(u.hostname) && u.searchParams.has("uddg")) {
      return u.searchParams.get("uddg");
    }
    return u.toString();
  } catch {
    return null;
  }
}

// 検索結果の HTML を読む。lite 版（class='result-link' / 'result-snippet'）と
// html 版（class="result__a" / "result__snippet"）の両方に効く形にしてある。
function parseResults(html) {
  const items = [];

  const linkRe =
    /<a\b([^>]*\bclass=["'][^"']*\bresult(?:__a|-link)\b[^"']*["'][^>]*)>([\s\S]*?)<\/a>/gi;
  const snippetRe =
    /<(a|td)\b[^>]*\bclass=["'][^"']*\bresult(?:__snippet|-snippet)\b[^"']*["'][^>]*>([\s\S]*?)<\/\1>/gi;

  for (const m of html.matchAll(linkRe)) {
    const hrefMatch = /\bhref=["']([^"']+)["']/i.exec(m[1]);
    if (!hrefMatch) continue;
    // 広告（/y.js 経由）とスポンサー枠は落とす
    if (/\/y\.js\b/.test(hrefMatch[1])) continue;
    if (/\b(result--ad|result-sponsored)\b/.test(m[1])) continue;
    // href の中の &amp; を戻してからでないとクエリ(uddg)を読み違える
    const url = unwrapDdgLink(decodeEntities(hrefMatch[1]));
    if (!url || !/^https?:\/\//i.test(url)) continue;
    items.push({ at: m.index, title: stripTags(m[2]) || url, url, snippet: "" });
  }

  // スニペットは直前のリンクに紐付ける（件数がズレても対応が壊れないよう位置で寄せる）
  for (const m of html.matchAll(snippetRe)) {
    const text = stripTags(m[2]);
    if (!text) continue;
    let target = null;
    for (const item of items) {
      if (item.at < m.index) target = item;
      else break;
    }
    if (target && !target.snippet) target.snippet = text;
  }

  // 同じ URL が複数枠に出ることがあるので畳む
  const seen = new Set();
  const out = [];
  for (const { title, url, snippet } of items) {
    if (seen.has(url)) continue;
    seen.add(url);
    out.push({ title, url, snippet });
  }
  return out;
}

// ---------------------------------------------------------------- 検索

async function ddgSearch(query, opts = {}) {
  const maxResults = opts.maxResults ?? DEFAULT_RESULTS;
  const region = opts.region ?? DEFAULT_REGION;
  const safe = SAFE_COOKIE[opts.safesearch ?? DEFAULT_SAFE] ?? SAFE_COOKIE.moderate;

  const body = new URLSearchParams({ q: query, kl: region });
  // 期間しぼり（d=1日 / w=1週 / m=1ヶ月 / y=1年）
  if (opts.timeRange) body.set("df", opts.timeRange);

  const errors = [];
  for (const endpoint of ENDPOINTS) {
    try {
      const res = await fetch(endpoint, {
        method: "POST",
        headers: {
          "Content-Type": "application/x-www-form-urlencoded",
          "User-Agent": USER_AGENT,
          Accept: "text/html,application/xhtml+xml",
          "Accept-Language": "ja,en-US;q=0.8,en;q=0.7",
          Referer: "https://duckduckgo.com/",
          Cookie: `kl=${region}; p=${safe}`,
        },
        body,
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
      if (!res.ok) {
        errors.push(`${endpoint}: HTTP ${res.status}`);
        continue;
      }
      const html = await res.text();
      const results = parseResults(html);
      if (results.length > 0) return { results: results.slice(0, maxResults), endpoint };
      // 0 件は「本当に無い」ときと bot 判定で弾かれたときがある。後者は
      // 次のエンドポイントで通ることがあるので、まだ試していない口があれば回す。
      errors.push(`${endpoint}: no results parsed`);
    } catch (e) {
      errors.push(`${endpoint}: ${describeFetchError(e, new URL(endpoint).host)}`);
    }
  }
  // 全部の口が「0 件」で揃ったときだけ「結果なし」として返す。
  // 1 つでも通信自体が失敗しているならエラーにする（黙って 0 件にすると、
  // firewall で塞がれているのか本当に無いのかが区別できなくなる）。
  if (errors.every((e) => e.endsWith("no results parsed"))) {
    return { results: [], endpoint: ENDPOINTS[0] };
  }
  throw new Error(`duckduckgo request failed (${errors.join(" / ")})`);
}

function formatResults(query, results) {
  if (results.length === 0) {
    return [
      `No results for: ${query}`,
      "",
      "DuckDuckGo returned nothing. The query may be too narrow, or the request was",
      "rate-limited / blocked by the sandbox firewall (see ALLOWED_DOMAINS).",
    ].join("\n");
  }
  const lines = [`Search results for: ${query}`, ""];
  results.forEach((r, i) => {
    lines.push(`${i + 1}. ${r.title}`);
    lines.push(`   ${r.url}`);
    if (r.snippet) lines.push(`   ${r.snippet}`);
    lines.push("");
  });
  return lines.join("\n").trimEnd();
}

// ---------------------------------------------------------------- ページ取得

// 検索結果を開いて読むための最小限の本文抽出。script/style/nav を落として
// タグを剥がすだけの素朴な実装（LLM に渡す用途なので整形の精度より軽さを取る）。
function htmlToText(html) {
  let s = html
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<head\b[\s\S]*?<\/head>/gi, "")
    .replace(/<(script|style|noscript|svg|template)\b[\s\S]*?<\/\1>/gi, "")
    .replace(/<(header|footer|nav|aside)\b[\s\S]*?<\/\1>/gi, "");
  s = s
    .replace(/<\/(p|div|section|article|li|tr|h[1-6]|blockquote|pre)>/gi, "\n")
    .replace(/<br\s*\/?>/gi, "\n");
  return decodeEntities(s.replace(/<[^>]*>/g, ""))
    .replace(/[ \t ]+/g, " ")
    .replace(/\n\s*\n\s*\n+/g, "\n\n")
    .split("\n")
    .map((l) => l.trim())
    .join("\n")
    .trim();
}

async function fetchPage(url, maxChars = MAX_CHARS) {
  let target;
  try {
    target = new URL(url);
  } catch {
    throw new Error(`invalid url: ${url}`);
  }
  if (!/^https?:$/.test(target.protocol)) {
    throw new Error(`unsupported protocol: ${target.protocol}`);
  }

  let res;
  try {
    res = await fetch(target, {
      headers: {
        "User-Agent": USER_AGENT,
        Accept: "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5",
        "Accept-Language": "ja,en-US;q=0.8,en;q=0.7",
      },
      redirect: "follow",
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (e) {
    throw new Error(describeFetchError(e, target.host));
  }
  if (!res.ok) throw new Error(`HTTP ${res.status} ${res.statusText} for ${target}`);

  const type = (res.headers.get("content-type") || "").toLowerCase();
  if (type && !/^(text\/|application\/(json|xml|xhtml))/.test(type)) {
    throw new Error(`unsupported content-type: ${type}`);
  }

  const raw = await res.text();
  const title = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(raw);
  const text = /html|xml/.test(type) || /^\s*<(!doctype|html)/i.test(raw)
    ? htmlToText(raw)
    : raw.trim();

  const head = [`URL: ${res.url || target}`];
  if (title) head.push(`Title: ${stripTags(title[1])}`);
  const body =
    text.length > maxChars
      ? `${text.slice(0, maxChars)}\n\n[truncated at ${maxChars} chars]`
      : text;
  return `${head.join("\n")}\n\n${body}`;
}

// ---------------------------------------------------------------- MCP サーバ

// MCP の stdio トランスポートは「1 行 1 JSON-RPC メッセージ」。
// stdout はプロトコル専用なので、ログは必ず stderr に出すこと。
const TOOLS = [
  {
    name: "web_search",
    description:
      "Search the web with DuckDuckGo and return titles, URLs and snippets. " +
      "Use this whenever you need current information from the internet: docs, " +
      "release notes, error messages, library versions. This is the web search " +
      "for this environment (the built-in WebSearch tool is not available here).",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", description: "Search query." },
        max_results: {
          type: "integer",
          description: `Number of results to return (default ${DEFAULT_RESULTS}, max 20).`,
          minimum: 1,
          maximum: 20,
        },
        region: {
          type: "string",
          description: `DuckDuckGo region code, e.g. "wt-wt" (no region) or "jp-jp" (default ${DEFAULT_REGION}).`,
        },
        time_range: {
          type: "string",
          description: "Limit results by age: d (day), w (week), m (month), y (year).",
          enum: ["d", "w", "m", "y"],
        },
      },
      required: ["query"],
    },
  },
  {
    name: "web_fetch",
    description:
      "Fetch a URL and return its readable text content. Use it to open a result " +
      "returned by web_search. Only http(s) and text-like content types are supported.",
    inputSchema: {
      type: "object",
      properties: {
        url: { type: "string", description: "Absolute http(s) URL to fetch." },
        max_chars: {
          type: "integer",
          description: `Truncate the extracted text to this many characters (default ${MAX_CHARS}).`,
          minimum: 500,
        },
      },
      required: ["url"],
    },
  },
];

async function callTool(name, args = {}) {
  if (name === "web_search") {
    const query = String(args.query ?? "").trim();
    if (!query) throw new Error("query is required");
    const maxResults = Math.min(num(args.max_results, DEFAULT_RESULTS), 20);
    const { results } = await ddgSearch(query, {
      maxResults,
      region: args.region,
      timeRange: args.time_range,
    });
    return formatResults(query, results);
  }
  if (name === "web_fetch") {
    const url = String(args.url ?? "").trim();
    if (!url) throw new Error("url is required");
    return await fetchPage(url, num(args.max_chars, MAX_CHARS));
  }
  throw new Error(`unknown tool: ${name}`);
}

function runMcpServer() {
  const send = (msg) => process.stdout.write(`${JSON.stringify(msg)}\n`);
  const reply = (id, result) => send({ jsonrpc: "2.0", id, result });
  const fail = (id, code, message) => send({ jsonrpc: "2.0", id, error: { code, message } });

  const handle = async (msg) => {
    // id が無いものは通知。応答してはいけない。
    const isNotification = msg.id === undefined || msg.id === null;
    switch (msg.method) {
      case "initialize":
        reply(msg.id, {
          // クライアントが提示したバージョンをそのまま返す（未指定なら既知の最新）
          protocolVersion: msg.params?.protocolVersion || "2025-06-18",
          capabilities: { tools: { listChanged: false } },
          serverInfo: { name: "websearch", version: VERSION },
        });
        return;
      case "tools/list":
        reply(msg.id, { tools: TOOLS });
        return;
      case "tools/call": {
        const { name, arguments: args } = msg.params ?? {};
        try {
          const text = await callTool(name, args ?? {});
          reply(msg.id, { content: [{ type: "text", text }] });
        } catch (e) {
          // ツールの失敗はプロトコルエラーではなく isError で返す（モデルに読ませる）
          reply(msg.id, { content: [{ type: "text", text: `error: ${e.message}` }], isError: true });
        }
        return;
      }
      case "ping":
        reply(msg.id, {});
        return;
      // capabilities では宣言していないが、問い合わせてくるクライアントがいるので空で返す
      case "resources/list":
        reply(msg.id, { resources: [] });
        return;
      case "prompts/list":
        reply(msg.id, { prompts: [] });
        return;
      default:
        if (!isNotification) fail(msg.id, -32601, `method not found: ${msg.method}`);
    }
  };

  // stdin が閉じたら終了する（MCP のシャットダウンはクライアントが stdin を閉じる）。
  // ただし処理中のリクエストは返してから終わる。そうしないと
  // `echo <request> | websearch --mcp` のような叩き方で黙って何も返らない。
  let pending = 0;
  let stdinClosed = false;
  const exitWhenIdle = () => {
    if (stdinClosed && pending === 0) process.exit(0);
  };

  let buf = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => {
    buf += chunk;
    let nl;
    while ((nl = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (!line) continue;
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        fail(null, -32700, "parse error");
        continue;
      }
      pending++;
      handle(msg)
        .catch((e) => {
          process.stderr.write(`[websearch] ${e.stack || e.message}\n`);
          if (msg.id !== undefined && msg.id !== null) fail(msg.id, -32603, e.message);
        })
        .finally(() => {
          pending--;
          exitWhenIdle();
        });
    }
  });
  process.stdin.on("end", () => {
    stdinClosed = true;
    exitWhenIdle();
  });
}

// ---------------------------------------------------------------- CLI

const USAGE = `usage:
  websearch <query...> [-n <count>] [--region <kl>] [--time d|w|m|y] [--json]
  websearch --fetch <url> [--max-chars <n>]
  websearch --mcp          # MCP サーバ(stdio)として動く

例:
  websearch "llama.cpp server api" -n 3
  websearch --fetch https://example.com/docs`;

async function runCli(argv) {
  const opts = { words: [], json: false, fetch: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "-n" || a === "--num") opts.maxResults = num(argv[++i], DEFAULT_RESULTS);
    else if (a === "--region") opts.region = argv[++i];
    else if (a === "--time") opts.timeRange = argv[++i];
    else if (a === "--max-chars") opts.maxChars = num(argv[++i], MAX_CHARS);
    else if (a === "--json") opts.json = true;
    else if (a === "--fetch") opts.fetch = argv[++i];
    else if (a === "-h" || a === "--help") {
      console.log(USAGE);
      return 0;
    } else if (a === "-v" || a === "--version") {
      console.log(VERSION);
      return 0;
    }
    else if (a.startsWith("-")) {
      console.error(`unknown option: ${a}\n\n${USAGE}`);
      return 2;
    } else opts.words.push(a);
  }

  try {
    if (opts.fetch) {
      console.log(await fetchPage(opts.fetch, opts.maxChars ?? MAX_CHARS));
      return 0;
    }
    const query = opts.words.join(" ").trim();
    if (!query) {
      console.error(USAGE);
      return 2;
    }
    const { results } = await ddgSearch(query, opts);
    console.log(opts.json ? JSON.stringify(results, null, 2) : formatResults(query, results));
    return 0;
  } catch (e) {
    console.error(`websearch: ${e.message}`);
    return 1;
  }
}

// テストから import したときに CLI が走らないよう、直接実行されたときだけ動かす
const isMain =
  process.argv[1] !== undefined && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  const argv = process.argv.slice(2);
  if (argv[0] === "--mcp" || process.env.WEB_SEARCH_MCP === "1") {
    runMcpServer();
  } else {
    runCli(argv).then((code) => process.exit(code));
  }
}

export { parseResults, unwrapDdgLink, stripTags, htmlToText, formatResults };
