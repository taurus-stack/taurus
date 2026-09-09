# Taurus Stack 开发指南

> 每个子项目的环境搭建、目录结构、启动/测试命令、关键配置一目了然。
> 一键调试：根目录 `.vscode/launch.json` 预置了各服务及组合启动配置，VS Code 中直接 F5 即可。
> 以下为等价的命令行方式。

---

## 通用前置条件

| 工具                | 版本                        | 用途                            |
| ----------------- | ------------------------- | ----------------------------- |
| conda `taurus` 环境 | Python 3.12.x             | 所有 Python 服务统一走此环境            |
| Poetry            | 最新                        | Python 依赖管理                   |
| pnpm              | 10.x（packageManager 字段固定） | 前端依赖管理                        |
| MySQL             | 8.0+                      | backend + auth + scheduler 共享 |
| Redis             | 7.2+                      | 缓存 + 调度队列 + 分布式锁              |

```bash
conda activate taurus
poetry config virtualenvs.in-project false   # 全局虚拟环境
```

---

## taurus-backend

**定位**：核心 API 服务（Django 4.2 + dvadmin），提供主机管理、命令执行、工作流、定时任务等业务 API。端口 8000（API）+ 8765（WebSocket）。

### 目录结构

```
taurus-backend/
├── application/          # Django 项目配置（settings / urls / celery / wsgi）
├── conf/                 # 环境配置（env.py，gitignored；env.example.py 为模板）
├── taurus/               # 核心业务 app
│   ├── models.py         # Host / Task / Workflow / Program ...
│   ├── views.py          # ViewSets（前缀 api/taurus/）
│   ├── serializers.py
│   ├── workflow/         # 工作流引擎
│   ├── sdk/              # gRPC client SDK
│   ├── utils/            # 工具函数（auth / gRPC / 加密）
│   ├── management/       # Django management commands
│   └── tasks.py          # Celery 异步任务（当前调度链路已走 taurus-scheduler，保留兼容）
├── dvadmin/              # ⚠️ 框架代码，不要直接修改
├── certs/                # mTLS 证书（*.key 永不提交）
├── db/                   # 数据库 dump / 迁移脚本
├── logs/                 # 运行日志
├── manage.py
└── pyproject.toml
```

### 技术栈

Django 4.2 + DRF + dvadmin（RBAC / 菜单 / 字典）+ PyMySQL + Redis + JWT + drf-spectacular + Cryptography（Fernet 加密）+ OpenSSL（mTLS）。

### 环境变量（`conf/env.py`）

| 变量                                                                                          | 说明                           | 示例                                   |
| ------------------------------------------------------------------------------------------- | ---------------------------- | ------------------------------------ |
| `DATABASE_HOST` / `DATABASE_PORT` / `DATABASE_USER` / `DATABASE_PASSWORD` / `DATABASE_NAME` | MySQL 连接                     | `taurus_backend` / 前缀 `taurus_`      |
| `REDIS_HOST` / `REDIS_PORT` / `REDIS_PASSWORD` / `REDIS_URL`                                | Redis（DB1）                   | `redis://localhost:6379/1`           |
| `TAURUS_AUTH_URL`                                                                           | 指向 taurus-auth 服务            | `http://localhost:8001`              |
| `TAURUS_SCHEDULER_QUEUE`                                                                    | 调度 Worker 消费的 Redis 队列 Key   | `taurus:scheduler:queue:script_task` |
| `REDIS_URL_SCHEDULER`                                                                       | Scheduler Worker 用的 Redis DB | `redis://localhost:6379/2`           |
| `SECRET_KEY`                                                                                | Django 密钥                    | 随机生成                                 |

### 启动

```bash
conda activate taurus
cd taurus-backend
poetry install
cp conf/env.example.py conf/env.py    # 编辑上述变量
poetry run python manage.py migrate
poetry run python manage.py init      # 初始化系统数据（仅首次）
poetry run python manage.py runserver 0.0.0.0:8000

# WebSocket 服务（必选，端口 8765）
poetry run python manage/run_websocket_server.py

# Scheduler Worker（消费调度队列，配合 taurus-scheduler 使用）
poetry run python manage.py run_scheduler_worker --workers 4
```

