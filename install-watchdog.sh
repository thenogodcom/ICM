#!/bin/bash
# ==============================================================================
# Script Name: Strict Network Watchdog Installer (Ultimate Edition)
# Description: 自動安裝雙目標(Google/CF)網絡保活腳本，專治低配 VPS 網絡假死
# System Support: CentOS / Debian / Ubuntu / AlmaLinux / Rocky / Alpine
# Version: 2.5 (Fixed: Latency regex strictly matches 'min/avg/max' pattern)
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
echo -e "${BLUE}    嚴格網卡守護程序 v2.5 (Ultimate Edition)              ${PLAIN}"
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

# 網卡重啟等待時間 (秒)
RESTART_WAIT=3

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
# Strict Network Watchdog - Core Logic (v2.5)
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

# --- 獲取默認網卡 ---
INTERFACE=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1)
if [[ -z "$INTERFACE" ]]; then
    INTERFACE=$(ip link | awk -F: '$0 !~ "lo|vir|wl|^[^0-9]"{print $2;getline}' | head -1 | sed 's/ //g')
fi
if [[ -z "$INTERFACE" ]]; then
    logger -t strict-watchdog "FATAL: 無法獲取默認網卡"
    exit 1
fi

# --- 日誌環境初始化 (帶 Fallback 機制) ---
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

# --- 智能 Ping 檢測函數 (正則結構匹配 - 最安全方案) ---
check_target() {
    local target=$1
    local packets=4
    local timeout=2
    
    # 執行 ping (忽略錯誤碼)
    local output
    output=$(ping -c $packets -W $timeout "$target" 2>&1 || true)
    
    # 1. 解析丟包率 (Awk 遍歷字段查找百分比)
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
    
    # 2. 解析平均延遲 (使用 sed 匹配 num/num/num 結構)
    # 這是唯一能區分 IP 地址和 Ping 統計數據的方法
    # 邏輯: 尋找 "數字/數字/數字" 的模式，並提取中間那個
    local avg
    avg=$(echo "$output" | sed -n 's|.*/\([0-9.]\+\)/[0-9.]\+/.*|\1|p' | cut -d. -f1)
    
    # 兜底
    [[ -z "$loss" ]] && loss=100
    [[ -z "$avg" ]] && avg=9999
    
    echo "${loss},${avg}"
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

# 判斷邏輯
if [[ $loss1 -ge $PACKET_LOSS_THRESHOLD ]] && [[ $loss2 -ge $PACKET_LOSS_THRESHOLD ]]; then
    RESTART_NEEDED=1
    REASON="嚴重丟包 (G:${loss1}%, C:${loss2}% >= ${PACKET_LOSS_THRESHOLD}%)"
elif [[ $latency1 -gt $MAX_LATENCY ]] && [[ $latency2 -gt $MAX_LATENCY ]]; then
    RESTART_NEEDED=1
    REASON="嚴重延遲 (G:${latency1}ms, C:${latency2}ms > ${MAX_LATENCY}ms)"
fi

# 執行重啟
if [[ $RESTART_NEEDED -eq 1 ]]; then
    {
        echo "------------------------------------------------"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 觸發重啟"
        echo "  原因: $REASON"
        echo "  網卡: $INTERFACE"
    } >> "$LOG_FILE"
    
    ip link set dev "$INTERFACE" down 2>/dev/null
    sleep "$RESTART_WAIT"
    if ip link set dev "$INTERFACE" up 2>/dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 重啟成功" >> "$LOG_FILE"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [FATAL] 重啟失敗" >> "$LOG_FILE"
        logger -t strict-watchdog "FATAL: 網卡重啟失敗 ($INTERFACE)"
    fi
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
echo -e "${GREEN}              安裝成功 (v2.5 Ultimate)                      ${PLAIN}"
echo -e "${BLUE}=============================================================${PLAIN}"
echo -e "優化摘要:"
echo -e "  ✅ 延遲解析: 修復 grep 取值 BUG，使用 sed 匹配 'min/avg/max' 結構"
echo -e "  ✅ 日誌容錯: 權限不足自動切換至 /tmp，保證日誌不丟失"
echo -e "  ✅ 丟包解析: AWK 智能遍歷，精準識別百分比字段"
echo -e "  ✅ 系統集成: 關鍵錯誤記錄到 syslog 便於監控"
echo -e ""
echo -e "測試命令: ${GREEN}bash $INSTALL_PATH${PLAIN}"
echo -e "日誌查看: ${GREEN}tail -f $LOG_FILE${PLAIN}"
echo -e "${BLUE}=============================================================${PLAIN}"
