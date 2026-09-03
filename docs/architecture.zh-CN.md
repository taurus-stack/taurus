# 系统架构

[English](architecture.md)

## 目录

1. [组件总览](#组件总览)
2. [通信协议](#通信协议)
3. [数据流 — 命令执行](#数据流--命令执行)
4. [数据流 — 定时任务](#数据流--定时任务)
5. [数据流 — 工作流](#数据流--工作流)
6. [安全架构](#安全架构)
7. [数据库 Schema（高层）](#数据库-schema高层)

---

## 组件总览

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Taurus Stack                                    │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌──────────────┐                                                        │
│   │   Taurus Web  │  前端管理界面                                          │
│   │   (Vue 3 + TS)│  • Element Plus UI                                    │
│   └──────┬───────┘  • fast-crud 表格/表单                                  │
│          │ HTTP/REST + JWT                                                  │
│          ▼                                                                 │
│   ┌─────────────────────────────────────────────────────────────┐          │
│   │                   Taurus Backend (Django 4.2)              │          │
│   │                                                             │          │
│   │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐ │          │
│   │  │ Edition Gate │  │  工作流引擎   │  │  调度处理器       │ │          │
│   │  │ (社区版       │  │              │  │                  │ │          │
│   │  │  vs 企业版)   │  │              │  │                  │ │          │
│   │  └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘ │          │
│   │         │                  │                  │            │          │
│   │  ┌──────▼──────────────────▼──────────────────▼─────────┐  │          │
│   │  │              taurus_ee（企业版专属）                   │  │          │
│   │  │  • 审批引擎  • 通知  • HA 调度  • 策略引擎  • DAG   │  │          │
│   │  └──────────────────────────────────────────────────────┘  │          │
│   │                                                             │          │
│   │  ┌──────────────────────────────────────────────────────┐  │          │
│   │  │        MySQL/MariaDB 8.0+                            │  │          │
│   │  │  • Hosts, Sessions, Programs, Logs, Schedules, ...   │  │          │
│   │  └──────────────────────────────────────────────────────┘  │          │
│   └──┬──────────────────────────────┬──────────────────────────┘          │
│      │                              │                                      │
│      │ gRPC + mTLS                  │ Redis Queue                         │
│      ▼                              ▼                                      │
│   ┌──────────────┐           ┌──────────────┐                             │
│   │   Taurus     │           │   Taurus     │                             │
│   │  Executor    │           │  Scheduler   │                             │
│   │  (Python +   │           │  (APScheduler)│                            │
│   │   gRPC)      │           │               │                             │
│   │              │           │  Redis Leader 选举                          │
│   │  • 执行命令  │           │  • 每分钟轮询 DB                            │
│   │  • 流式 I/O  │           │  • Redis Queue 派发任务                     │
│   │  • 文件传输  │           │                                             │
│   └──────┬───────┘           └──────────────┘                             │
│          │                                                                 │
│          │ HTTP + HMAC-SHA256 签名                                         │
│          ▼                                                                 │
│   ┌──────────────┐                                                        │
│   │   Taurus     │                                                        │
│   │ Supervisor   │                                                        │
│   │ (asyncio)    │                                                        │
│   │  • 心跳      │                                                        │
│   │  • 程序生命周期│                                                       │
│   └──────────────┘                                                        │
│                                                                             │
│   ┌──────────────┐                                                        │
│   │   Taurus     │                                                        │
│   │    Auth      │  票据鉴权服务                                            │
│   │  (Django)    │  • 签发一次性执行票据                                    │
│   └──────────────┘  • 验证票据合法性                                        │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 通信协议

### 1. Web ↔ Backend: HTTP/REST + JWT

```
GET /api/taurus/hosts/
Authorization: Bearer <jwt_token>
Content-Type: application/json
```

**鉴权**: JWT 用 HMAC-SHA256 签名。Token 包含用户 ID、角色、过期时间。Django middleware 每层请求验证。

**WebSocket**: Django Channels 提供实时命令输出流（或 pure asyncio 降级）。

### 2. Backend ↔ Executor: gRPC + mTLS

```protobuf
// command_service.proto
service CommandService {
    rpc Run(CommandRequest) returns (stream CommandResponse);
    rpc StreamFile(FileStreamRequest) returns (FileStreamResponse);
    rpc List(ListRequest) returns (ListResponse);
}
```

**鉴权**: 双向 TLS（mutual TLS）。Backend 和 Executor 都出示同一 CA 签发的证书。支持 CRL 吊销。

**传输**: TCP over TLS 1.3。默认端口 50051。

### 3. Backend ↔ Supervisor: HTTP + 签名

```
POST /api/taurus/supervisor/heartbeat/
X-Timestamp: 1725340800
X-Signature: sha256=<hmac_hex>
X-Host-Id: <uuid>
```

**鉴权**: HMAC-SHA256 over `(timestamp + body)` 使用 per-host secret key。Timestamp 检查防重放窗口（±5 分钟）。

### 4. Backend ↔ Auth: HTTP + JWT

```
POST /api/ticket/issue/      Backend 请求票据 → Auth 返回 JWT
POST /api/ticket/verify/     Executor 执行前验证票据
```

**鉴权**: 预共享 service secret。Backend 签名请求，Auth 验证。

### 5. Scheduler → Backend: Redis Queue（HA）

```
Scheduler (Leader)              Redis                      Backend (Worker)
       │                          │                            │
       │  LPUSH schedule_queue   │                            │
       │ ──────────────────────► │                            │
       │                          │  BRPOP schedule_queue      │
       │                          │ ──────────────────────────►│
       │                          │                            │  执行命令
```

**HA 策略**: Redis Leader Election。同一时刻只有一个 scheduler 活跃。用 Redis `SET NX EX` 创建 60s TTL 的 leader key。

---

## 数据流 — 命令执行

```
用户在 Web 点击"执行"
    │
    ▼
Web: POST /api/taurus/session/  (HTTP + JWT)
    │
    ▼
Backend: SessionViewSet.create()
    │  1. 检查 has_feature("COMMAND_SINGLE")
    │  2. 检查主机在线
    │  3. 生成 execution ticket (通过 taurus-auth)
    │  4. 创建 Session 记录 (status=RUNNING)
    │  5. gRPC 调用 Executor
    │
    ▼
Executor: CommandService.Run()
    │  1. 用 taurus-auth 验证 ticket 签名
    │  2. Fork 子进程
    │  3. 流式 stdout/stderr 返回
    │
    ▼
Backend: 推送到 WebSocket 订阅者
    │
    ▼
Web: Terminal 组件渲染输出
```

### 关键类

| 层 | 类 | 位置 |
|---|---|---|
| API | `SessionViewSet` | `taurus/views.py` (薄封装 → `taurus_ee/`) |
| Gate | `ee_service_or_403` | `taurus/ee_fallback.py` (CE stub) / `taurus_ee/utils/gate.py` (EE) |
| gRPC | `GrpcExecutorClient` | `taurus/utils/grpc_client.py` |
| Ticket | `auth_jwt.issue_ticket` | `taurus/utils/auth_jwt.py` |
| Model | `Host`, `Session` | `taurus/models.py` |

---

## 数据流 — 定时任务

```
Scheduler (Leader, APScheduler)
    │
    │  每 30s 轮询 MySQL: SELECT * FROM script_task WHERE next_run_at <= NOW()
    │
    ▼
发现 ScriptTask
    │
    ├── Redis Queue 路径（正常）
    │   └─ LPUSH taurus_script_task_queue → Backend run_scheduler_worker 消费
    │
    └── HTTP 兜底路径（Redis 不可达）
        └─ POST /api/taurus/script_task/<id>/execute/ → Backend 直接执行
```

### HA Scheduler（企业版）

```
Node A (Leader)          Redis                    Node B (Follower)
    │                      │                          │
    │ SET leader_key NX 60s│                          │
    │ ────────────────────►│                          │
    │  ✅ 我是 Leader       │                          │
    │                      │                          │
    │ 心跳刷新              │                          │ SET leader_key NX 60s
    │ （每 30s）            │                          │ ───────────────────►│
    │                      │                          │ ❌ key 存在         │
    │                      │                          │ （等 1s 重试）       │
    │ Node A 挂了           │                          │
    │                      │ （key 60s 后过期）         │
    │                      │                          │ SET leader_key NX 60s
    │                      │                          │ ───────────────────►│
    │                      │                          │ ✅ 我是新 Leader     │
```

---

## 数据流 — 工作流

```
Web: 拖拽设计 Workflow DAG
    │  • 节点类型: approval, command, http, condition, wait, loop
    │  • 连线: 串行 / 并行
    │
    ▼
Backend: WorkflowEngine (taurus_ee/services/workflow_approval_engine.py)
    │  1. 验证 DAG（循环、不可达节点）
    │  2. 检查 has_feature("WORKFLOW_EXECUTION")
    │  3. 保存 WorkflowDefinition（JSON）
    │
    ▼
Web: 运行 Workflow
    │
    ▼
WorkflowRunner: 逐节点执行
    │  • 串行: 等前序节点成功
    │  • 并行: 扇出，等全部（或第一个成功）
    │  • 条件: 评估 Python 表达式
    │  • 审批: 阻塞直到人工审批
    │
    ▼
每个节点 → 对应 Executor (CommandService, HttpService, ...)
    │
    ▼
WorkflowExecutionRecord（持久化每个节点结果）
```

---

## 安全架构

### 纵深防御

```
第 1 层: 网络
  └── TLS 1.3 全覆盖 (gRPC mTLS, HTTPS API)
  └── Executor 端口 50051 不暴露公网（NAT 后）

第 2 层: 传输鉴权
  └── Web → Backend: JWT (HMAC-SHA256)
  └── Backend ↔ Executor: mTLS (CA 证书签名)
  └── Backend ↔ Supervisor: HMAC-SHA256 (per-host secret)
  └── Backend ↔ Auth: 预共享 service secret

第 3 层: License Gate（企业版）
  └── RSA-PSS-SHA256 签名 License 文件
  └── 双条件: edition == "enterprise" AND license.valid == True
  └── 可选机器指纹绑定
  └── 规范化 JSON 防篡改

第 4 层: 授权
  └── RBAC 角色 + 自定义 permission codes
  └── 脚本审批工作流（企业版）
  └── IP 白名单

第 5 层: 审计
  └── 全操作日志（命令输出、session、审批决策）
  └── 日志转发外部 SIEM（企业版）
```

### 证书生命周期

```
                    签发端 (CA)
                   ┌──────────┐
   CSR ───────────► │ ca.key   │ ◄─ 永不出签发端
                   │ ca.crt   │
                   └────┬─────┘
                        │ 签名
                        ▼
          ┌──────────────────────────────────┐
          │  分发到所有服务                    │
          │  - Backend (gRPC client cert)     │
          │  - Executor (mTLS server+client)  │
          │  - Supervisor (签名请求)          │
          └──────────────────────────────────┘

吊销: 签发端更新 ca.crl → 分发到所有服务
      CRL 在每次 mTLS 握手时检查
```

---

## 数据库 Schema（高层）

CE 和 EE 共享的核心表：

| 表 | 说明 | CE? | EE? |
|---|---|---|---|
| `host_host` | 注册的远程主机 | ✅ | ✅ |
| `host_session` | 命令执行 session | ✅ | ✅ |
| `host_program` | 主机上安装的程序 | ✅ | ✅ |
| `host_log` | 主机日志集中存储 | ✅ | ✅ |
| `script_scripttask` | 定时脚本 | ✅ | ✅ |
| `script_script` | 脚本内容 | ✅ | ✅ |
| `perm_role` / `perm_user` | RBAC 角色和用户 | ✅ | ✅ |

EE 专属表（安装 `taurus_ee` 时创建）：

| 表 | 说明 |
|---|---|
| `workflow_workflowdefinition` | 保存的工作流 DAG |
| `workflow_workflowexecution` | 工作流运行历史 |
| `approval_approvalrecord` | 审批决策 |
| `notification_notificationrule` | 通知路由规则 |
| `supervisor_programinstallpolicy` | 程序部署策略 |
| `scheduler_schedulercluster` | HA 调度集群状态 |
