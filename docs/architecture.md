# System Architecture

[中文](architecture.zh-CN.md)

## Table of Contents

1. [Component Overview](#component-overview)
2. [Communication Protocols](#communication-protocols)
3. [Data Flow — Command Execution](#data-flow--command-execution)
4. [Data Flow — Scheduled Task](#data-flow--scheduled-task)
5. [Data Flow — Workflow](#data-flow--workflow)
6. [Security Architecture](#security-architecture)
7. [Database Schema (High Level)](#database-schema-high-level)

---

## Component Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                             Taurus Stack                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌──────────────┐                                                        │
│   │   Taurus Web  │  Frontend management interface                         │
│   │   (Vue 3 + TS)│  • Element Plus UI framework                            │
│   └──────┬───────┘  • fast-crud tables/forms                               │
│          │ HTTP/REST + JWT                                                  │
│          ▼                                                                 │
│   ┌─────────────────────────────────────────────────────────────┐          │
│   │                   Taurus Backend (Django 4.2)              │          │
│   │                                                             │          │
│   │  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐ │          │
│   │  │ Edition Gate │  │  Workflow    │  │  Scheduler       │ │          │
│   │  │ (Community   │  │  Engine      │  │  Handler         │ │          │
│   │  │  vs Ent)     │  │              │  │                  │ │          │
│   │  └──────┬───────┘  └──────┬───────┘  └────────┬─────────┘ │          │
│   │         │                  │                  │            │          │
│   │  ┌──────▼──────────────────▼──────────────────▼─────────┐  │          │
│   │  │                  taurus_ee (Enterprise Only)         │  │          │
│   │  │  • Approval Engine  • Notification  • HA Scheduler   │  │          │
│   │  │  • Policy Engine   • DAG Units      • Program MGMT    │  │          │
│   │  └──────────────────────────────────────────────────────┘  │          │
│   │                                                             │          │
│   │  ┌──────────────────────────────────────────────────────┐  │          │
│   │  │            Database (MySQL/MariaDB 8.0+)             │  │          │
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
│   │              │           │  Leader Election in Redis                  │
│   │  • Run cmds  │           │  • Polls DB every minute                    │
│   │  • Stream I/O│           │  • Pushes tasks via Redis Queue             │
│   │  • File xfer │           │                                             │
│   └──────┬───────┘           └──────────────┘                             │
│          │                                                                 │
│          │ HTTP + HMAC-SHA256 Signature                                    │
│          ▼                                                                 │
│   ┌──────────────┐                                                        │
│   │   Taurus     │                                                        │
│   │ Supervisor   │                                                        │
│   │ (asyncio)    │                                                        │
│   │  • Heartbeat │                                                        │
│   │  • Program   │                                                        │
│   │    lifecycle │                                                        │
│   └──────────────┘                                                        │
│                                                                             │
│   ┌──────────────┐                                                        │
│   │   Taurus     │                                                        │
│   │    Auth      │  Ticket-based authentication                            │
│   │  (Django)    │  • Issues one-time tickets                              │
│   └──────────────┘  • Verifies tickets for gRPC execution                  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Communication Protocols

### 1. Web ↔ Backend: HTTP/REST + JWT

```
GET /api/taurus/hosts/
Authorization: Bearer <jwt_token>
Content-Type: application/json
```

**Auth**: JWT signed with HMAC-SHA256. Token contains user ID, role, and expiration. Validated on every request by Django middleware.

**WebSockets**: Real-time command output streaming via Django Channels (or pure asyncio fallback).

### 2. Backend ↔ Executor: gRPC + mTLS

```protobuf
// command_service.proto
service CommandService {
    rpc Run(CommandRequest) returns (stream CommandResponse);
    rpc StreamFile(FileStreamRequest) returns (FileStreamResponse);
    rpc List(ListRequest) returns (ListResponse);
}
```

**Auth**: Mutual TLS (双向证书). Backend and Executor both present certs signed by the same CA. CRL supported for revocation.

**Transport**: TCP over TLS 1.3. Default port 50051.

### 3. Backend ↔ Supervisor: HTTP + Signature

```
POST /api/taurus/supervisor/heartbeat/
X-Timestamp: 1725340800
X-Signature: sha256=<hmac_hex>
X-Host-Id: <uuid>
```

**Auth**: HMAC-SHA256 over `(timestamp + body)` using a per-host secret key. Timestamp checked for replay window (±5 minutes).

### 4. Backend ↔ Auth: HTTP + JWT

```
POST /api/ticket/issue/      Backend requests ticket → Auth returns JWT
POST /api/ticket/verify/     Executor verifies ticket before running command
```

**Auth**: Pre-shared service secret. Backend signs requests, Auth validates.

### 5. Scheduler → Backend: Redis Queue (HA)

```
Scheduler (Leader)              Redis                      Backend (Worker)
       │                          │                            │
       │  LPUSH schedule_queue   │                            │
       │ ──────────────────────► │                            │
       │                          │  BRPOP schedule_queue      │
       │                          │ ──────────────────────────►│
       │                          │                            │  run command
```

**HA Strategy**: Redis Leader Election. Only one scheduler instance is active at a time. Redis `SET NX EX` creates a leader key with 60s TTL.

---

## Data Flow — Command Execution

```
User clicks "Run" in Web
    │
    ▼
Web: POST /api/taurus/session/  (HTTP + JWT)
    │
    ▼
Backend: SessionViewSet.create()
    │  1. Check has_feature("COMMAND_SINGLE")
    │  2. Check host online
    │  3. Generate execution ticket (via taurus-auth)
    │  4. Create Session record (status=RUNNING)
    │  5. gRPC call to Executor
    │
    ▼
Executor: CommandService.Run()
    │  1. Verify ticket signature with taurus-auth
    │  2. Fork subprocess
    │  3. Stream stdout/stderr back
    │
    ▼
Backend: Stream to WebSocket subscriber
    │
    ▼
Web: Terminal component renders output
```

### Key Classes

| Layer | Class | Location |
|-------|-------|----------|
| API | `SessionViewSet` | `taurus/views.py` (thin wrapper → `taurus_ee/`) |
| Auth | `ee_service_or_403` | `taurus/ee_fallback.py` (CE stub) / `taurus_ee/utils/gate.py` (EE) |
| gRPC | `GrpcExecutorClient` | `taurus/utils/grpc_client.py` |
| Ticket | `auth_jwt.issue_ticket` | `taurus/utils/auth_jwt.py` |
| Model | `Host`, `Session` | `taurus/models.py` |

---

## Data Flow — Scheduled Task

```
Scheduler (Leader, APScheduler)
    │
    │  Poll MySQL every 30s: SELECT * FROM script_task WHERE next_run_at <= NOW()
    │
    ▼
ScriptTask discovered
    │
    ├── Redis Queue path (normal)
    │   └─ LPUSH taurus_script_task_queue → Backend run_scheduler_worker picks up
    │
    └── HTTP fallback path (Redis unreachable)
        └─ POST /api/taurus/script_task/<id>/execute/ → Backend runs directly
```

### HA Scheduler (Enterprise Only)

```
Node A (Leader)          Redis                    Node B (Follower)
    │                      │                          │
    │ SET leader_key NX 60s│                          │
    │ ────────────────────►│                          │
    │  ✅ I'm leader       │                          │
    │                      │                          │
    │ Heartbeat refresh    │                          │ SET leader_key NX 60s
    │ (every 30s)          │                          │ ───────────────────►│
    │                      │                          │ ❌ key exists        │
    │                      │                          │  (wait 1s, retry)    │
    │ Node A dies          │                          │
    │                      │  (key expires after 60s) │
    │                      │                          │ SET leader_key NX 60s
    │                      │                          │ ───────────────────►│
    │                      │                          │ ✅ I'm the new leader │
```

---

## Data Flow — Workflow

```
Web: Design Workflow DAG
    │  • Drag-drop nodes (approval, command, http, condition, wait, loop)
    │  • Connect with edges (serial / parallel)
    │
    ▼
Backend: WorkflowEngine (taurus_ee/services/workflow_approval_engine.py)
    │  1. Validate DAG (cycles, unreachable nodes)
    │  2. Check has_feature("WORKFLOW_EXECUTION")
    │  3. Save WorkflowDefinition (JSON)
    │
    ▼
Web: Run Workflow
    │
    ▼
WorkflowRunner: Execute node by node
    │  • Serial: wait previous node success
    │  • Parallel: fan out, wait all (or first success)
    │  • Conditional: evaluate Python expression
    │  • Approval: block until human approves
    │
    ▼
Each node → Appropriate Executor (CommandService, HttpService, ...)
    │
    ▼
WorkflowExecutionRecord (persist every node result)
```

---

## Security Architecture

### Defense in Depth

```
Layer 1: Network
  └── TLS 1.3 everywhere (gRPC mTLS, HTTPS API)
  └── Executor port 50051 not exposed to public internet (behind NAT)

Layer 2: Transport Authentication
  └── Web → Backend: JWT (HMAC-SHA256)
  └── Backend ↔ Executor: mTLS (CA-signed certs)
  └── Backend ↔ Supervisor: HMAC-SHA256 (per-host secret)
  └── Backend ↔ Auth: Pre-shared service secret

Layer 3: License Gate (Enterprise Only)
  └── RSA-PSS-SHA256 signed license file
  └── Dual-condition: edition == "enterprise" AND license.valid == True
  └── Machine fingerprint binding (optional)
  └── Tamper detection via canonicalized JSON

Layer 4: Authorization
  └── Role-based access control (RBAC) with custom permission codes
  └── Script approval workflow (Enterprise)
  └── IP whitelisting

Layer 5: Audit
  └── All operations logged (command output, session, approval decisions)
  └── Log forwarding to external SIEM (Enterprise)
```

### Certificate Lifecycle

```
                    Issuer (CA)
                   ┌──────────┐
   Request CSR ───► │ ca.key   │ ◄─ NEVER leaves issuer
                   │ ca.crt   │
                   └────┬─────┘
                        │ sign
                        ▼
          ┌──────────────────────────────────┐
          │  distributes to all services     │
          │  - Backend (as client cert for   │
          │    gRPC calls to Executor)       │
          │  - Executor (as both server and  │
          │    client for mTLS)              │
          │  - Supervisor (signs requests)   │
          └──────────────────────────────────┘

Revocation: ca.crl updated by issuer, deployed to all services
            CRL checked on every mTLS handshake
```

---

## Database Schema (High Level)

Core tables shared between CE and EE:

| Table | Description | CE? | EE? |
|-------|-------------|-----|-----|
| `host_host` | Registered remote hosts | ✅ | ✅ |
| `host_session` | Command execution sessions | ✅ | ✅ |
| `host_program` | Installed programs on hosts | ✅ | ✅ |
| `host_log` | Centralized host logs | ✅ | ✅ |
| `script_scripttask` | Scheduled scripts | ✅ | ✅ |
| `script_script` | Saved script content | ✅ | ✅ |
| `perm_role` / `perm_user` | RBAC roles and users | ✅ | ✅ |

EE-only tables (created when `taurus_ee` is installed):

| Table | Description |
|-------|-------------|
| `workflow_workflowdefinition` | Saved workflow DAGs |
| `workflow_workflowexecution` | Workflow run history |
| `approval_approvalrecord` | Approval decisions |
| `notification_notificationrule` | Notification routing |
| `supervisor_programinstallpolicy` | Program deployment policy |
| `scheduler_schedulercluster` | HA scheduler cluster state |
