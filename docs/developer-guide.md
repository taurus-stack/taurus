# Taurus Stack Developer Guide

> Environment setup, directory structure, start/test commands, and key configuration for every subproject at a glance.
> One-click debugging: the root `.vscode/launch.json` ships pre-configured launch profiles for each service and combinations — just press F5 in VS Code.
> The commands below are the equivalent manual CLI approach.

---

## Common Prerequisites

| Tool              | Version                  | Purpose                             |
| ----------------- | ------------------------ | ----------------------------------- |
| conda `taurus` env | Python 3.12.x           | All Python services share this env  |
| Poetry            | latest                   | Python dependency management        |
| pnpm              | 10.x (pinned in `packageManager`) | Frontend dependency management      |
| MySQL             | 8.0+                     | Shared by backend + auth + scheduler |
| Redis             | 7.2+                     | Cache + scheduler queue + dist. locks |

```bash
conda activate taurus
poetry config virtualenvs.in-project false   # use a global virtualenv
```

---

## taurus-backend

**Role**: Core API service (Django 4.2 + dvadmin) providing host management, command execution, workflow, scheduled tasks, etc. Ports 8000 (API) + 8765 (WebSocket).

### Directory Layout

```
taurus-backend/
├── application/          # Django project config (settings / urls / celery / wsgi)
├── conf/                 # Environment config (env.py, gitignored; env.example.py is the template)
├── taurus/               # Core business app
│   ├── models.py         # Host / Task / Workflow / Program ...
│   ├── views.py          # ViewSets (prefix api/taurus/)
│   ├── serializers.py
│   ├── workflow/         # Workflow engine
│   ├── sdk/              # gRPC client SDK
│   ├── utils/            # Utility functions (auth / gRPC / crypto)
│   ├── management/       # Django management commands
│   └── tasks.py          # Celery async tasks (scheduling now goes through taurus-scheduler; kept for compatibility)
├── dvadmin/              # ⚠️ Framework code — do not modify directly
├── certs/                # mTLS certificates (*.key never committed)
├── db/                   # Database dumps / migration scripts
├── logs/                 # Runtime logs
├── manage.py
└── pyproject.toml
```

### Tech Stack

Django 4.2 + DRF + dvadmin (RBAC / menus / dicts) + PyMySQL + Redis + JWT + drf-spectacular + Cryptography (Fernet encryption) + OpenSSL (mTLS).

### Environment Variables (`conf/env.py`)

| Variable                                                                                          | Description                | Example                              |
| ----------------------------------------------------------------------------------------------- | -------------------------- | ------------------------------------ |
| `DATABASE_HOST` / `DATABASE_PORT` / `DATABASE_USER` / `DATABASE_PASSWORD` / `DATABASE_NAME`     | MySQL connection          | `taurus_backend` / `taurus_` prefix  |
| `REDIS_HOST` / `REDIS_PORT` / `REDIS_PASSWORD` / `REDIS_URL`                                    | Redis (DB1)               | `redis://localhost:6379/1`           |
| `TAURUS_AUTH_URL`                                                                               | URL of the taurus-auth service | `http://localhost:8001`              |
| `TAURUS_SCHEDULER_QUEUE`                                                                        | Redis queue key consumed by the scheduler Worker | `taurus:scheduler:queue:script_task` |
| `REDIS_URL_SCHEDULER`                                                                           | Redis DB used by the Scheduler Worker | `redis://localhost:6379/2`           |
| `SECRET_KEY`                                                                                    | Django secret key         | random                               |

### Startup

```bash
conda activate taurus
cd taurus-backend
poetry install
cp conf/env.example.py conf/env.py    # edit the variables above
poetry run python manage.py migrate
poetry run python manage.py init      # initialize system data (first run only)
poetry run python manage.py runserver 0.0.0.0:8000

# WebSocket service (required, port 8765)
poetry run python manage/run_websocket_server.py

# Scheduler Worker (consumes the scheduling queue, pairs with taurus-scheduler)
poetry run python manage.py run_scheduler_worker --workers 4
```

