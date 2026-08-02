# JumpServer 單機 Docker Compose 部署

單機 `docker compose` 編排,PostgreSQL 與 Redis 自建於容器內。對應 Plane **CLJUMPSERV-8**。

> 維運操作手冊(安裝 / 上線 / 備份 / 故障排除)見 **[RUNBOOK.md](./RUNBOOK.md)**。

## 元件

| 服務 | Image | 角色 | 對外埠 |
|---|---|---|---|
| postgresql | `postgres:16-bookworm` | 資料庫 | 內部 |
| redis | `redis:7-bookworm` | 快取 / session / celery | 內部 |
| core | `${CORE_IMAGE}`(本 repo) | API/UI + WS(`jms start web`) | 內部 8080/8070 |
| celery | `${CORE_IMAGE}` | 背景任務(`jms start task`) | 內部 |
| koko | `jumpserver/koko` | SSH/Telnet/K8s 終端代理 | `2222` |
| lion | `jumpserver/lion` | RDP/VNC 圖形代理 | 內部 |
| magnus | `jumpserver/magnus` | 資料庫代理(**7 埠模型**) | `33061/33062/63790/54320/14330/15210/27018` |
| chen | `jumpserver/chen` | Web 資料庫用戶端 | 內部 |
| web | `jumpserver/web` | nginx:serve lina+luna,反代 core/koko/lion/chen | 內部(由 Caddy 反代) |
| caddy | `caddy:2-alpine` | **TLS 反向代理 / 唯一 HTTP(S) 入口**,自動 Let's Encrypt | `80` / `443` |

> 設定走環境變數:core 讀 `os.environ`(`apps/jumpserver/conf.py`),故不掛 `config.yml`,全部由 `.env` 帶入。

### chen vs magnus(存取 DB 資產的兩種方式)

兩者都提供**受稽核**的資料庫存取,差別只在使用者「在瀏覽器裡查」還是「用自己的工具連」:

| | 在哪操作 | 要裝工具嗎 | 對外埠 |
|---|---|---|---|
| **chen** | JumpServer 網頁裡的 Web DB 介面(類似網頁版 DBeaver) | 不用,瀏覽器就好 | 無(走 443) |
| **magnus** | 使用者自己的 DBeaver / Navicat / `mysql` CLI,透過 JumpServer 代理連 | 要 | 33061… 那 7 個 |

常見做法是兩個都開,讓使用者自選。若確定不用原生 DB 工具直連,magnus 的 7 個埠可不對外開。

## ✅ 版本對齊(CLJUMPSERV-4,已定案)

**目標:穩定 `v4.10.18-ce`。** 調查結論(2026-08-02):

| 元件 | 用的 tag | 說明 |
|---|---|---|
| core | `jumpserver/core:v4.10.18-ce` | **官方 image**,不用 fork 的 dev HEAD |
| koko / lion / chen / web | `v4.10.18-ce` | 與 core 對齊(`COMPONENT_TAG`) |
| magnus | `v3.10.22` | magnus **無 v4 tag**,自成 v3.10.x 版本線(`MAGNUS_TAG`) |

**為什麼不用 fork 的 dev HEAD?** 本 repo dev(≈ v4.10.19-rc2 線)含上游 commit `a9689d81e`,把 Magnus 改成**單埠 5525**;但**所有已發布的 magnus 都還是舊 7 埠**,單埠 magnus 元件 image 尚未發布。用 dev core 會導致 DB 代理連不通。改用 `v4.10.18-ce`(單埠變更「之前」的穩定版),core 仍是 7 埠模型,正好對上 magnus v3.10.22。

> 若日後要用單埠 5525:須等上游發布對應的 magnus image(或自 build),屆時把 core 升到含 a9689d81e 的版本、magnus 換成單埠版、compose 埠改回單一 5525。

## Magnus 7 埠(CLJUMPSERV-9)

v3.10.x magnus 為**每種 DB 一個埠**:mysql 33061 / mariadb 33062 / redis 63790 / postgresql 54320 / sqlserver 14330 / oracle 15210 / mongodb 27018。compose 已全部對外對映;各埠可在 `.env` 用 `MAGNUS_*_PORT` 調整。

## 部署步驟

在目標機、repo 根目錄執行:

```bash
./deploy/gen-env.sh    # 產 deploy/.env,自動填入隨機 secret(CLJUMPSERV-7)
# 編輯 deploy/.env:填入真實 DOMAIN 與 TLS_EMAIL(否則 up.sh 會擋)
./deploy/up.sh         # pull + up -d + 等 core healthy(CLJUMPSERV-10/11)
```

