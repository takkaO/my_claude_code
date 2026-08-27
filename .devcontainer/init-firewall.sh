#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'       # Stricter word splitting

# 許可ドメインリスト(git管理、ワークスペース直下)
# NOTE: postStartCommand はワークスペースのbind mount後に実行されるため、
#       ビルド時にコンテナへコピーする必要はなく、常に最新の内容を読み込める
ALLOWED_DOMAINS_FILE="/workspace/.devcontainer/allowed-domains.txt"

# IPSet configuration
IPSET_STATIC="allowed-static"    # GitHub の CIDR 範囲(静的、GitHub Meta API由来)
IPSET_DYNAMIC="allowed-dynamic"  # allowed-domains.txt に列挙したドメイン(動的、DNS解決)
DNS_TTL=600                      # 動的IPのタイムアウト(秒)

# allowed-domains.txt を読み込み、コメント行/空行を除いてDYNAMIC_DOMAINS配列を構築
load_dynamic_domains() {
    local file="$1"
    local -n out_array=$2
    out_array=()

    if [ ! -f "$file" ]; then
        echo "ERROR: Allowed domains file not found: $file"
        exit 1
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$line" ] && continue
        [[ "$line" == \#* ]] && continue
        out_array+=("$line")
    done < "$file"

    if [ ${#out_array[@]} -eq 0 ]; then
        echo "ERROR: No domains loaded from $file"
        exit 1
    fi
}

declare -a DYNAMIC_DOMAINS=()
load_dynamic_domains "$ALLOWED_DOMAINS_FILE" DYNAMIC_DOMAINS
echo "Loaded ${#DYNAMIC_DOMAINS[@]} domain(s) from $ALLOWED_DOMAINS_FILE"

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy "$IPSET_STATIC" 2>/dev/null || true
ipset destroy "$IPSET_DYNAMIC" 2>/dev/null || true
ipset destroy allowed-domains 2>/dev/null || true  # 旧ipsetのクリーンアップ

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# First allow DNS and localhost before any restrictions
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Create ipsets
ipset create "$IPSET_STATIC" hash:net
ipset create "$IPSET_DYNAMIC" hash:ip timeout "$DNS_TTL"

# Fetch GitHub meta information and aggregate + add their IP ranges (static)
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "Processing GitHub IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    echo "Adding GitHub range $cidr"
    ipset add -exist "$IPSET_STATIC" "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

# Resolve and add domains from allowed-domains.txt (dynamic, with TTL)
for domain in "${DYNAMIC_DOMAINS[@]}"; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "ERROR: Failed to resolve $domain"
        exit 1
    fi

    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        echo "Adding $ip for $domain"
        ipset add -exist "$IPSET_DYNAMIC" "$ip" timeout "$DNS_TTL"
    done < <(echo "$ips")
done

# Get host IP from default route
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

# Set up remaining iptables rules
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# --- 実行PCのLANネットワーク許可 ---
# initializeCommand(detect-host-network.sh)がホスト側で検出し書き出した
# 一時ファイルを読み込む。PCによってLANのサブネットが変わり、
# Ethernet/WiFi同時接続時は複数行になりうるため1行ずつ処理する。
# Dockerブリッジのゲートウェイから算出した $HOST_NETWORK とは別に許可する。
# 読み込んだら一時ファイルは削除する。
HOST_LAN_FILE="/workspace/.devcontainer/.host-network.tmp"
if [ -f "$HOST_LAN_FILE" ]; then
    while IFS= read -r HOST_LAN_NETWORK; do
        [ -z "$HOST_LAN_NETWORK" ] && continue
        echo "Allowing host LAN network: $HOST_LAN_NETWORK"
        iptables -A INPUT -s "$HOST_LAN_NETWORK" -j ACCEPT
        iptables -A OUTPUT -d "$HOST_LAN_NETWORK" -j ACCEPT
    done < "$HOST_LAN_FILE"
    rm -f "$HOST_LAN_FILE"
fi

# Set default policies to DROP first
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# First allow established connections for already approved traffic
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Then allow only specific outbound traffic to allowed domains
iptables -A OUTPUT -m set --match-set "$IPSET_STATIC" dst -j ACCEPT
iptables -A OUTPUT -m set --match-set "$IPSET_DYNAMIC" dst -j ACCEPT

# --- 動的ドメインの自動リフレッシュ設定 ---

# リフレッシュ用スクリプトを生成
# 実行の都度 allowed-domains.txt を読み直すため、ドメインの追加/削除は
# コンテナ再起動なしで最大5分以内に反映される
cat > /usr/local/bin/refresh-dynamic-domains.sh << EOF
#!/bin/bash
IPSET_DYNAMIC="$IPSET_DYNAMIC"
DNS_TTL=$DNS_TTL
ALLOWED_DOMAINS_FILE="$ALLOWED_DOMAINS_FILE"

[ -f "\$ALLOWED_DOMAINS_FILE" ] || exit 0

while IFS= read -r line || [ -n "\$line" ]; do
    line="\$(echo "\$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*\$//')"
    [ -z "\$line" ] && continue
    [[ "\$line" == \#* ]] && continue
    domain="\$line"
    ips=\$(dig +short A "\$domain" 2>/dev/null | grep -E '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\$')
    if [ -n "\$ips" ]; then
        while IFS= read -r ip; do
            ipset add "\$IPSET_DYNAMIC" "\$ip" timeout "\$DNS_TTL" -exist 2>/dev/null
        done <<< "\$ips"
    fi
done < "\$ALLOWED_DOMAINS_FILE"
EOF

chmod +x /usr/local/bin/refresh-dynamic-domains.sh 2>/dev/null || true

# cron デーモンを起動(コンテナには init システムが無いため明示的に起動が必要)
if command -v cron &> /dev/null; then
    if ! pgrep -x cron >/dev/null 2>&1; then
        service cron start >/dev/null 2>&1 || cron
    fi

    # cron ジョブ登録(5分毎にリフレッシュスクリプトを実行)
    # NOTE: cronのデフォルトPATHには/usr/sbinが含まれず、ipsetコマンド
    #       (/usr/sbin/ipset)が見つからずリフレッシュがサイレント失敗する
    #       事例があったため、PATHを明示的に指定する。
    (crontab -l 2>/dev/null | grep -v -e refresh-dynamic-domains -e '^PATH=' || true; \
     echo "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"; \
     echo "*/5 * * * * /usr/local/bin/refresh-dynamic-domains.sh") | crontab - 2>/dev/null || true
    echo "cron refresh job registered (every 5 minutes)"
else
    echo "WARNING: cron not installed - dynamic domain IPs will not auto-refresh until container restart"
fi

# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

# Verify GitHub API access
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi