# Taurus Stack

<div align="center">

**Distributed Operations Management System**

[English](README.md) | [中文](README.zh-CN.md)

[![License](https://img.shields.io/badge/license-AGPLv3-blue.svg)](LICENSE)
[![Python Version](https://img.shields.io/badge/python-3.12+-blue.svg)](https://www.python.org/)
[![Vue Version](https://img.shields.io/badge/vue-3.2+-green.svg)](https://vuejs.org/)
[![TypeScript](https://img.shields.io/badge/typescript-4.9+-blue.svg)](https://www.typescriptlang.org/)
[![Community Edition](https://img.shields.io/badge/Community-37%2F77%20Features-brightgreen.svg)](#community-edition)
[![Enterprise Edition](https://img.shields.io/badge/Enterprise-77%2F77%20Features-blue.svg)](#enterprise-edition)

</div>

---

## What is Taurus Stack?

Taurus Stack is a comprehensive distributed operations management system (堡垒机 / 运维管理平台) designed for managing remote hosts, executing commands, and monitoring system health. It provides secure, scalable, and reliable infrastructure management capabilities.

Taurus Stack ships in two editions sharing the same codebase:

|                          | **Community Edition**  | **Enterprise Edition**                 |
| ------------------------ | ---------------------- | -------------------------------------- |
| **License**              | AGPL-3.0 (open source) | Commercial                             |
| **Features**             | 37 / 77                | 77 / 77                                |
| **Workflow Engine**      | ✅ Basic orchestration  | ✅ Full + Approval + DAG                |
| **High Availability**    | Single instance        | Redis HA + Leader Election             |
| **Audit & Approval**     | ❌                      | ✅ Script / Program / Workflow Approval |
| **Notification**         | ❌                      | ✅ Email + Webhook + Callback           |
| **Multi-Host Execution** | ❌                      | ✅ Serial / Parallel / Batch            |
| **License System**       | ❌                      | ✅ RSA-PSS-SHA256 Signed License        |
| **Source Code**          | Fully open source      | `taurus_ee/` closed-source package     |

> **Security**: Enterprise Edition code lives in a separate private repository. The Community Edition repository contains zero private keys, zero signing code, and `taurus_ee/` is permanently gitignored. See [docs/editions.md](docs/editions.md) for the full separation design.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Taurus Stack Architecture                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│   ┌──────────────┐  HTTP/REST+JWT   ┌──────────────────────────────────┐  │
│   │   Taurus Web  │ ───────────────►│        Taurus Backend              │  │
│   │   (Vue 3)     │ ◄────────────── │      (Django 4.2 + dvadmin)       │  │
│   └──────────────┘  WebSocket        │                                   │  │
│                                       │  ┌──────────────────────────┐   │  │
│                                       │  │   Edition Gate            │   │  │
│                                       │  │  (edition + license.valid)│   │  │
│                                       │  └──────────┬───────────────┘   │  │
│                                       │             │ EE features        │  │
│                                       │             │ auto-discover      │  │
│                                       │     ┌───────▼───────────────┐   │  │
│                                       │     │ taurus_ee/  (EE only) │   │  │
│                                       │     │  • RSA License Verify │   │  │
│                                       │     │  • Approval Engine     │   │  │
│                                       │     │  • Workflow DAG        │   │  │
│                                       │     │  • HA Scheduler        │   │  │
│                                       │     └───────┬───────────────┘   │  │
│                                       └──────┬──────┬──────────────────┘  │
│                                              │      │                       │
│                     ┌────────────────────────┘      │                      │
│                     │ gRPC + mTLS                    │ HTTP + JWT           │
│   ┌──────────────┐  │                                │                      │
│   │   Taurus     │  ▼                                ▼                      │
│   │  Executor    │ ◄───────────────────────┐     ┌──────────────┐         │
│   │  (gRPC)      │ ───────────────────────►│     │ Taurus Auth  │         │
│   └──────────────┘                         │     │ (Ticket Svc) │         │
│                                             │     └──────────────┘         │
│   ┌──────────────┐  HTTP(Heartbeat)        │                                │
│   │   Taurus     │ ◄───────────────────────┘                                │
│   │ Supervisor   │  (asyncio daemon)                                        │
│   └──────────────┘                                                          │
│                                                                             │
│   ┌──────────────┐              Redis Queue              ┌──────────────┐  │
│   │   Taurus     │ ─────────────────────────────────────►│ Taurus Backend│  │
│   │  Scheduler   │   APScheduler + Leader Election       │ (run_scheduler│  │
│   │ (standalone) │                                        │  _worker)     │  │
│   └──────────────┘                                        └──────────────┘  │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Communication Overview

| Link                 | Protocol         | Auth                        | Purpose                                |
| -------------------- | ---------------- | --------------------------- | -------------------------------------- |
| Web → Backend        | HTTP/REST + JWT  | HMAC-SHA256 signed tokens   | Management API                         |
| Backend ↔ Executor   | gRPC + mTLS      | Mutual TLS certificates     | Remote command execution               |
| Backend ↔ Supervisor | HTTP + Signature | HMAC-SHA256 request signing | Heartbeat + Program control            |
| Backend ↔ Auth       | HTTP + JWT       | JWT with service secret     | One-time execution ticket verification |
| Scheduler → Backend  | Redis Queue      | Redis auth                  | Schedule dispatch                      |

---

## Repository Structure

This is a **git submodule** aggregate repository. Each service lives in its own repository with independent versioning and `.gitignore`.

```
taurus-stack/                          ← Root (this repo, aggregation only)
├── .gitmodules                        ← Submodule definitions
├── README.md / README.zh-CN.md        ← You are here
├── docs/                              ← Cross-repository documentation
│
├── taurus-backend/  🔧 git submodule  ← Django 4.2 + dvadmin (API server)
│   ├── application/                   ← Django project config
│   ├── taurus/                        ← Business logic + Edition Gate
│   │   ├── editions/                  ← Community vs Enterprise abstract
│   │   ├── ee_fallback.py             ← CE stub when taurus_ee missing
│   │   └── serializers.py / views.py  ← Thin wrappers with try/except
│   ├── certs/                         ← CA certificates (gitignored)
│   └── plugins/taurus_ee → ../../taurus_ee/   ← Dev symlink (gitignored)
│
├── taurus-web/      🔧 git submodule  ← Vue 3 + TS + Element Plus + fast-crud
├── taurus-executor/ 🔧 git submodule  ← Python + gRPC remote executor
├── taurus-supervisor/ 🔧 git submodule ← asyncio host daemon
├── taurus-auth/     🔧 git submodule  ← Django ticket-based auth service
├── taurus-scheduler/ 🔧 git submodule ← APScheduler standalone service
│
└── taurus_ee/       🔒 PRIVATE REPO   ← Enterprise Edition (never public)
    ├── license.py                     ← RSA-PSS-SHA256 verify-only
    ├── apps.py                        ← Django app ready() injection
    ├── services/                      ← Approval, Notification, HA...
    ├── workflow_units/                ← DAG execution units
    └── management/commands/           ← license_status, license_import
```

### Clone the full stack

```bash
# Clone with all submodules
git clone --recurse-submodules https://github.com/taurus-ops/taurus-stack.git
cd taurus-stack

# Update submodules to latest
git submodule update --remote --recursive

# Individual submodule URLs: see .gitmodules
```

> **Note**: `taurus_ee` (Enterprise Edition) is NOT a public submodule. Enterprise customers receive it as a PyArmor/Cython-obfuscated Python wheel: `pip install taurus_ee-*.whl`. The `taurus_ee/` directory in this repo is permanently gitignored.

---

## Quick Start

### Prerequisites

- Python 3.12+
- Node.js >= 18.0.0
- MySQL/MariaDB (8.0+)
- Redis (6.0+)
- Poetry (Python dependency management)
- pnpm (Frontend dependency management)

### Development Setup (Community Edition)

```bash
# 0. Clone with submodules
git clone --recurse-submodules https://github.com/taurus-ops/taurus-stack.git
cd taurus-stack

# 1. Backend
cd taurus-backend
poetry install
cp conf/env.example.py conf/env.py     # Edit DB/Redis/secret values
poetry run python manage.py migrate
poetry run python manage.py runserver 0.0.0.0:8000

# 2. Auth (another terminal)
cd taurus-auth
poetry install
cp .env.example .env                   # Match shared secret with backend
poetry run python manage.py migrate
poetry run python manage.py runserver 0.0.0.0:8001

# 3. Web (another terminal)
cd taurus-web
pnpm install
pnpm run dev                           # Vite dev server on port 3000

# 4. Register a remote host
curl -fsSL http://localhost:8000/api/taurus/supervisor/install_script/ \
  | bash -s -- --token <your-token> --auto-install
```

### Docker Compose

```bash
docker-compose up -d
docker-compose logs -f taurus-backend
```

### Enterprise Edition (after receiving license)

```bash
# Install the EE wheel (customer-specific build)
poetry add /path/to/taurus_ee-2.0.0-py3-none-any.whl

# Or place the symlink in development
ln -s /path/to/taurus_ee taurus-backend/plugins/taurus_ee

# Import your signed license
python manage.py license_import ./license.lic --force

# Verify it's active
python manage.py license_status
# → License valid: True, Feature Gate: 77/77 (全部放行)
```

---

## Security

### Certificate Management

```
taurus-backend/certs/           (gitignored — secrets never committed)
├── ca.crt                      # CA certificate (public, distributable)
├── ca.key                      # ⚠️ CA private key (keep offline!)
├── client.crt                  # Client certificate
├── client.key                  # ⚠️ Client private key
└── openssl.cnf                 # OpenSSL configuration
```

### License System (Enterprise Only)

```
┌─ Issuer (private signing server) ─────────────────────────────┐
│  scripts/license_signer.py          (gitignored, private-only) │
│  scripts/secrets/license_signer_privkey.pem                    │
│  RSA-2048 Private Key (chmod 600, never leaves issuer)        │
└───────────────────────────────────────────────────────────────┘
           │  signs JSON payload + base64 → .lic file
           ▼
┌─ License File (delivered to customer) ──────────────────────┐
│  license.lic                                                  │
│  {customer_id, customer_name, tier, expires_at, features,     │
│   quota, machine_fp?} + Base64(RSA-PSS-SHA256 signature)    │
└───────────────────────────────────────────────────────────────┘
           │  loaded at runtime
           ▼
┌─ Taurus EE Runtime (taurus_ee/license.py) ────────────────────┐
│  • RSA-PSS-SHA256 signature verification                      │
│  • Expiration check                                           │
│  • Machine fingerprint matching (optional, anti-vm)          │
│  • Tamper detection (sort_keys JSON canonicalization)         │
│                                                               │
│  ⚠️ NO signing code — verification only                       │
│  ⚠️ NO private key — only hardcoded RSA public key           │
└───────────────────────────────────────────────────────────────┘
```

**Gate mechanism**: `has_feature()` checks **both** `TAURUS_EDITION=enterprise` **AND** `license.valid=True`. Either fails → all EE features return False.

### Environment Variables

| Variable                     | Service           | Description                              | Default                    |
| ---------------------------- | ----------------- | ---------------------------------------- | -------------------------- |
| `TAURUS_EDITION`             | Backend           | `community` or `enterprise`              | `community`                |
| `TAURUS_LICENSE_FILE`        | Backend           | Path to `.lic` file                      | Auto-detected              |
| `TAURUS_DEV_BYPASS_LICENSE`  | Backend           | Set `1` to skip license check (dev only) | unset                      |
| `TAURUS_SIGNER_PRIVKEY_PATH` | License Signer    | Path to RSA private key                  | unset                      |
| `AUTH_SERVICE_URL`           | Backend/Auth      | Auth service base URL                    | `http://localhost:8001`    |
| `REDIS_URL`                  | Backend/Scheduler | Redis connection                         | `redis://localhost:6379/0` |

---

## Documentation

Cross-repository design docs live in this root repo:

- [docs/architecture.md](docs/architecture.md) — System architecture, protocols, data flow
- [docs/editions.md](docs/editions.md) — Community vs Enterprise separation, License security design
- [CONTRIBUTING.md](CONTRIBUTING.md) — Multi-repository development workflow

Service-specific docs live in each subrepo:

- [taurus-backend/docs/](taurus-backend/docs/) — API, models, Edition dev guide
- [taurus-executor/docs/](taurus-executor/docs/) — gRPC executor, deployment, upgrade
- [taurus-supervisor/](taurus-supervisor/README.md) — Host daemon, communication protocol

---

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) for details on our multi-repository development workflow, branching strategy, and code review process.

For security issues, see the `SECURITY.md` in each subproject.

---

## License

- **Community Edition**: GNU Affero General Public License v3.0 — see [LICENSE](LICENSE)
- **Enterprise Edition**: Proprietary commercial license — contact sales

---

## Links

| Service          | Repository                                                           | Issues                                                                |
| ---------------- | -------------------------------------------------------------------- | --------------------------------------------------------------------- |
| Backend          | [taurus-backend](https://github.com/taurus-ops/taurus-backend)       | [tracker](https://github.com/taurus-ops/taurus-backend/issues)        |
| Web              | [taurus-web](https://github.com/taurus-ops/taurus-web)               | [tracker](https://github.com/taurus-ops/taurus-web/issues)            |
| Executor         | [taurus-executor](https://github.com/taurus-ops/taurus-executor)     | [tracker](https://github.com/taurus-ops/taurus-executor/issues)       |
| Supervisor       | [taurus-supervisor](https://github.com/taurus-ops/taurus-supervisor) | [tracker](https://github.com/taurus-ops/taurus-supervisor/issues)     |
| Auth             | [taurus-auth](https://github.com/taurus-ops/taurus-auth)             | [tracker](https://github.com/taurus-ops/taurus-auth/issues)           |
| Scheduler        | [taurus-scheduler](https://github.com/taurus-ops/taurus-scheduler)   | [tracker](https://github.com/taurus-ops/taurus-scheduler/issues)      |
| **Stack (this)** | [taurus-stack](https://github.com/taurus-ops/taurus-stack)           | [discussions](https://github.com/taurus-ops/taurus-stack/discussions) |
