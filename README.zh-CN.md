# Taurus Stack

<div align="center">

**分布式运维管理平台**

[English](README.md) | [中文](README.zh-CN.md)

[![License](https://img.shields.io/badge/license-AGPLv3-blue.svg)](LICENSE)
[![Python Version](https://img.shields.io/badge/python-3.12+-blue.svg)](https://www.python.org/)
[![Vue Version](https://img.shields.io/badge/vue-3.2+-green.svg)](https://vuejs.org/)
[![TypeScript](https://img.shields.io/badge/typescript-4.9+-blue.svg)](https://www.typescriptlang.org/)
[![官网门户](https://img.shields.io/badge/Website-taurus--portal-teal.svg)](https://taurus-stack.github.io/taurus-portal/)

</div>

---

## 项目简介

Taurus Stack 是一套完整的分布式运维管理系统（堡垒机 / 运维管理平台），用于远程主机管理、命令执行、系统健康监控。提供安全、可扩展、高可靠的基础设施管理能力。

---

## 功能截图

### 仪表盘 & 主机管理

| 首页仪表盘                               |
|:-----------------------------------:|
| [![首页](img/home.png)](img/home.png) |
|                                     |
|                                     |
|                                     |

### 任务管理

| 任务管理                                                      | 任务执行详情                                                        | 任务节点执行详情                                                                  |
|:---------------------------------------------------------:|:-------------------------------------------------------------:|:-------------------------------------------------------------------------:|
| [![任务管理](img/job-management.png)](img/job-management.png) | [![任务执行详情](img/job-exec-detail.png)](img/job-exec-detail.png) | [![任务节点执行详情](img/job-node-exec-detail.png)](img/job-node-exec-detail.png) |

| 执行记录                                                            | 执行日志                                                    | 运行详情                                              | 重新运行                                    |
|:---------------------------------------------------------------:|:-------------------------------------------------------:|:-------------------------------------------------:|:---------------------------------------:|
| [![执行记录](img/execution-records.png)](img/execution-records.png) | [![执行日志](img/execution-log.png)](img/execution-log.png) | [![运行详情](img/run-detail.png)](img/run-detail.png) | [![重新运行](img/rerun.png)](img/rerun.png) |

### 脚本与命令

| 脚本库                                                      | 运行脚本                                              | 程序命令                                                          | 运行命令                                                |
|:--------------------------------------------------------:|:-------------------------------------------------:|:-------------------------------------------------------------:|:---------------------------------------------------:|
| [![脚本库](img/script-library.png)](img/script-library.png) | [![运行脚本](img/run-script.png)](img/run-script.png) | [![程序命令](img/program-commands.png)](img/program-commands.png) | [![运行命令](img/run-command.png)](img/run-command.png) |

### 注册

| 注册令牌                                                              |
|:-----------------------------------------------------------------:|
| [![注册令牌](img/registration-token.png)](img/registration-token.png) |

---

## 架构总览

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Taurus Stack 架构                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌──────────────┐  HTTP/REST+JWT   ┌──────────────────────────────────┐  │
│   │   Taurus Web  │ ───────────────►│        Taurus Backend              │  │
│   │   (Vue 3)     │ ◄────────────── │      (Django 4.2 + dvadmin)       │  │
│   └──────────────┘  WebSocket        │                                   │  │
│                                       └──────┬──────┬──────────────────┘  │
│                                              │      │                       │
│                     ┌────────────────────────┘      │                      │
│                     │ gRPC + mTLS                    │ HTTP + JWT           │
│   ┌──────────────┐  │                                │                      │
│   │   Taurus     │  ▼                                ▼                      │
│   │  Executor    │ ◄───────────────────────┐     ┌──────────────┐         │
│   │  (gRPC)      │ ───────────────────────►│     │ Taurus Auth  │         │
│   └──────────────┘                         │     │ (票据服务)    │         │
│                                             │     └──────────────┘         │
│   ┌──────────────┐  HTTP(心跳)             │                                │
│   │   Taurus     │ ◄───────────────────────┘                                │
│   │ Supervisor   │  (asyncio 守护)                                           │
│   └──────────────┘                                                          │
│                                                                             │
│   ┌──────────────┐              Redis Queue              ┌──────────────┐  │
│   │   Taurus     │ ─────────────────────────────────────►│ Taurus Backend│  │
│   │  Scheduler   │   APScheduler + Leader 选举           │ (run_scheduler│  │
│   │ (独立服务)    │                                        │  _worker)     │  │
│   └──────────────┘                                        └──────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 通信协议

| 链路                   | 协议              | 鉴权                   | 用途        |
| -------------------- | --------------- | -------------------- | --------- |
| Web → Backend        | HTTP/REST + JWT | HMAC-SHA256 签名 Token | 管理 API    |
| Backend ↔ Executor   | gRPC + mTLS     | 双向 TLS 证书            | 远程命令执行    |
| Backend ↔ Supervisor | HTTP + 签名       | HMAC-SHA256 请求签名     | 心跳 + 程序控制 |
| Backend ↔ Auth       | HTTP + JWT      | 服务密钥签发 JWT           | 一次性执行票据验证 |
| Scheduler → Backend  | Redis Queue     | Redis Auth           | 定时任务派发    |

---

## 仓库结构

根仓库是 **git submodule 聚合仓库**，各服务独立仓库、独立版本、独立 `.gitignore`。

```
taurus-stack/                          ← 根仓库（submodule 聚合）
├── .gitmodules                        ← submodule 定义
├── README.md / README.zh-CN.md        ← 你在这里
├── docs/                              ← 跨仓库设计文档
│
├── taurus-backend/  🔧 git submodule  ← Django 4.2 + dvadmin (API 服务)
│   ├── application/                   ← Django 项目配置
│   ├── taurus/                        ← 业务逻辑
│   │   └── serializers.py / views.py
│   └── certs/                         ← CA 证书（gitignored）
│
├── taurus-web/      🔧 git submodule  ← Vue 3 + TS + Element Plus + fast-crud
├── taurus-executor/ 🔧 git submodule  ← Python + gRPC 远程执行器
├── taurus-supervisor/ 🔧 git submodule ← asyncio 主机守护
├── taurus-auth/     🔧 git submodule  ← Django 票据鉴权服务
└── taurus-scheduler/ 🔧 git submodule ← APScheduler 独立调度服务
```

### 克隆完整项目

```bash
# 递归克隆所有 submodule
git clone --recurse-submodules https://github.com/taurus-ops/taurus-stack.git
cd taurus-stack

# 更新 submodule 到最新
git submodule update --remote --recursive

# 各 submodule 远程地址见 .gitmodules
```

---

## 快速开始

### 前置要求

| 工具 | 版本 | 说明 |
| --- | --- | --- |
| conda `taurus` 环境 | Python 3.12.x | 所有 Python 服务统一走此环境 |
| MySQL | 8.0+ | backend + auth + scheduler 共享 |
| Redis | 7.2+ | 缓存 + 调度队列（DB 隔离见下） |
| Poetry | 最新 | Python 依赖管理 |
| pnpm | 10.x | 前端依赖（`package.json` 已固定版本） |

### 一键启动（推荐）

```bash
# 0. 克隆（带 submodule）
git clone --recurse-submodules https://github.com/taurus-ops/taurus-stack.git
cd taurus-stack

# 1. 初始化（install + migrate + init，首次运行或清理后）
./scripts/dev.sh --init

# 2. 启动最小链路（backend + WS + auth + web，三个后台进程）
./scripts/dev.sh

# 或完整链路（再加 scheduler + scheduler-worker）
./scripts/dev.sh --all
```

启动完成后浏览器打开 `http://localhost:3000`，默认账号 **superadmin / admin123456**。

### VS Code 一键调试（launch.json）

根目录 `.vscode/launch.json` 预置了以下组合配置，直接 F5：

| 配置名 | 包含 |
| --- | --- |
| 🚀 完整开发环境 | backend + WebSocket |
| 🚀 完整开发环境 + 定时任务 | backend + WS + scheduler + scheduler-worker |
| 🌐 全栈开发 | backend + WS + web |
| 🌐 全栈开发 + 定时任务 | backend + WS + web + scheduler + worker |
| 🔐 票据鉴权开发 | backend + auth + executor |

### 手动启动（想了解每一步时用）

需要 **4 个终端**，每个跑一个服务：

```bash
# ===== 终端 1：backend（端口 8000）+ WebSocket（端口 8765）=====
conda activate taurus
cd taurus-backend
poetry install
cp conf/env.example.py conf/env.py          # 填写 MySQL / Redis / 密钥
poetry run python manage.py migrate
poetry run python manage.py init            # 初始化菜单 / 角色 / superadmin
poetry run python manage.py runserver 0.0.0.0:8000

# 同目录另开一个：WebSocket 是必选组件
poetry run python manage/run_websocket_server.py

# ===== 终端 2：auth（端口 8001）=====
conda activate taurus
cd taurus-auth
poetry install
cp .env.example .env                        # 与 backend 共享 BACKEND_JWT_SECRET
poetry run python manage.py migrate
poetry run python manage.py runserver 0.0.0.0:8001

# ===== 终端 3：web（端口 3000）=====
cd taurus-web
pnpm install
pnpm run dev

# ===== 终端 4：（可选）scheduler + worker =====
conda activate taurus
cd taurus-scheduler
cp .env.example .env                        # Redis DB 必须是 2
poetry install && python -m scheduler.main

cd taurus-backend
poetry run python manage.py run_scheduler_worker --workers 4
```

### 验证

```bash
# 健康检查
curl http://localhost:8000/api/health/      # backend
curl http://localhost:8001/health/          # auth
curl http://localhost:9101/health            # scheduler（启动后）

# Swagger / Redoc
open http://localhost:8000/api/schema/swagger-ui/

# 前端
open http://localhost:3000                  # superadmin / admin123456
```

### 各链路最小依赖

| 想做什么 | 必须启动 |
| --- | --- |
| 看前端界面 / 管理数据 | backend + WS + auth + web |
| 跑定时任务 | 最小链路 + scheduler + scheduler-worker |
| 跑远程命令 | 最小链路 + executor（需要 mTLS 证书） |
| 跑受管程序 | 最小链路 + executor + supervisor |
| 纯 API 开发测试 | backend（auth 可选，票据功能才需要） |

### Docker Compose

```bash
# 一键起全栈（含 MySQL + Redis + 所有应用）
docker compose up -d --build
docker compose logs -f taurus-backend

# 单独起 scheduler（独立 compose 文件）
docker compose -f docker-compose.scheduler.yml up -d
```

### 常见坑

| 症状 | 原因 | 解决 |
| --- | --- | --- |
| backend 启动报 `ModuleNotFoundError: taurus_auth` | conda 环境没激活 | `conda activate taurus` 再跑 |
| executor 报 `cannot import executor_core` | 没加 PYTHONPATH | `export PYTHONPATH=$PWD/src` |
| scheduler Redis 连不上 | DB 用了 1 不是 2 | 改 `.env` 里 `REDIS_DB=2` |
| superadmin 密码登不上 | init 前已有数据库 | `python manage.py init -Y` 重置后再登 |
| auth 票据签发失败 | `BACKEND_JWT_SECRET` 与 backend 不一致 | 两边 `.env` / `conf/env.py` 用同一个值 |

> 详细的各子项目环境变量、目录结构、mTLS 证书生成见 [docs/developer-guide.zh-CN.md](docs/developer-guide.zh-CN.md)。

---

## 开发者指南

> 一键调试：根目录 [.vscode/launch.json](.vscode/launch.json) 预置了各服务及组合启动配置（如"完整开发环境"、"全栈开发 + 定时任务"），VS Code 中直接 F5 即可。以下为等价的命令行方式。

### 服务端口速查

| 服务               | 端口          | 入口 / 健康检查                          |
| ---------------- | ----------- | ---------------------------------- |
| taurus-web       | 3000        | Vite Dev Server（生产由 nginx 提供，80）   |
| taurus-backend   | 8000        | Swagger: `/api/schema/swagger-ui/` |
| taurus-auth      | 8001        | 健康检查: `/health/`                   |
| taurus-websocket | 8765        | WebSocket 服务                       |
| taurus-executor  | 50051       | gRPC + mTLS                        |
| taurus-scheduler | 9101        | 健康检查: `/health`                    |
| MySQL / Redis    | 3306 / 6379 | backend + auth + scheduler 共享      |

### 各服务速查（详细开发指南见 [docs/developer-guide.zh-CN.md](docs/developer-guide.zh-CN.md)）

| 服务               | 启动入口                                                                                                          | 关键依赖                     | 测试命令                             |
| ---------------- | ------------------------------------------------------------------------------------------------------------- | ------------------------ | -------------------------------- |
| backend          | `poetry run python manage.py runserver 0.0.0.0:8000`                                                          | MySQL + Redis            | `poetry run pytest tests/`       |
| backend WS（必选）   | `poetry run python manage/run_websocket_server.py`                                                            | —                        | —                                |
| scheduler worker | `poetry run python manage.py run_scheduler_worker --workers 4`                                                | Redis DB2                | —                                |
| auth             | `poetry run python manage.py runserver 0.0.0.0:8001`                                                          | MySQL + Redis + MACAROON | `poetry run pytest --cov=ticket` |
| web              | `pnpm run dev`                                                                                                | pnpm                     | `pnpm run test`                  |
| executor         | `PYTHONPATH=src TAURUS_SERVER_URL=http://localhost:8000 TAURUS_HOST_UUID=<uuid> python -m executor_core.main` | mTLS 证书                  | `poetry run pytest tests/unit/`  |
| supervisor       | `PYTHONPATH=$PWD python -m taurus_supervisor.main`                                                            | asyncio                  | `poetry run pytest`              |
| scheduler        | `PYTHONPATH=$PWD python -m scheduler.main`                                                                    | Redis DB2（DB 只读）         | `poetry run pytest`              |

### 开发约定摘要

| 主题        | 约定                                                                            |
| --------- | ----------------------------------------------------------------------------- |
| Python 依赖 | 统一 Poetry，禁止 `pip install`（新增依赖用 `poetry add`）                                |
| Python 环境 | conda `taurus` 环境，Python 3.12.x                                               |
| 前端依赖      | pnpm，lock 文件必须提交                                                              |
| 命名        | 文件/变量 `snake_case`，类 `PascalCase`，常量 `UPPER_SNAKE_CASE`；模型字段 verbose_name 用中文 |
| 测试命名      | `test_<场景>_<预期行为>`，核心逻辑覆盖率 ≥ 80%                                              |
| Commit    | Conventional Commits（`feat(scope): ...`）                                      |
| 密钥与配置     | 只提交 `*.example` 模板；`conf/env.py`、`.env`、`certs/*.key` 永不提交                    |
| 数据库       | 变更走 Django migration，禁止手改已提交的 migration                                       |
| API 文档    | drf-spectacular 自动生成，不手写                                                      |

### 代码修改去向

| 想改什么           | 仓库                |
| -------------- | ----------------- |
| API、Model、业务逻辑 | taurus-backend    |
| UI、组件、页面       | taurus-web        |
| 远程执行、gRPC 协议   | taurus-executor   |
| 主机守护、心跳、程序管理   | taurus-supervisor |
| 票据鉴权、JWT       | taurus-auth       |
| 定时任务派发、HA 选举   | taurus-scheduler  |

完整的多仓库开发工作流（分支策略、PR 流程、submodule 指针更新）见 [CONTRIBUTING.zh-CN.md](CONTRIBUTING.zh-CN.md)。

---

## 安全机制

### 证书管理

```
taurus-backend/certs/           (gitignored — 绝不提交密钥)
├── ca.crt                      # CA 证书（公开可分发）
├── ca.key                      # ⚠️ CA 私钥（离线保存！）
├── client.crt                  # 客户端证书
├── client.key                  # ⚠️ 客户端私钥
└── openssl.cnf                 # OpenSSL 配置
```

### 环境变量

| 变量                           | 作用                | 说明                         | 默认                         |
| ---------------------------- | ----------------- | -------------------------- | -------------------------- |
| `AUTH_SERVICE_URL`           | Backend/Auth      | 鉴权服务地址                     | `http://localhost:8001`    |
| `REDIS_URL`                  | Backend/Scheduler | Redis 连接                   | `redis://localhost:6379/0` |

---

## 文档索引

跨仓库设计文档：

- [docs/architecture.md](docs/architecture.md) — 系统架构、协议、数据流
- [docs/developer-guide.zh-CN.md](docs/developer-guide.zh-CN.md) — 各子项目开发指南（目录结构、环境变量、启动/测试命令）
- [CONTRIBUTING.md](CONTRIBUTING.md) — 多仓库开发工作流

各服务专属文档见对应仓库。

---

## 贡献

详见 [CONTRIBUTING.md](CONTRIBUTING.md) 了解多仓库开发工作流、分支策略和 Code Review 流程。

安全问题请在各子项目 `SECURITY.md` 中查看联系方式。

---

## License

GNU Affero General Public License v3.0 — 见 [LICENSE](LICENSE)

---

## 相关链接

| 服务             | 仓库                                                                   | Issue                                                         |
| -------------- | -------------------------------------------------------------------- | ------------------------------------------------------------- |
| **官网门户**       | [taurus-portal](https://github.com/taurus-stack/taurus-portal)       | [访问站点](https://taurus-stack.github.io/taurus-portal/)         |
| Backend        | [taurus-backend](https://github.com/taurus-ops/taurus-backend)       | [跟踪器](https://github.com/taurus-ops/taurus-backend/issues)    |
| Web            | [taurus-web](https://github.com/taurus-ops/taurus-web)               | [跟踪器](https://github.com/taurus-ops/taurus-web/issues)        |
| Executor       | [taurus-executor](https://github.com/taurus-ops/taurus-executor)     | [跟踪器](https://github.com/taurus-ops/taurus-executor/issues)   |
| Supervisor     | [taurus-supervisor](https://github.com/taurus-ops/taurus-supervisor) | [跟踪器](https://github.com/taurus-ops/taurus-supervisor/issues) |
| Auth           | [taurus-auth](https://github.com/taurus-ops/taurus-auth)             | [跟踪器](https://github.com/taurus-ops/taurus-auth/issues)       |
| Scheduler      | [taurus-scheduler](https://github.com/taurus-ops/taurus-scheduler)   | [跟踪器](https://github.com/taurus-ops/taurus-scheduler/issues)  |
| **Stack（本仓库）** | [taurus-stack](https://github.com/taurus-ops/taurus-stack)           | [讨论](https://github.com/taurus-ops/taurus-stack/discussions)  |