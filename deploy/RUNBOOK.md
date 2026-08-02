# JumpServer 部署 Runbook

單機 Docker Compose 部署的操作手冊(CLJUMPSERV-15)。彙整安裝、上線、日常維運與故障排除。
細節設定見 [README.md](./README.md)。

---

## 0. 架構速覽

```
                 Internet
                    │  80/443
              ┌─────▼─────┐
              │   caddy   │  TLS 反向代理(自動 Let's Encrypt)
              └─────┬─────┘
                    │ (內網 jms_net)
   ┌────────────────┼───────────────────────────┐
   │        ┌───────▼──────┐                     │
   │        │ web (nginx)  │ serve lina+luna     │
   │        └──┬───┬───┬───┘                     │
   │           │   │   │                         │
 ┌─▼─┐ ┌───┐ ┌─▼┐ ┌▼─┐ ┌▼──┐ ┌─────┐ ┌────────┐ ┌──────┐
 │core│ │cel│ │koko│lion│chen│ │magnus│ │postgres│ │redis │
 └────┘ └───┘ └──┘ └──┘ └───┘ └─────┘ └────────┘ └──────┘
  API   task  SSH  RDP  webDB  DBproxy    DB        cache
              2222       (443)  33061…
```

- **對外埠**:80/443(web)、2222(koko SSH)、33061/33062/63790/54320/14330/15210/27018(magnus,用到才開)。
- **內部**:postgres / redis 不對外;core/celery/web/chen 只在 `jms_net`。
- 版本:core/koko/lion/chen/web = `v4.10.18-ce`,magnus = `v3.10.22`(詳見 README「版本對齊」)。

---

## 1. 前置需求

| 項目 | 需求 |
|---|---|
| 機器 | 8 vCPU / 16GB / 100GB+ SSD(最低 4C/8G/50GB),64-bit Linux(Ubuntu 22.04 / Debian 12,amd64) |
| 軟體 | Docker Engine + `docker compose` plugin |
| 網路 | 固定對外 IP;`DOMAIN` 的 DNS A/AAAA 指到本機;防火牆開 80+443(+2222 / magnus 視需求) |
| 其他 | 錄影/稽核會長,磁碟預留成長空間 |

---

## 2. 首次部署

```bash
# 1) 取得 code
git clone https://github.com/cliff-staff/jumpserver.git && cd jumpserver

# 2) 產 .env(隨機 secret)
./deploy/gen-env.sh

# 3) 編輯 deploy/.env:填入真實 DOMAIN 與 TLS_EMAIL(必填,否則 up.sh 會擋)
#    其餘(image tag / TZ / ports)預設即可

# 4) 上線:pull + up -d + 等 core healthy(首次會自動 DB migrate)
./deploy/up.sh
```

完成後瀏覽 `https://<DOMAIN>/`,用 **`admin` / `ChangeMe`** 登入,**立刻改密碼**。

---

## 3. 上線後檢查(對應 #12 冒煙測試)

- [ ] `docker compose -f deploy/docker-compose.yml ps` 全部 `healthy`
- [ ] `https://<DOMAIN>` 憑證有效(Caddy 自動簽發)
- [ ] 登入後改掉 admin 密碼
- [ ] 系統設定 > 終端機:koko / lion / magnus / chen 顯示 online
- [ ] 建一台測試 SSH 資產 → web terminal 可連
- [ ] 建一台 RDP 資產 → lion 圖形連線可用
- [ ] (若用 DB)建 DB 資產 → chen 網頁查詢 / magnus 原生工具連線
- [ ] 連線後在稽核 > 會話裡看得到錄影

---

## 4. 日常操作

```bash
cd /path/to/jumpserver
C="docker compose -f deploy/docker-compose.yml"

$C ps                     # 狀態
$C logs -f core           # 看 log(換服務名)
$C restart core           # 重啟單一服務
$C down                   # 停止(保留資料 volume)
$C up -d                  # 啟動
```

**更新版本**(改 `.env` 的 `COMPONENT_TAG` / `CORE_IMAGE` / `MAGNUS_TAG` 後):

```bash
$C pull && $C up -d       # 拉新 image 並滾動重啟;core 啟動會自動跑新 migration
```

> 升級前務必先 `./deploy/backup.sh`(migration 可能不可逆)。

---

## 5. 備份 / 還原(#13)

```bash
./deploy/backup.sh /var/backups/jumpserver 14      # 手動備份,保留 14 天
# cron: 0 3 * * * cd /path/to/jumpserver && ./deploy/backup.sh /var/backups/jumpserver 14 >> /var/log/jms-backup.log 2>&1

./deploy/restore.sh <backup.tar.gz> --yes          # 還原(具破壞性)
```

備份含:DB dump、`.env`、`core_data`(錄影)、`caddy_data`(憑證)。**備份檔含 secret,存異地並限存取。**

---

## 6. 監控 / 日誌(#14)

```bash
# 日誌輪替(一次性,host 層)
sudo cp deploy/monitoring/daemon.json /etc/docker/daemon.json
sudo systemctl restart docker && docker compose -f deploy/docker-compose.yml up -d

# 健康 / 磁碟監控(cron 每 5 分)
*/5 * * * * cd /path/to/jumpserver && ALERT_WEBHOOK=https://hooks... ./deploy/monitor.sh >> /var/log/jms-monitor.log 2>&1
```

---

## 7. 故障排除

| 症狀 | 可能原因 / 處理 |
|---|---|
| `core` 一直 unhealthy | 看 `logs core`;首次啟動 migrate + 下載較久(start_period 180s);確認 postgres/redis healthy、`.env` 的 DB/REDIS 密碼正確 |
| 元件(koko/lion/magnus/chen)沒 online | `BOOTSTRAP_TOKEN` 各元件與 core 要一致;看該元件 `logs`;確認能連到 `http://core:8080` |
| TLS 憑證簽不出來 | `DOMAIN` DNS 要先指到本機;對外 80 必須可達(ACME HTTP-01);看 `logs caddy`;反覆失敗小心 Let's Encrypt 速率限制 |
| DB 資產(magnus)連不通 | 確認對外開了對應 magnus 埠;magnus online;**注意 core 若換成含單埠變更的版本,magnus v3.10.x 會不相容**(見 README) |
| 磁碟滿 | 多半是錄影成長;`monitor.sh` 會告警;清舊錄影或擴容;確認已套 log rotation |
| 忘記 admin 密碼 | `$C exec core bash -lc "cd apps && python manage.py changepassword admin"` |

---

## 8. 安全備註

- 管理埠(443)建議限來源 IP,別對整個網際網路開。
- `admin` 首登後立即改密碼;啟用 MFA。
- `.env` 與備份檔含 secret:`chmod 600`、勿入 git(已 gitignore)、異地保存。
- `postgres` / `redis` 不對外(僅 `jms_net`)。

---

## 9. 對應 Plane 任務

| Task | 內容 | 產物 |
|---|---|---|
| #4 | 版本對齊 | `.env.example` pin,README |
| #7 | 產 secret | `gen-env.sh` |
| #8 | compose 編排 | `docker-compose.yml` |
| #10 | 啟動 + migrate | `up.sh` |
| #11 | TLS 反代 | `Caddyfile` |
| #13 | 備份 | `backup.sh` / `restore.sh` |
| #14 | 監控 | `monitor.sh` / `monitoring/daemon.json` |
| #15 | 本 runbook | `RUNBOOK.md` |
| #1/#2 | 開機器 / 加固 | 手動(見前置需求 + 安全備註) |
| #9/#12 | magnus 驗證 / 冒煙 | 上線後執行(見第 3 節) |