### Reachable Endpoints

| URL                                            | Description              |
| ---------------------------------------------- | ------------------------ |
| `http://localhost:8000/`                       | 404 (pure API service)   |
| `http://localhost:8000/api/health/`            | Health check            |
| `http://localhost:8000/api/schema/swagger-ui/` | Swagger UI              |
| `http://localhost:8000/api/schema/redoc/`      | Redoc                   |
| `http://localhost:8000/api/taurus/`            | Prefix for all Taurus business APIs |

### Tests & Lint

```bash
poetry run pytest tests/                        # unit tests
poetry run python manage.py check               # Django system checks
poetry run ruff check . && poetry run black --check .
```

### Development Notes

- **Never modify `dvadmin/`**: framework code — touching it breaks upgrades. Write custom apps under `taurus/` instead.
- **mTLS certificates**: never commit `certs/ca.key`. The public key `ca.crt` may be committed; generate client certs per deployment.
- **Scheduler Worker vs scheduler are decoupled**: the scheduler process handles leader election + reading the DB + pushing to the Redis queue; the Worker is a management command inside backend that consumes the queue + executes + writes records. They can share the same host.

---

## taurus-auth

**Role**: Standalone ticket-authentication service (Django 4.2) that validates one-time execution tickets for the executor. Port 8001.

### Directory Layout

```
taurus-auth/
├── taurus_auth/          # Django project config (settings.py / urls.py)
├── ticket/               # Ticket business app (models / views / serializers / services)
│   └── utils/jwt_helper.py
├── db/                   # DB import/export scripts
├── manage.py
├── .env.example          # ← config template
└── pyproject.toml
```

### Tech Stack

Django 4.2 + PyMySQL + redis + macaroon + djangorestframework-simplejwt.

### Environment Variables (required)

| Variable                                                            | Description                  | launch.json example                                       |
| ------------------------------------------------------------------- | ---------------------------- | --------------------------------------------------------- |
| `DB_NAME` / `DB_USER` / `DB_PASSWORD` / `DB_HOST` / `DB_PORT`       | Dedicated auth database      | `taurus_auth` / `root` / `123456` / `localhost` / `3306` |
| `REDIS_URL`                                                         | Redis connection             | `redis://:123456@127.0.0.1:6379/1`                        |
| `BACKEND_JWT_SECRET`                                                | JWT signing secret shared with backend | random                                              |
| `MACAROON_ROOT_KEY`                                                 | Macaroon ticket root key     | random                                                    |
| `ALLOWED_BACKEND_IPS`                                               | Backend IPs allowed to access | `127.0.0.1` in development                                |
| `RATELIMIT_ENABLE`                                                  | Enable rate limiting         | `True`                                                    |
| `RATELIMIT_RATE`                                                    | Rate limit                   | `100/m`                                                   |
| `TICKET_DEFAULT_EXPIRES_MINUTES`                                    | Default ticket lifetime      | `5`                                                       |
| `TICKET_MAX_EXPIRES_MINUTES`                                        | Max ticket lifetime          | `60`                                                      |
| `DJANGO_SETTINGS_MODULE`                                            | Required at startup          | `taurus_auth.settings`                                    |

### Startup

```bash
cd taurus-auth
poetry install
cp .env.example .env       # edit the required fields above
poetry run python manage.py migrate
poetry run python manage.py runserver 0.0.0.0:8001
```

Health check: `curl http://localhost:8001/health/`

### Tests

```bash
poetry run pytest                 # all tests
poetry run pytest --cov=ticket    # with coverage
```

### Development Notes

- Auth is a separate Django project — `DJANGO_SETTINGS_MODULE` differs from backend (`taurus_auth.settings`); startup scripts must set it explicitly.
- Share `BACKEND_JWT_SECRET` with backend, otherwise ticket issuance/verification fails.
- Do not rotate the Macaroon root key once generated — all already-issued tickets become invalid.

