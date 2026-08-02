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
| magnus | `jumpserver/magnus` | **資料庫代理(單埠)** | `5525` |
| chen | `jumpserver/chen` | Web 資料庫用戶端 | 內部 |
| web | `jumpserver/web` | nginx:serve lina+luna,反代 core/koko/lion/chen | `80` |

> 設定走環境變數:core 讀 `os.environ`(`apps/jumpserver/conf.py`),故不掛 `config.yml`,全部由 `.env` 帶入。

## ⚠️ 版本對齊(CLJUMPSERV-4,務必先做)

本 repo core 是上游 `dev`(`VERSION=2.0.0`,Python 3.14 / Django 4.1,前沿)。周邊元件 image tag 必須與 core **相容**,否則註冊失敗或協定不通。

- `CORE_IMAGE`:用本 repo build 的 core image,或對應版本的官方 core image。
- `COMPONENT_TAG`:koko/lion/magnus/chen/web 的 tag,須對齊 core。`.env.example` 先填 `v2.0.0` 佔位——**上線前確認實際可用的相容 tag**。

## Magnus 單埠(CLJUMPSERV-9)

上游 commit `a9689d81e` 把 Magnus 從「每種 DB 一個埠」改成**單一 `magnus_port`(預設 5525)**,所有 DB 協定(mysql/mariadb/postgresql/redis/sqlserver/oracle/mongodb)共用。所以只對外開一個 `5525`。migration `0011_endpoint_magnus_port` 會移除舊的 7 個埠欄位(不可逆,migrate 前備份 DB)。

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