### 可访问端点

| URL                                            | 说明                  |
| ---------------------------------------------- | ------------------- |
| `http://localhost:8000/`                       | 404（纯 API 服务）       |
| `http://localhost:8000/api/health/`            | 健康检查                |
| `http://localhost:8000/api/schema/swagger-ui/` | Swagger UI          |
| `http://localhost:8000/api/schema/redoc/`      | Redoc               |
| `http://localhost:8000/api/taurus/`            | 所有 Taurus 业务 API 前缀 |

### 测试与 Lint

```bash
poetry run pytest tests/                        # 单元测试
poetry run python manage.py check               # Django 系统检查
poetry run ruff check . && poetry run black --check .
```

### 开发注意事项

- **dvadmin/ 不可修改**：框架代码改了升级会炸。需要扩展时在 `taurus/` 下写自定义 app。
- **mTLS 证书**：`certs/ca.key` 永不提交。CA 公钥 `ca.crt` 可提交，每次部署生成 client 证书。
- **Scheduler Worker 与 scheduler 解耦**：scheduler 进程负责 Leader 选举 + 读 DB + 推 Redis 队列；Worker 是 backend 内的 management command，负责消费队列 + 执行 + 写记录。两者可以同机部署。

---

## taurus-auth

**定位**：独立的票据鉴权服务（Django 4.2），为 executor 提供一次性执行票据验证。端口 8001。

### 目录结构

```
taurus-auth/
├── taurus_auth/          # Django 项目配置（settings.py / urls.py）
├── ticket/               # 票据业务 app（models / views / serializers / services）
│   └── utils/jwt_helper.py
├── db/                   # 数据库导入/导出脚本
├── manage.py
├── .env.example          # ← 配置模板
└── pyproject.toml
```

### 技术栈

Django 4.2 + PyMySQL + redis + macaroon + djangorestframework-simplejwt。

### 环境变量（必填项）

| 变量                                                            | 说明                     | launch.json 示例                                           |
| ------------------------------------------------------------- | ---------------------- | -------------------------------------------------------- |
| `DB_NAME` / `DB_USER` / `DB_PASSWORD` / `DB_HOST` / `DB_PORT` | 独立 auth 数据库            | `taurus_auth` / `root` / `123456` / `localhost` / `3306` |
| `REDIS_URL`                                                   | Redis 连接               | `redis://:123456@127.0.0.1:6379/1`                       |
| `BACKEND_JWT_SECRET`                                          | 与 backend 共享的 JWT 签名密钥 | 随机生成                                                     |
| `MACAROON_ROOT_KEY`                                           | Macaroon 票据根密钥         | 随机生成                                                     |
| `ALLOWED_BACKEND_IPS`                                         | 允许访问的 backend IP       | 开发阶段可设 `127.0.0.1`                                       |
| `RATELIMIT_ENABLE`                                            | 是否启用限流                 | `True`                                                   |
| `RATELIMIT_RATE`                                              | 限流速率                   | `100/m`                                                  |
| `TICKET_DEFAULT_EXPIRES_MINUTES`                              | 票据默认有效期                | `5`                                                      |
| `TICKET_MAX_EXPIRES_MINUTES`                                  | 票据最长有效期                | `60`                                                     |
| `DJANGO_SETTINGS_MODULE`                                      | 启动时需指定                 | `taurus_auth.settings`                                   |

### 启动

```bash
cd taurus-auth
poetry install
cp .env.example .env       # 编辑上述必填项
poetry run python manage.py migrate
poetry run python manage.py runserver 0.0.0.0:8001
```

健康检查：`curl http://localhost:8001/health/`

### 测试

```bash
poetry run pytest                 # 全部测试
poetry run pytest --cov=ticket    # + 覆盖率
```

### 开发注意事项

- Auth 是独立 Django 项目，`DJANGO_SETTINGS_MODULE` 与 backend 不同（`taurus_auth.settings`），启动脚本必须显式指定。
- 与 backend 共享 `BACKEND_JWT_SECRET`，否则票据签发/验证会失败。
- Macaroon 根密钥一旦生成不要更换，已签发的票据会全部失效。