---

## taurus-executor

**Role**: Remote command executor (Python + gRPC + mTLS) deployed on target hosts; receives execution instructions from backend. Port 50051 (gRPC).

### Directory Layout

```
taurus-executor/
├── src/executor_core/    # Core source
│   ├── main.py           # Entry point
│   ├── executors/        # Command executors (command / privileged)
│   ├── infra/            # Config, TLS, logging, state management
│   └── services/         # gRPC Server + interceptors (auth / CRL / ticket)
├── proto/executor/v1/    # gRPC proto definitions
├── scripts/              # Cert generation, packaging scripts
├── manage/cli.py         # Debugging CLI
├── tests/                # unit/ + integration/
├── Dockerfile.dev
├── .env.example          # ← config template
└── pyproject.toml
```

### Tech Stack

Python 3.12 + grpcio + cryptography + pyopenssl.

### Environment Variables (required)

| Variable                 | Description                              | launch.json example      |
| ----------------------- | ---------------------------------------- | ------------------------ |
| `PYTHONPATH`            | Must point to `src/` to import `executor_core` | `$PWD/src`         |
| `TAURUS_SERVER_URL`     | Backend address                          | `http://localhost:8000` |
| `TAURUS_HOST_UUID`      | UUID assigned after host registration in backend | obtained from the registration API |
| `GRPC_HOST` / `GRPC_PORT` | gRPC listen address                     | `0.0.0.0` / `50051`     |
| `TAURUS_AUTH_URL`       | Auth service URL (used for ticket validation) | `http://localhost:8001` |

### Startup

```bash
cd taurus-executor
poetry install
export PYTHONPATH=$PWD/src
export TAURUS_SERVER_URL=http://localhost:8000
export TAURUS_HOST_UUID=<obtain after registering with backend>
python -m executor_core.main
```

### mTLS Certificate Generation

The executor communicates with backend over gRPC + mTLS, which needs a three-level certificate chain:

```
CA certificate (taurus-backend/certs/ca.crt + ca.key)
├── executor server certificate (server.crt + server.key)  ← held by the executor itself
└── SDK client certificate (client.crt + client.key)       ← used by SDK/CLI to connect to the executor
```

#### Step 1: Ensure the CA exists (taurus-backend)

The CA certificate is auto-generated by backend's `CAManager.ensure_ca_exists()` and stored in `taurus-backend/certs/`:

```bash
# Triggered automatically on first backend startup; or manually:
cd taurus-backend
poetry run python -c "from taurus.ca_manager import CAManager; CAManager('certs').ensure_ca_exists()"
```

Generated artifacts:

| File        | Purpose                          | gitignore |
| ----------- | -------------------------------- | --------- |
| `certs/ca.key` | ⚠️ CA private key, **never distribute** | ✅       |
| `certs/ca.crt` | CA public certificate, commit & distribute | ❌       |

#### Step 2: Generate the executor server certificate

Pick any one of the three approaches:

**Approach A — Development (local script, fastest)**

```bash
cd taurus-executor
./scripts/generate_dev_server_cert.sh
# Default SANs: DNS:taurus-grpc-server, DNS:localhost, IP:127.0.0.1
# Optional args: ./scripts/generate_dev_server_cert.sh [cert-name] [validity-days]
```

Artifacts: `taurus-executor/tls/server.crt` + `server.key` + `ca.crt` (copied from backend)

**Approach B — Production / re-sign (full extensions via openssl.cnf)**

```bash
cd taurus-executor
# Default 365 days; customize: GRPC_SERVER_NAME=executor-host-01 ./scripts/regenerate_executor_cert.sh 730
./scripts/regenerate_executor_cert.sh
```

Difference vs Approach A: it signs with `openssl ca -config openssl.cnf` (not `openssl x509 -req`), writing to the CA database (`index.txt` / `serial`) for cert traceability and later CRL management.

