#!/bin/bash
# ==============================================================================
# Script Name: Strict Network Watchdog Installer (Safe Reboot Edition)
# Description: 自動安裝雙目標(Google/CF)網絡保活腳本，使用系統服務重啟網絡，防止失聯
# System Support: CentOS / Debian / Ubuntu / AlmaLinux / Rocky / Alpine
# Version: 2.6 (Fixed: Replaced 'ip link' with system service restart for safety)
# ==============================================================================

set -u

# --- 顏色定義 ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly PLAIN='\033[0m'

# --- 變量配置 ---
readonly INSTALL_PATH="/root/strict-watchdog.sh"
readonly CONFIG_PATH="/etc/strict-watchdog.conf"
readonly CRON_JOB="*/10 * * * * $INSTALL_PATH"

# --- 錯誤處理函數 ---
error_exit() {
    echo -e "${RED}錯誤: $1${PLAIN}" >&2
    exit 1
}

# --- 檢查 Root 權限 ---
[[ $EUID -ne 0 ]] && error_exit "本腳本需要 Root 權限才能執行"

# --- 檢查必要依賴 ---
for cmd in ip ping awk date grep sed dirname mkdir; do
    command -v "$cmd" &>/dev/null || error_exit "缺少必要工具: $cmd"
done

clear
echo -e "${BLUE}=============================================================${PLAIN}"
echo -e "${BLUE}    嚴格網卡守護程序 v2.6 (Safe Reboot Edition)           ${PLAIN}"
echo -e "${BLUE}=============================================================${PLAIN}"
echo -e "正在準備安裝環境...\n"

# 1. 創建配置文件
echo -e "${YELLOW}> 正在生成配置文件: ${CONFIG_PATH}...${PLAIN}"

cat > "$CONFIG_PATH" << 'EOF'
# ==============================================================================
# Strict Network Watchdog Configuration
# ==============================================================================

# 檢測目標 IP
TARGET1="8.8.8.8"          # Google DNS
TARGET2="1.1.1.1"          # Cloudflare DNS

# 觸發重啟的丟包率閾值 (0-100)
PACKET_LOSS_THRESHOLD=50

# 觸發重啟的延遲閾值 (毫秒)
MAX_LATENCY=500

# 日誌文件路徑
LOG_FILE="/var/log/strict-watchdog/watchdog.log"

# 日誌最大字節數 (1MB)
MAX_LOG_SIZE=1048576

# 日誌輪轉保留行數
LOG_KEEP_LINES=500
EOF

chmod 644 "$CONFIG_PATH"
echo -e "${GREEN}> 配置文件創建成功。${PLAIN}"

# 2. 寫入核心邏輯腳本
echo -e "${YELLOW}> 正在生成檢測腳本至: ${INSTALL_PATH}...${PLAIN}"

cat > "$INSTALL_PATH" << 'EOF'
#!/bin/bash
# ---------------------------------------------------------
# Strict Network Watchdog - Core Logic (v2.6)
# ---------------------------------------------------------

set -u
export LC_ALL=C  # 強制英文環境

# --- 配置加載 ---
readonly CONFIG="/etc/strict-watchdog.conf"
if [[ ! -f "$CONFIG" ]]; then
    echo "[ERROR] 配置文件不存在: $CONFIG" >&2
    exit 1
fi
source "$CONFIG"

# --- 獲取默認網卡 (僅用於記錄日誌，不依賴它重啟) ---
INTERFACE=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1)
[[ -z "$INTERFACE" ]] && INTERFACE="unknown"

# --- 日誌環境初始化 ---
LOG_DIR=$(dirname "$LOG_FILE")
if [[ ! -d "$LOG_DIR" ]]; then
    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        LOG_FILE="/tmp/strict-watchdog.log"
    fi
fi
if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="/tmp/strict-watchdog.log"
fi

# --- 日誌輪轉函數 ---
rotate_log() {
    if [[ -f "$LOG_FILE" ]]; then
        local log_size
        log_size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [[ $log_size -gt $MAX_LOG_SIZE ]]; then
            tail -n "$LOG_KEEP_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] 日誌已輪轉" >> "$LOG_FILE"
        fi
    fi
}