---

## taurus-executor

**定位**：远程命令执行器（Python + gRPC + mTLS），部署在目标主机上，接收 backend 的执行指令。端口 50051（gRPC）。

### 目录结构

```
taurus-executor/
├── src/executor_core/    # 核心源码
│   ├── main.py           # 入口
│   ├── executors/         # 命令执行器（command / privileged）
│   ├── infra/            # 配置、TLS、日志、状态管理
│   └── services/         # gRPC Server + 拦截器（auth / CRL / ticket）
├── proto/executor/v1/    # gRPC proto 定义
├── scripts/              # 证书生成、打包脚本
├── manage/cli.py         # 调试 CLI
├── tests/                # unit/ + integration/
├── Dockerfile.dev
├── .env.example          # ← 配置模板
└── pyproject.toml
```

### 技术栈

Python 3.12 + grpcio + cryptography + pyopenssl。

### 环境变量（必填项）

| 变量                        | 说明                                      | launch.json 示例          |
| ------------------------- | --------------------------------------- | ----------------------- |
| `PYTHONPATH`              | 必须指向 `src/` 目录才能 import `executor_core` | `$PWD/src`              |
| `TAURUS_SERVER_URL`       | backend 地址                              | `http://localhost:8000` |
| `TAURUS_HOST_UUID`        | 主机在 backend 注册后分配的 UUID                 | 从后端注册接口获取               |
| `GRPC_HOST` / `GRPC_PORT` | gRPC 监听地址                               | `0.0.0.0` / `50051`     |
| `TAURUS_AUTH_URL`         | auth 服务地址（用于票据验证）                       | `http://localhost:8001` |

### 启动

```bash
cd taurus-executor
poetry install
export PYTHONPATH=$PWD/src
export TAURUS_SERVER_URL=http://localhost:8000
export TAURUS_HOST_UUID=<从 backend 注册后获取>
python -m executor_core.main
```

### mTLS 证书生成

executor 与 backend 之间用 gRPC + mTLS 通信，需要三级证书：

```
CA 证书（taurus-backend/certs/ca.crt + ca.key）
├── executor 服务器证书（server.crt + server.key）← executor 自己持有
└── SDK 客户端证书（client.crt + client.key）      ← 给 SDK/CLI 连接 executor 时用
```

#### 第一步：确保 CA 存在（taurus-backend）

CA 证书由 backend 的 `CAManager.ensure_ca_exists()` 自动生成，存放在 `taurus-backend/certs/`：

```bash
# backend 首次启动时会自动触发；也可以手动调用：
cd taurus-backend
poetry run python -c "from taurus.ca_manager import CAManager; CAManager('certs').ensure_ca_exists()"
```

生成产物：

| 文件 | 用途 | gitignore |
| --- | --- | --- |
| `certs/ca.key` | ⚠️ CA 私钥，**绝不分发** | ✅ |
| `certs/ca.crt` | CA 公钥证书，可提交、可分发 | ❌ |

#### 第二步：生成 executor 服务器证书

三种方式任选其一：

**方式 A — 开发环境（本地脚本直接签，最快）**

```bash
cd taurus-executor
./scripts/generate_dev_server_cert.sh
# 默认加 SAN: DNS:taurus-grpc-server, DNS:localhost, IP:127.0.0.1
# 可选参数：./scripts/generate_dev_server_cert.sh [证书名] [有效期天数]
```

产物：`taurus-executor/tls/server.crt` + `server.key` + `ca.crt`（从 backend 拷过来）

**方式 B — 生产/重签（用 openssl.cnf 带完整扩展）**

```bash
cd taurus-executor
# 默认 365 天，自定义：GRPC_SERVER_NAME=executor-host-01 ./scripts/regenerate_executor_cert.sh 730
./scripts/regenerate_executor_cert.sh
```

与方式 A 的区别：用 `openssl ca -config openssl.cnf` 签（而非 `openssl x509 -req`），会写入 CA 数据库（`index.txt` / `serial`），便于证书溯源和后续 CRL 管理。

**方式 C — 后端 API 签发（生产部署走注册流程）**