**Approach C — Backend API signing (standard flow for production deployment)**

When the executor registers, it submits a CSR to the backend, which signs it online via `CAManager.sign_server_csr()`. This is the standard flow for large-scale host deployment — no manual script needed.

#### Step 3: Load the certificates in the executor

Certificates under `taurus-executor/tls/` are auto-detected; you can also specify them explicitly via env vars:

```bash
export TLS_CERT_PATH=$PWD/tls/server.crt
export TLS_KEY_PATH=$PWD/tls/server.key
export TLS_CA_PATH=$PWD/tls/ca.crt
python -m executor_core.main
```

#### Step 4 (optional): Generate an SDK client certificate

Connecting to the executor with the Python SDK / CLI requires a client certificate (mutual TLS):

```bash
cd taurus-executor
./scripts/generate_sdk_cert.sh
# Optional args: ./scripts/generate_sdk_cert.sh [cert-name] [validity-days]
```

Artifacts: `taurus-executor/certs/sdk/taurus-sdk.crt` + `taurus-sdk.key` + `ca.crt`

Usage example:

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
# ssl_target_name_override bypasses SAN matching when connecting by raw IP:
channel = grpc.secure_channel("10.0.1.123:50051", credentials, options=[
    ("grpc.ssl_target_name_override", "taurus-grpc-server"),
])
```

#### Certificate Verification

```bash
# Verify the server cert is trusted by the CA
openssl verify -CAfile tls/ca.crt tls/server.crt

# Inspect SAN extensions
openssl x509 -in tls/server.crt -noout -ext subjectAltName

# Connect to the executor with the SDK cert for a smoke test
python -m manage.cli --address localhost:50051 --cert tls/server.crt --key tls/server.key --ca tls/ca.crt status
```

#### Security Red Lines

- **`ca.key` must never leave `taurus-backend/certs/`** — do not copy it to the executor or any client host.
- Set `chmod 600` on `server.key` / `taurus-sdk.key`; never commit them to git.
- `*.crt` public certificates are freely distributable; `ca.crt` must be shared with every client to establish the trust chain.
- Renew certs with `regenerate_executor_cert.sh` (leaves a trace via `openssl ca`) — never overwrite with `generate_dev_server_cert.sh`.

#### Mounting Certificates in Docker

The root `docker-compose.yml` mounts cert directories into containers read-only, so **certificates generated on the host are read automatically by containers** — no image rebuild needed:

| Service                  | Host directory          | Container path | Notes                                         |
| ------------------------ | ----------------------- | -------------- | --------------------------------------------- |
| taurus-backend           | `./taurus-backend/certs` | `/app/certs:ro` | CA public key `ca.crt` (shared by all services) |
| taurus-websocket         | `./taurus-backend/certs` | `/app/certs:ro` | Same as backend                               |
| taurus-workflow-scheduler | `./taurus-backend/certs` | `/app/certs:ro` | Same as backend                               |
| taurus-scheduler-worker  | `./taurus-backend/certs` | `/app/certs:ro` | Uses gRPC to reach the executor when consuming the queue |
| taurus-executor          | `./taurus-executor/tls`  | `/opt/taurus-executor/tls:ro` | Server cert `server.crt` + `server.key` + `ca.crt` |

> `:ro` read-only: containers can only read, preventing tampering. Keep these paths fixed as declared in compose, because the read directory is hard-coded in the `Dockerfile`.

**Docker certificate generation order:**

```bash
# 1. CA (local backend or auto-generated by first compose startup) → taurus-backend/certs/ca.{crt,key}
poetry run python -c "from taurus.ca_manager import CAManager; CAManager('certs').ensure_ca_exists()"

# 2. Generate executor server cert → taurus-executor/tls/server.{crt,key} + copy ca.crt
cd taurus-executor
./scripts/generate_dev_server_cert.sh   # artifacts land under tls/
# ensure server.crt + server.key + ca.crt are all present

