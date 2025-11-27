# 🌐 自動安裝雙目標(Google/CF)網絡保活腳本，專治低配 VPS 網絡假死

---

## 🚀 一鍵安裝

請使用 `root` 權限在終端執行以下命令：

```bash
curl -sSL https://raw.githubusercontent.com/thenogodcom/ICM/main/install-watchdog.sh | sudo bash
```

首次執行會自動安裝腳本至 `/etc/strict-watchdog.conf` 並進入主選單。
手動腳本執行：

```bash
bash /root/strict-watchdog.sh
```

編輯延遲觸發條件，默認10ms

```bash
nano /etc/strict-watchdog.conf
```

查看網卡重啓記錄

```bash
cat /var/log/strict-watchdog/watchdog.log
```