executor 注册时向后端提交 CSR，后端 `CAManager.sign_server_csr()` 在线签发。这是主机大规模部署时的标准流程，不需要手动跑脚本。

#### 第三步：让 executor 加载证书

证书放在 `taurus-executor/tls/` 下时自动识别；也可以通过环境变量显式指定：

```bash
export TLS_CERT_PATH=$PWD/tls/server.crt
export TLS_KEY_PATH=$PWD/tls/server.key
export TLS_CA_PATH=$PWD/tls/ca.crt
python -m executor_core.main
```

#### 第四步（可选）：生成 SDK 客户端证书

用 Python SDK / CLI 连接 executor 时需要客户端证书（双向 TLS）：

```bash
cd taurus-executor
./scripts/generate_sdk_cert.sh
# 可选参数：./scripts/generate_sdk_cert.sh [证书名] [有效期天数]
```

产物：`taurus-executor/certs/sdk/taurus-sdk.crt` + `taurus-sdk.key` + `ca.crt`

使用示例：

```python
import grpc

with open("tls/ca.crt", "rb") as f:
    ca_cert = f.read()
with open("certs/sdk/taurus-sdk.crt", "rb") as f:
    client_cert = f.read()
with open("certs/sdk/taurus-sdk.key", "rb") as f:
    client_key = f.read()

credentials = grpc.ssl_channel_credentials(
    root_certificates=ca_cert,
    private_key=client_key,
    certificate_chain=client_cert,
)
# ssl_target_name_override 绕过 IP 直接连时的 SAN 匹配：
channel = grpc.secure_channel("10.0.1.123:50051", credentials, options=[
    ("grpc.ssl_target_name_override", "taurus-grpc-server"),
])
```

#### 证书校验

```bash
# 验证服务器证书被 CA 信任
openssl verify -CAfile tls/ca.crt tls/server.crt

# 查看 SAN 扩展
openssl x509 -in tls/server.crt -noout -ext subjectAltName

# 用 SDK 证书连 executor 测试
python -m manage.cli --address localhost:50051 --cert tls/server.crt --key tls/server.key --ca tls/ca.crt status
```

#### 安全红线

- **`ca.key` 永不出 `taurus-backend/certs/`**，不要拷到 executor 或任何客户端主机。
- `server.key` / `taurus-sdk.key` 设置 `chmod 600`，不要提交 git。
- `*.crt` 公钥证书可自由分发，`ca.crt` 必须与所有客户端共享以建立信任链。
- 证书续期用 `regenerate_executor_cert.sh`（走 `openssl ca` 留痕），不要直接用 `generate_dev_server_cert.sh` 覆盖。

#### Docker 场景证书挂载

根目录 `docker-compose.yml` 已用只读挂载把证书目录映射进容器，**宿主机生成证书 → 容器自动读取**，无需 rebuild 镜像：

| 服务 | 宿主机目录 | 容器内路径 | 说明 |
| --- | --- | --- | --- |
| taurus-backend | `./taurus-backend/certs` | `/app/certs:ro` | CA 公钥 `ca.crt`（被所有服务共享） |
| taurus-websocket | `./taurus-backend/certs` | `/app/certs:ro` | 同 backend |
| taurus-workflow-scheduler | `./taurus-backend/certs` | `/app/certs:ro` | 同 backend |
| taurus-scheduler-worker | `./taurus-backend/certs` | `/app/certs:ro` | 消费队列执行时要用 gRPC 连 executor |
| taurus-executor | `./taurus-executor/tls` | `/opt/taurus-executor/tls:ro` | 服务器证书 `server.crt` + `server.key` + `ca.crt` |

> `:ro` 只读：容器内只能读证书，防止被篡改。路径必须保持 compose 里声明的固定位置，因为在 `Dockerfile` 中已经写死了读取目录。

**Docker 场景证书生成顺序：**