# 3. Start via compose; certs are mounted read-only into containers
docker compose up -d taurus-executor

# 4. Verify the certs are in place inside the container
docker exec taurus-executor ls -l /opt/taurus-executor/tls/
docker exec taurus-executor openssl verify -CAfile /opt/taurus-executor/tls/ca.crt \
  /opt/taurus-executor/tls/server.crt
```

**The SAN gotcha (easiest Docker pitfall):**

`generate_dev_server_cert.sh` defaults to SANs of `localhost` + `127.0.0.1` only, but inside the compose network the executor is reached **by service name**, so SAN matching fails. Two solutions:

- **Option A (recommended)**: regenerate the cert with `GRPC_SERVER_NAME` set to the service name during development:
  ```bash
  GRPC_SERVER_NAME=taurus-executor ./scripts/regenerate_executor_cert.sh
  ```
- **Option B**: skip SAN verification on the client — debug only:
  ```bash
  # Bypass via ssl_target_name_override (Python SDK side), see SDK example above
  ```

**About supervisor:**

In `docker-compose.yml`, `taurus-supervisor` shares the network/process namespaces via `network_mode: "service:taurus-executor"` + `pid: "service:taurus-executor"`, so it **reuses the executor's mTLS channel** to talk to the outside (via backend's `HTTP + signature`, not gRPC). Therefore the supervisor container needs **no** TLS cert mount of its own — the executor's copy is enough.

### Debugging CLI

```bash
python -m manage.cli --address localhost:50051 status
python -m manage.cli --address localhost:50051 exec "ls -la"
```

### Tests

```bash
poetry run pytest tests/unit/          # unit tests (no real backend needed)
poetry run pytest tests/integration/    # integration tests (needs backend + auth)
```

### Development Notes

- **PYTHONPATH trap**: source lives under `src/`, which `poetry run` does not add automatically — you must export it manually. launch.json sets it explicitly; remember to add it on the command line.
- After a proto change, regenerate the Python code: `scripts/process_grpc_files.py`.
- Certificate generation is covered above; use Approach A in development, B or C in production.

---

## taurus-supervisor

**Role**: Host daemon (Python + asyncio) managing the executor process lifecycle, heartbeat reporting, and start/stop of managed programs.

### Directory Layout

```
taurus-supervisor/
├── taurus_supervisor/     # Daemon core
│   ├── main.py            # Entry point
│   ├── heartbeat.py       # Heartbeat reporting
│   ├── program_manager.py # Managed program start/stop
│   └── log_forwarder.py   # Log forwarding
├── taurus_pm/             # Standalone pm CLI
├── templates/systemd/     # systemd service templates
├── templates/supervisor.env.example  # ← config template
├── scripts/               # register / build / uninstall
└── pyproject.toml
```

### Tech Stack

Python 3.12 + asyncio + httpx + structlog.

### Environment Variables

| Variable                     | Description                 | launch.json example           |
| ---------------------------- | --------------------------- | ------------------------------ |
| `PYTHONPATH`                 | Points to project root (to import `taurus_supervisor`) | `$PWD` |
| `BASE_DIR`                   | Supervisor runtime data dir | `~/taurus`                    |
| `SERVER_URL`                 | Backend address             | `http://localhost:8000`       |
| `HOST_ID`                    | Host identifier (UUID)      | corresponds to executor's `TAURUS_HOST_UUID` |
| `SUPERVISOR_HEARTBEAT_INTERVAL` | Heartbeat interval (s)     | `10`                          |
| `HEALTH_CHECK_INTERVAL`      | Health check interval (s)   | `10`                          |
| `LOG_DIR`                    | Log directory               | `~/taurus/logs`               |
| `SSL_VERIFY`                 | Verify certificates (disable in dev) | `false`                          |
| `CONFIG_ENCRYPTION_ENABLED`  | Config encryption           | `false`                       |
| `REQUEST_SIGNING_SECRET`     | Signature verification with backend | can be empty in dev        |

