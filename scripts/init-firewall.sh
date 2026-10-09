#!/usr/bin/env bash
#
# コンテナ起動時に egress をホワイトリスト制限する。
# ALLOWED_DOMAINS（カンマ区切り）と llama-server のホスト/ポートだけ通す。
# root で実行する前提（entrypoint から sudo 経由で呼ばれる）。
#
set -euo pipefail

ALLOWED_DOMAINS="${ALLOWED_DOMAINS:-}"
# ホスト側 llama-server。Docker Desktop なら host.docker.internal、
# Linux なら compose の extra_hosts で host-gateway を割り当てる。
LLAMA_HOST="${LLAMA_HOST:-host.docker.internal}"
LLAMA_PORT="${LLAMA_PORT:-8080}"

echo "[firewall] initializing egress whitelist..."

# 既存ルールを掃除
iptables -F
iptables -X || true

# loopback は無条件で許可
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# 確立済みコネクションの戻りパケットは許可
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# DNS（名前解決しないとホワイトリスト判定もできない）
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# --- llama-server への接続を許可 ---
# host.docker.internal が複数 IP に解決される環境もあるので、全 IP を許可する
LLAMA_IPS="$(getent ahostsv4 "$LLAMA_HOST" | awk '{print $1}' | sort -u || true)"
if [ -n "$LLAMA_IPS" ]; then
    for ip in $LLAMA_IPS; do
        echo "[firewall] allow llama-server $LLAMA_HOST ($ip):$LLAMA_PORT"
        iptables -A OUTPUT -p tcp -d "$ip" --dport "$LLAMA_PORT" -j ACCEPT
    done
else
    echo "[firewall] WARNING: could not resolve $LLAMA_HOST"
fi

# Linux host-gateway 経由のときのため、デフォルトゲートウェイの当該ポートも許可
GW="$(ip route | awk '/default/ {print $3; exit}')"
if [ -n "${GW:-}" ]; then
    iptables -A OUTPUT -p tcp -d "$GW" --dport "$LLAMA_PORT" -j ACCEPT
fi

# --- ホワイトリストドメインを ipset でまとめる ---
# Web 検索(DuckDuckGo)の口もここに書いてもらう（暗黙に開けない）。
# 書き忘れは entrypoint が起動時に警告する。
ipset create allowed hash:ip -exist
if [ -n "$ALLOWED_DOMAINS" ]; then
    IFS=',' read -ra DOMS <<< "$ALLOWED_DOMAINS"
    for d in "${DOMS[@]}"; do
        d="$(echo "$d" | xargs)"   # trim
        [ -z "$d" ] && continue
        for ip in $(getent ahostsv4 "$d" | awk '{print $1}' | sort -u); do
            ipset add allowed "$ip" -exist
            echo "[firewall] allow $d -> $ip"
        done
    done
fi
iptables -A OUTPUT -m set --match-set allowed dst -j ACCEPT

# --- それ以外の egress は全部 drop ---
iptables -A OUTPUT -j DROP
iptables -P OUTPUT DROP
iptables -P INPUT  DROP

echo "[firewall] done."