`up.sh` 做的事:pull image → `up -d` → 等 `jms_core` 變 healthy(首次啟動 core 會自動跑
DB migrate,並由 data migration 建預設管理員)。完成後印出登入資訊。

**預設管理員:`admin` / `ChangeMe`——登入後立刻改密碼。** 需要重設:

```bash
docker compose -f deploy/docker-compose.yml exec core bash -lc "cd apps && python manage.py changepassword admin"
```

## TLS / 反向代理(CLJUMPSERV-11,Caddy)

Caddy 是唯一對外入口(80/443),`web` 容器改成內部服務不再對外發布。Caddy 自動向 Let's Encrypt
申請並續約 `DOMAIN` 的憑證,http 自動轉 https,並透通轉發 WebSocket(web terminal 需要)。

**前置(上線前必備):**
1. DNS:`DOMAIN` 的 A/AAAA 記錄要先指到這台機器。
2. 防火牆:對外開 **80 + 443**(80 供 ACME HTTP-01 challenge 與轉址)。
3. `.env` 的 `DOMAIN` / `TLS_EMAIL` 填真值(勿留 `example.com`)。

憑證存在 `caddy_data` volume,**務必納入備份(CLJUMPSERV-13)**,避免重建時觸發 Let's Encrypt 速率限制。
設定檔:[`Caddyfile`](./Caddyfile)。

## 備份 / 還原(CLJUMPSERV-13)

```bash
./deploy/backup.sh [BACKUP_DIR] [RETENTION_DAYS]   # 預設 ./backups、保留 14 天
```

備份內容(打包成一個 `jumpserver-backup-<時間>.tar.gz`):

| 項目 | 來源 |
|---|---|
| `db.sql.gz` | PostgreSQL `pg_dump` |
| `env.bak` | `deploy/.env`(**含 secret**) |
| `core_data.tgz` | 媒體 / 連線錄影 / static |
| `caddy_data.tgz` | Let's Encrypt 憑證(重建避免撞速率限制) |

> Redis 只是快取 / session(可重建),**不備份**。`core_data`/`caddy_data` 用 `--volumes-from`
> 直接抓容器 volume,不必知道 volume 名。備份檔含 secret,`chmod 600` 並存到異地。

排程(每天 3:00,保留 14 天):

```cron
0 3 * * *  cd /path/to/jumpserver && ./deploy/backup.sh /var/backups/jumpserver 14 >> /var/log/jms-backup.log 2>&1
```

還原(**具破壞性**,會覆蓋現有 DB / 錄影 / 憑證):

```bash
./deploy/restore.sh backups/jumpserver-backup-YYYYmmdd-HHMMSS.tar.gz --yes
```

## 監控 / 日誌(CLJUMPSERV-14)

**日誌輪替**(避免容器 log 塞爆磁碟)——設定 Docker 全域 log rotation,套用所有容器:

```bash
sudo cp deploy/monitoring/daemon.json /etc/docker/daemon.json   # json-file max-size 20m x 5
sudo systemctl restart docker && docker compose -f deploy/docker-compose.yml up -d
```

**健康 / 磁碟監控**——`monitor.sh` 檢查:任一容器非 running / unhealthy、Docker 資料碟使用率超標
(預設 85%,錄影會長)。有問題時 exit 非 0,並可選擇性打 webhook 告警:

```bash
./deploy/monitor.sh                                  # 印狀態;有問題 exit 1
DISK_THRESHOLD=90 ALERT_WEBHOOK=https://... ./deploy/monitor.sh   # 超標打 Slack/Discord webhook
```

排程(每 5 分鐘檢查一次):

```cron
*/5 * * * *  cd /path/to/jumpserver && ALERT_WEBHOOK=https://hooks... ./deploy/monitor.sh >> /var/log/jms-monitor.log 2>&1
```

> compose 每個服務都已設 healthcheck(用官方 `check` 工具),`docker compose ps` 可直接看健康狀態;
> `monitor.sh` 只是把它彙整 + 加磁碟檢查 + 告警。

## 後續(其他 Plane task)

- **CLJUMPSERV-12**:冒煙測試(登入 / SSH / RDP / DB 經 magnus / 稽核錄影)。
- **CLJUMPSERV-14**:監控 / 日誌輪替 / healthcheck 告警。