```bash
# 1. CA（本地 backend 或首次 compose 启动自动生成）→ taurus-backend/certs/ca.{crt,key}
poetry run python -c "from taurus.ca_manager import CAManager; CAManager('certs').ensure_ca_exists()"

# 2. 生成 executor 服务器证书 → taurus-executor/tls/server.{crt,key} + 拷贝 ca.crt
cd taurus-executor
./scripts/generate_dev_server_cert.sh   # 产物在 tls/ 下
# 确认目录里同时有 server.crt + server.key + ca.crt

# 3. compose 启动，证书以只读方式挂进容器
docker compose up -d taurus-executor

# 4. 验证容器内证书就位
docker exec taurus-executor ls -l /opt/taurus-executor/tls/
docker exec taurus-executor openssl verify -CAfile /opt/taurus-executor/tls/ca.crt \
  /opt/taurus-executor/tls/server.crt
```

**SAN 关键点（Docker 最容易踩的坑）：**

`generate_dev_server_cert.sh` 默认 SAN 只含 `localhost` + `127.0.0.1`，但在 compose 网络里 executor 通过**服务名**被访问，SAN 匹配会失败。两种解法：

- **方案 A（推荐）**：开发时用 `GRPC_SERVER_NAME` 指定服务名重新生成证书：
  ```bash
  GRPC_SERVER_NAME=taurus-executor ./scripts/regenerate_executor_cert.sh
  ```
- **方案 B**：客户端不校验 SAN —— 仅限调试：
  ```bash
  # 用 ssl_target_name_override 绕过（Python SDK 侧），见上方 SDK 示例
  ```

**supervisor 的特殊情况：**

`docker-compose.yml` 里 `taurus-supervisor` 通过 `network_mode: "service:taurus-executor"` + `pid: "service:taurus-executor"` 与 executor 共享网络/进程命名空间，**复用 executor 的 mTLS 通道**对外通信（经 backend 的 `HTTP + 签名`，不经 gRPC），因此 supervisor 容器**不需要**自己的 TLS 证书挂载——只有 executor 那份即可。

### 调试 CLI

```bash
python -m manage.cli --address localhost:50051 status
python -m manage.cli --address localhost:50051 exec "ls -la"
```

### 测试

```bash
poetry run pytest tests/unit/          # 单元测试（无需真实 backend）
poetry run pytest tests/integration/    # 集成测试（需要 backend + auth）
```

### 开发注意事项

- **PYTHONPATH 陷阱**：源码在 `src/` 下，`poetry run` 不会自动加这个路径，必须手动 export。VS Code launch.json 里显式配置了，命令行跑时记得加。
- proto 变更后需重新生成 Python 代码：`scripts/process_grpc_files.py`。
- 证书生成详见上一节"mTLS 证书生成"，开发用方式 A，生产走方式 B 或 C。

---

## taurus-supervisor

**定位**：主机守护进程（Python + asyncio），管理 executor 进程生命周期、心跳上报、受管程序启停。

### 目录结构

```
taurus-supervisor/
├── taurus_supervisor/     # 守护进程核心
│   ├── main.py            # 入口
│   ├── heartbeat.py       # 心跳上报
│   ├── program_manager.py # 受管程序启停
│   └── log_forwarder.py   # 日志转发
├── taurus_pm/             # 独立的 pm CLI
├── templates/systemd/     # systemd 服务模板
├── templates/supervisor.env.example  # ← 配置模板
├── scripts/               # register / build / uninstall
└── pyproject.toml
```

### 技术栈

Python 3.12 + asyncio + httpx + structlog。

### 环境变量

| 变量                              | 说明                                     | launch.json 示例                     |
| ------------------------------- | -------------------------------------- | ---------------------------------- |
| `PYTHONPATH`                    | 指向项目根目录（才能 import `taurus_supervisor`） | `$PWD`                             |
| `BASE_DIR`                      | supervisor 运行时数据目录                     | `~/taurus`                         |
| `SERVER_URL`                    | backend 地址                             | `http://localhost:8000`            |
| `HOST_ID`                       | 主机标识（UUID）                             | 与 executor 的 `TAURUS_HOST_UUID` 对应 |
| `SUPERVISOR_HEARTBEAT_INTERVAL` | 心跳间隔秒                                  | `10`                               |
| `HEALTH_CHECK_INTERVAL`         | 健康检查间隔秒                                | `10`                               |
| `LOG_DIR`                       | 日志目录                                   | `~/taurus/logs`                    |
| `SSL_VERIFY`                    | 是否验证证书（开发可关闭）                          | `false`                            |
| `CONFIG_ENCRYPTION_ENABLED`     | 配置加密                                   | `false`                            |
| `REQUEST_SIGNING_SECRET`        | 与 backend 签名验证用                        | 开发可留空                              |