### Startup

```bash
cd taurus-supervisor
poetry install
export PYTHONPATH=$PWD
export BASE_DIR=~/taurus
python -m taurus_supervisor.main
```

### Tests

```bash
poetry run pytest    # pytest + pytest-asyncio
```

### Development Notes

- Supervisor and Executor are usually deployed on the same host, sharing PID/Network namespaces (`pid: "service:taurus-executor"` in docker-compose).
- Heartbeat uses HTTP + HMAC signature; if the backend has no `REQUEST_SIGNING_SECRET` configured during development, leave it empty in supervisor too to skip signing.

---

## taurus-scheduler

**Role**: Standalone scheduling service (Python + APScheduler + FastAPI) that reads `ScriptTask` from the DB, elects a leader, and dispatches tasks to a Redis queue. Health-check port 9101.

### Directory Layout

```
taurus-scheduler/
├── scheduler/
│   ├── main.py            # Entry point (scheduling engine + health-check API start together)
│   ├── engine.py          # APScheduler engine + leader election
│   ├── dispatcher.py      # Dispatch tasks to the Redis queue
│   ├── lock.py            # Redis distributed lock
│   ├── store.py           # MySQL read-only (polls ScriptTask)
│   ├── config.py          # pydantic-settings config
│   ├── health_api.py      # FastAPI health-check endpoint
│   └── logging_config.py
├── .env.example           # ← config template
├── Dockerfile
└── pyproject.toml
```

### Tech Stack

Python 3.12 + apscheduler + PyMySQL + redis + fastapi + uvicorn + prometheus-client + structlog.

### Environment Variables

| Variable                                                                                              | Description                     | launch.json example                        |
| ------------------------------------------------------------------------------------------------------- | ------------------------------- | ---------------------------------------- |
| `PYTHONPATH`                                                                                            | Points to project root          | `$PWD`                                   |
| `SCHEDULER_INSTANCE_ID`                                                                                 | Instance identifier (for leader election) | `dev-local-01`                           |
| `DB_HOST` / `DB_PORT` / `DB_USER` / `DB_PASSWORD` / `DB_NAME` / `DB_TABLE_PREFIX`                      | Read-only access to the same MySQL DB as backend | `taurus_backend` / `taurus_` prefix |
| `REDIS_HOST` / `REDIS_PORT` / `REDIS_PASSWORD` / `REDIS_DB`                                             | Redis config                   | **DB=2** (offset from other services), placeholder password |
| `REDIS_QUEUE_KEY`                                                                                       | Task queue key                 | `taurus:scheduler:queue:script_task`      |
| `REDIS_DEDUP_PREFIX`                                                                                    | Dedup prefix                   | `taurus:scheduler:dedup:`                |
| `REDIS_LOCK_PREFIX`                                                                                     | Leader lock prefix             | `taurus:scheduler:lock:`                 |
| `BACKEND_API_BASE_URL`                                                                                  | Fallback callback (HTTP push when the queue is unreachable) | `http://localhost:8000` |
| `HEALTH_HOST` / `HEALTH_PORT`                                                                           | Health-check listen            | `0.0.0.0` / `9101`                       |
| `TIMEZONE`                                                                                              | Timezone                       | `Asia/Shanghai`                          |

### Startup

```bash
cd taurus-scheduler
poetry install
export PYTHONPATH=$PWD
python -m scheduler.main
```

Health check: `curl http://localhost:9101/health`

### Tests

```bash
poetry run pytest    # pytest + pytest-asyncio
```

### Communication Security (no mTLS needed)

Scheduler does **not** go through gRPC and needs **no mTLS certificates** — it has only three communication channels, none of which are TLS/gRPC:

