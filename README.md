# 🌐 自動安裝雙目標(Google/CF)網絡保活腳本，專治低配 VPS 網絡假死

---

## 🚀 一鍵安裝

請使用 `root` 權限在終端執行以下命令：

```bash
curl -sSL https://raw.githubusercontent.com/thenogodcom/ICM/main/install-watchdog.sh | sudo bash
```

首次執行會自動安裝腳本至 `/etc/strict-watchdog.conf` 並進入主選單。
之後僅需執行：

```bash
bash /root/strict-watchdog.sh
```

即可隨時啟動管理介面。