### 启动

```bash
cd taurus-supervisor
poetry install
export PYTHONPATH=$PWD
export BASE_DIR=~/taurus
python -m taurus_supervisor.main
```

### 测试

```bash
poetry run pytest    # pytest + pytest-asyncio
```

### 开发注意事项

- Supervisor 与 Executor 通常部署在同一台主机，共享 PID/Network namespace（docker-compose 里 `pid: "service:taurus-executor"`）。
- 心跳用 HTTP + HMAC 签名，开发时如果 backend 未配置 `REQUEST_SIGNING_SECRET`，可以在 supervisor 里也留空跳过签名。

---

## taurus-scheduler

**定位**：独立调度服务（Python + APScheduler + FastAPI），负责读取 DB 中 ScriptTask、Leader 选举、派发任务到 Redis 队列。健康检查端口 9101。

### 目录结构

```
taurus-scheduler/
├── scheduler/
│   ├── main.py            # 入口（调度引擎 + 健康检查 API 一起启动）
│   ├── engine.py          # APScheduler 引擎 + Leader 选举
│   ├── dispatcher.py      # 派发任务到 Redis 队列
│   ├── lock.py            # Redis 分布式锁
│   ├── store.py           # MySQL 只读（轮询 ScriptTask）
│   ├── config.py          # pydantic-settings 配置
│   ├── health_api.py      # FastAPI 健康检查端点
│   └── logging_config.py
├── .env.example           # ← 配置模板
├── Dockerfile
└── pyproject.toml
```

### 技术栈

Python 3.12 + apscheduler + PyMySQL + redis + fastapi + uvicorn + prometheus-client + structlog。

### 环境变量

| 变量                                                                                | 说明                        | launch.json 示例                       |
| --------------------------------------------------------------------------------- | ------------------------- | ------------------------------------ |
| `PYTHONPATH`                                                                      | 指向项目根目录                   | `$PWD`                               |
| `SCHEDULER_INSTANCE_ID`                                                           | 实例标识（用于 Leader 选举）        | `dev-local-01`                       |
| `DB_HOST` / `DB_PORT` / `DB_USER` / `DB_PASSWORD` / `DB_NAME` / `DB_TABLE_PREFIX` | 只读访问 backend 的同一个 MySQL 库 | `taurus_backend` / 前缀 `taurus_`      |
| `REDIS_HOST` / `REDIS_PORT` / `REDIS_PASSWORD` / `REDIS_DB`                       | Redis 配置                  | **DB=2**（跟其他服务错开），密码用占位符             |
| `REDIS_QUEUE_KEY`                                                                 | 任务队列 Key                  | `taurus:scheduler:queue:script_task` |
| `REDIS_DEDUP_PREFIX`                                                              | 去重前缀                      | `taurus:scheduler:dedup:`            |
| `REDIS_LOCK_PREFIX`                                                               | Leader 锁前缀                | `taurus:scheduler:lock:`             |
| `BACKEND_API_BASE_URL`                                                            | 兜底回调（队列不可达时 HTTP 回推）      | `http://localhost:8000`              |
| `HEALTH_HOST` / `HEALTH_PORT`                                                     | 健康检查监听                    | `0.0.0.0` / `9101`                   |
| `TIMEZONE`                                                                        | 时区                        | `Asia/Shanghai`                      |

### 启动

```bash
cd taurus-scheduler
poetry install
export PYTHONPATH=$PWD
python -m scheduler.main
```

健康检查：`curl http://localhost:9101/health`

### 测试

```bash
poetry run pytest    # pytest + pytest-asyncio
```

### 通信安全（不需要 mTLS）

Scheduler **不经过 gRPC，也不需要 mTLS 证书**——它只有三条通信通道，均非 TLS/gRPC：

