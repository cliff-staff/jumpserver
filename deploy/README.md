# JumpServer 單機 Docker Compose 部署

單機 `docker compose` 編排,PostgreSQL 與 Redis 自建於容器內。對應 Plane **CLJUMPSERV-8**。

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
| web | `jumpserver/web` | nginx:serve lina+luna,反代 core/koko/lion/chen | `80` |

> 設定走環境變數:core 讀 `os.environ`(`apps/jumpserver/conf.py`),故不掛 `config.yml`,全部由 `.env` 帶入。

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

```bash
cp deploy/.env.example deploy/.env
# 產 secret 並填入 deploy/.env(指令見 .env.example 註解)

docker compose -f deploy/docker-compose.yml up -d          # 啟動(CLJUMPSERV-10)
docker compose -f deploy/docker-compose.yml ps             # 確認各容器 healthy
docker compose -f deploy/docker-compose.yml logs -f core   # core 首次啟動會自動 DB migrate
```

建立管理員(若 image 未自動建):

```bash
docker compose -f deploy/docker-compose.yml exec core bash -lc "cd apps && python manage.py createsuperuser"
```

## 後續(其他 Plane task)

- **CLJUMPSERV-11**:前面架 nginx/caddy 反代到 `web:80` + Let's Encrypt TLS,強制 https、轉發 websocket。
- **CLJUMPSERV-12**:冒煙測試(登入 / SSH / RDP / DB 經 magnus / 稽核錄影)。
- **CLJUMPSERV-13**:備份 `pg_data`、`.env`、`core_data`(錄影/上傳)。