| Channel        | Protocol              | Security model             | Notes                                    |
| -------------- | --------------------- | -------------------------- | ---------------------------------------- |
| MySQL          | TCP (Django ORM)      | DB credentials + net. isolation | read-only `ScriptTask`             |
| Redis          | TCP                   | Redis password + net. isolation | DB=2, queue/locks/dedup           |
| backend fallback callback | HTTP(S)     | optional `BACKEND_API_TOKEN` | pushed back when the queue is unreachable; see `BACKEND_API_TOKEN` in `.env.example` |

gRPC + mTLS exists only on the **executor ↔ backend** link (see the taurus-executor section). If you want to protect the scheduler's HTTP callback, just configure `BACKEND_API_TOKEN` — no certificate steps needed. If you need encryption for MySQL/Redis transport, use the corresponding SSL/TLS connection strings; that's database-side configuration, unrelated to the executor's CA/cert system.

### Companion: Scheduler Worker

After Scheduler pushes tasks into the Redis queue, a worker inside backend consumes and executes them:

```bash
cd taurus-backend
poetry run python manage.py run_scheduler_worker --workers 4
```

### Development Notes

- **Redis DB must be 2**: backend uses 1 (cache), auth uses 1 (tickets), scheduler is dedicated to 2.
- Scheduler accesses MySQL **read-only** (`ScriptTask` table); execution records are written back by the worker (inside the backend process).
- Leader election works automatically across multiple instances; with a single instance, `SCHEDULER_INSTANCE_ID` can be anything.

---

## taurus-web

**Role**: Frontend admin UI (Vue 3 + TypeScript + Element Plus + fast-crud). Dev port 3000; production is served by nginx on port 80.

### Directory Layout (core)

```
taurus-web/
├── src/
│   ├── api/taurus/            # Business API wrappers (host / ops / workflow / schedule ...)
│   ├── views/taurus/          # Business pages (subdirectories by domain)
│   │   ├── host/              # Host management
│   │   ├── ops/command/       # Command execution
│   │   ├── workflow/          # Workflow
│   │   ├── schedule/          # Scheduled tasks
│   │   └── supervisor/        # Supervisor management
│   ├── components/workflow/   # Workflow-specific components (DAG editor, etc.)
│   ├── stores/taurus/         # Pinia state
│   ├── i18n/pages/            # Page-level i18n (zh-cn / en / zh-tw)
│   ├── router/                # Routing
│   └── utils/request.ts       # Axios wrapper
├── .env.development           # Development env vars
├── .env.local_prod            # Local production build env vars
├── package.json               # pnpm package manager
└── vite.config.ts
```

### Tech Stack

Vue 3 + TypeScript + Element Plus + fast-crud (`@fast-crud/fast-crud` + `@fast-crud/ui-element`) + Vue Flow (DAG editing) + Monaco Editor + ECharts.

### Startup

```bash
cd taurus-web
pnpm install         # must use pnpm; lockfile pins pnpm@10.24.0
pnpm run dev         # http://localhost:3000
pnpm run build       # production build
```

### Tests & Lint

```bash
pnpm run test           # Vitest
pnpm run test:coverage  # with coverage
pnpm run lint-fix       # ESLint --fix
```

### Development Notes

- **CRUD pages must use fast-crud**: to add a CRUD page for a new model, the standard pattern is `api/taurus/<domain>/api.ts` (API wrapper) + `views/taurus/<domain>/index.vue` + `crud.tsx` (CrudOptions config). See `.trae/docs/fast-crud/FAST-CRUD-AI-DOC.md`.
- **Component selection** prefers Element Plus native components > fast-crud wrapper components > custom components. For dialogs see `.trae/docs/fast-crud/dialog-usage-guide.md`.
- **Forbidden**: untyped `any`; `v-html` rendering uncontrolled content.
- **WebSocket notifications**: `src/utils/websocket.ts` encapsulates real-time push from taurus-backend — no manual connection needed.
- Put page-level i18n text in `src/i18n/pages/<page-dir>/zh-cn.ts`, keeping the three locales aligned on commit.