| 通道 | 协议 | 安全模型 | 说明 |
| --- | --- | --- | --- |
| MySQL | TCP（Django ORM） | 数据库账号口令 + 网络隔离 | 只读 `ScriptTask` |
| Redis | TCP | Redis 密码 + 网络隔离 | DB=2，队列/锁/去重 |
| backend 兜底回调 | HTTP(S) | 可选 `BACKEND_API_TOKEN` | 队列不可达时回推，Token 见 `.env.example` 的 `BACKEND_API_TOKEN` |

gRPC + mTLS 只存在于 **executor ↔ backend** 链路（见 taurus-executor 章节）。如果你部署时希望对 scheduler 的 HTTP 回调做鉴权保护，配置 `BACKEND_API_TOKEN` 即可，无需任何证书生成步骤；如对 MySQL/Redis 传输层加密有要求，走对应的 SSL/TLS 连接串，这属于数据库侧配置，与 executor 那套 CA/证书体系无关。

### 配套：Scheduler Worker

Scheduler 把任务塞进 Redis 队列后，由 backend 内的 worker 消费并执行：

```bash
cd taurus-backend
poetry run python manage.py run_scheduler_worker --workers 4
```

### 开发注意事项

- **Redis DB 必须是 2**：backend 用 1（缓存），auth 用 1（票据），scheduler 专属 2。
- Scheduler 对 MySQL 是**只读**访问（`ScriptTask` 表），执行记录写回由 worker（在 backend 进程里）完成。
- 多实例部署时 Leader 选举自动生效，单实例时 `SCHEDULER_INSTANCE_ID` 随便填。

---

## taurus-web

**定位**：前端管理界面（Vue 3 + TypeScript + Element Plus + fast-crud）。开发端口 3000，生产由 nginx 托管 80。

### 目录结构（核心）

```
taurus-web/
├── src/
│   ├── api/taurus/            # 业务 API 封装（host / ops / workflow / schedule ...）
│   ├── views/taurus/          # 业务页面（按领域分子目录）
│   │   ├── host/              # 主机管理
│   │   ├── ops/command/       # 命令执行
│   │   ├── workflow/          # 工作流
│   │   ├── schedule/          # 定时任务
│   │   └── supervisor/        # supervisor 管理
│   ├── components/workflow/   # 工作流专用组件（DAG 编辑器等）
│   ├── stores/taurus/         # Pinia 状态
│   ├── i18n/pages/            # 页面级国际化（zh-cn / en / zh-tw）
│   ├── router/                # 路由
│   └── utils/request.ts       # Axios 封装
├── .env.development           # 开发环境变量
├── .env.local_prod            # 本地生产构建环境变量
├── package.json               # pnpm 包管理器
└── vite.config.ts
```

### 技术栈

Vue 3 + TypeScript + Element Plus + fast-crud（`@fast-crud/fast-crud` + `@fast-crud/ui-element`） + Vue Flow（DAG 编辑） + Monaco Editor + ECharts。

### 启动

```bash
cd taurus-web
pnpm install         # 必须 pnpm，lock 文件已指定 pnpm@10.24.0
pnpm run dev         # http://localhost:3000
pnpm run build       # 生产构建
```

### 测试与 Lint

```bash
pnpm run test           # Vitest
pnpm run test:coverage  # + 覆盖率
pnpm run lint-fix       # ESLint --fix
```

### 开发注意事项

- **CRUD 页面统一 fast-crud**：新增一个模型的 CRUD 页面，标准套路是 `api/taurus/<domain>/api.ts`（API 封装）+ `views/taurus/<domain>/index.vue` + `crud.tsx`（CrudOptions 配置）。详见项目 `.trae/docs/fast-crud/FAST-CRUD-AI-DOC.md`。
- **组件选型**优先 Element Plus 原生组件 > fast-crud 封装组件 > 自定义组件。对话框选型见 `.trae/docs/fast-crud/dialog-usage-guide.md`。
- **禁止**使用未定义类型的 `any`；禁止 `v-html` 渲染不受控内容。
- **WebSocket 通知**：`src/utils/websocket.ts` 封装了与 taurus-backend 的实时推送，不需要手动连接。
- 业务页面国际化文案放 `src/i18n/pages/<页面目录>/zh-cn.ts`，三语对齐提交。