# --- 智能 Ping 檢測函數 (v2.5 正則版) ---
check_target() {
    local target=$1
    local packets=4
    local timeout=2
    
    local output
    output=$(ping -c $packets -W $timeout "$target" 2>&1 || true)
    
    # 解析丟包率
    local loss
    loss=$(echo "$output" | awk '
        /packets transmitted/ {
            for(i=1; i<=NF; i++) {
                if ($i ~ /%/) {
                    gsub(/%/, "", $i)
                    print $i
                    exit
                }
            }
        }
    ')
    
    # 解析平均延遲 (sed 匹配結構)
    local avg
    avg=$(echo "$output" | sed -n 's|.*/\([0-9.]\+\)/[0-9.]\+/.*|\1|p' | cut -d. -f1)
    
    [[ -z "$loss" ]] && loss=100
    [[ -z "$avg" ]] && avg=9999
    
    echo "${loss},${avg}"
}

# --- 安全網絡重啟函數 (Systemd/Service 兼容) ---
restart_network_safely() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 正在重啟網絡服務..." >> "$LOG_FILE"
    
    # 嘗試檢測系統類型並重啟服務
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl list-units --full -all | grep -q "networking.service"; then
            systemctl restart networking
        elif systemctl list-units --full -all | grep -q "network.service"; then
            systemctl restart network
        elif systemctl list-units --full -all | grep -q "NetworkManager.service"; then
            systemctl restart NetworkManager
        else
            # 保底：如果找不到服務，才使用 ip link (帶 DHCP 刷新)
            echo "[WARN] 未找到 systemd 網絡服務，使用 ip link + dhclient 保底..." >> "$LOG_FILE"
            ip link set dev "$INTERFACE" down
            sleep 3
            ip link set dev "$INTERFACE" up
            sleep 5
            dhclient "$INTERFACE" 2>/dev/null || true
        fi
    else
        # 非 systemd 系統 (如 Alpine/OpenRC)
        if [ -f /etc/init.d/networking ]; then
            /etc/init.d/networking restart
        elif [ -f /etc/init.d/network ]; then
            /etc/init.d/network restart
        else
            # 最後的無奈
            ip link set dev "$INTERFACE" down
            sleep 3
            ip link set dev "$INTERFACE" up
            dhclient "$INTERFACE" 2>/dev/null || true
        fi
    fi
    
    # 檢查結果
    sleep 2
    if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 網絡重啟成功，連接已恢復。" >> "$LOG_FILE"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] 網絡重啟後仍無法連接互聯網！" >> "$LOG_FILE"
    fi
}

# --- 主邏輯 ---
rotate_log

result1=$(check_target "$TARGET1")
result2=$(check_target "$TARGET2")

loss1=${result1%%,*}
latency1=${result1##*,}
loss2=${result2%%,*}
latency2=${result2##*,}

RESTART_NEEDED=0
REASON=""

if [[ $loss1 -ge $PACKET_LOSS_THRESHOLD ]] && [[ $loss2 -ge $PACKET_LOSS_THRESHOLD ]]; then
    RESTART_NEEDED=1
    REASON="嚴重丟包 (G:${loss1}%, C:${loss2}% >= ${PACKET_LOSS_THRESHOLD}%)"
elif [[ $latency1 -gt $MAX_LATENCY ]] && [[ $latency2 -gt $MAX_LATENCY ]]; then
    RESTART_NEEDED=1
    REASON="嚴重延遲 (G:${latency1}ms, C:${latency2}ms > ${MAX_LATENCY}ms)"
fi

if [[ $RESTART_NEEDED -eq 1 ]]; then
    {
        echo "------------------------------------------------"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 觸發重啟"
        echo "  原因: $REASON"
        echo "  網卡: $INTERFACE"
    } >> "$LOG_FILE"
    
    # 調用新的安全重啟函數
    restart_network_safely
fi
EOF

# 3. 設置權限
chmod 755 "$INSTALL_PATH"
echo -e "${GREEN}> 腳本生成成功。${PLAIN}"

# 4. 配置定時任務
echo -e "${YELLOW}> 正在配置 Crontab 定時任務...${PLAIN}"
(crontab -l 2>/dev/null | grep -v "$INSTALL_PATH"; echo "$CRON_JOB") | crontab - 2>/dev/null

echo -e "${GREEN}> 定時任務已添加 (頻率: 每10分鐘)。${PLAIN}"
echo -e ""
echo -e "${BLUE}=============================================================${PLAIN}"
echo -e "${GREEN}              安裝成功 (v2.6 Safe Mode)                     ${PLAIN}"
echo -e "${BLUE}=============================================================${PLAIN}"
echo -e "安全升級說明:"
echo -e "  ✅ ${YELLOW}服務級重啟${PLAIN}: 優先使用 systemctl restart networking/network"
echo -e "  ✅ ${YELLOW}DHCP 保活${PLAIN}: 確保重啟後自動獲取 IP，防止 SSH 失聯"
echo -e "  ✅ ${YELLOW}兼容性增強${PLAIN}: 支持 NetworkManager, Debian/CentOS, OpenRC"
echo -e ""
echo -e "測試命令: ${GREEN}bash $INSTALL_PATH${PLAIN}"
echo -e "日誌查看: ${GREEN}tail -f $LOG_FILE${PLAIN}"
echo -e "${BLUE}=============================================================${PLAIN}"
