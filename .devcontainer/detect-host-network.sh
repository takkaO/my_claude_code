#!/bin/bash
# ホスト(PC)のLAN内IPアドレス(複数可)を検出し、CIDR(/24)を一時ファイルに書き出す
# devcontainer.json の initializeCommand からホスト側で実行される
# 書き出した一時ファイルは init-firewall.sh がコンテナ起動時に読み込み、
# firewallへの許可設定に使用したあと削除する

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_FILE="$SCRIPT_DIR/.host-network.tmp"

# 検出したIPを1行ずつ出力する(Ethernet/WiFi同時接続時は複数行)
detect_ips() {
    if grep -qi microsoft /proc/version 2>/dev/null && command -v powershell.exe >/dev/null 2>&1; then
        # WSL2: `ip route` はWSL2内部の仮想アダプタ(vEthernet)のIPを返してしまい、
        # Windowsホストが実際に繋がっているLANアダプタのIPとは異なる。
        # また Docker Desktop / WSL / VMware が作る仮想アダプタは
        # デフォルトゲートウェイを持たないため、Gateway有無と
        # PhysicalMediaType(物理NICのみ)で絞り込むことで、
        # Docker系ネットワークを混入させずにEthernet/WiFi両方を拾える。
        powershell.exe -NoProfile -Command \
            "Get-NetIPConfiguration | Where-Object {\$_.IPv4DefaultGateway -ne \$null -and \$_.NetAdapter.Status -eq 'Up' -and \$_.NetAdapter.PhysicalMediaType -in @('802.3','Native 802.11')} | ForEach-Object { \$_.IPv4Address.IPAddress }" \
            2>/dev/null | tr -d '\r'
    elif command -v ip >/dev/null 2>&1; then
        # Linux(WSL2以外)
        ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}'
    elif [ "$(uname 2>/dev/null)" = "Darwin" ] && command -v route >/dev/null 2>&1; then
        # macOS
        local iface
        iface=$(route get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')
        [ -n "$iface" ] && ipconfig getifaddr "$iface" 2>/dev/null
    fi
}

IPS="$(detect_ips || true)"

if [ -z "$(echo "$IPS" | tr -d '[:space:]')" ]; then
    echo "detect-host-network: ホストIPの検出に失敗しました。LAN許可はスキップされます。" >&2
    rm -f "$OUT_FILE"
    exit 0
fi

# 各IPを /24 CIDR に変換し、重複を除いて書き出す
echo "$IPS" | awk 'NF{ sub(/\.[0-9]+$/, ".0/24"); print }' | sort -u > "$OUT_FILE"

echo "detect-host-network: ホストLANネットワークを検出しました:"
sed 's/^/  - /' "$OUT_FILE"
