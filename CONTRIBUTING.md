# Contributing to Taurus Stack

[中文](CONTRIBUTING.zh-CN.md)

First off: **thank you for considering contributing**! Taurus Stack is a multi-repository project — this guide explains how development works across all services.

## Repository Layout

This is an **aggregate repository** using `git submodule`. Each service lives in its own repo:

```
taurus-stack/                      ← Root (this repo, submodule aggregate)
├── taurus-backend/     [submodule]    Django 4.2 + dvadmin
├── taurus-web/         [submodule]    Vue 3 + TypeScript
├── taurus-executor/    [submodule]    Python + gRPC
├── taurus-supervisor/  [submodule]    Python + asyncio
├── taurus-auth/        [submodule]    Django ticket service
├── taurus-scheduler/   [submodule]    APScheduler
└── taurus_ee/          [private]      Enterprise Edition (not public)
```

## Development Environment Setup

```bash
# Clone with submodules
git clone --recurse-submodules https://github.com/taurus-ops/taurus-stack.git
cd taurus-stack

# Each submodule has its own dependency management
cd taurus-backend && poetry install && cd ..
cd taurus-web && pnpm install && cd ..
```

See each submodule's `README.md` for service-specific setup instructions.

## Branch Strategy

We follow a trunk-based workflow with feature branches:

```
main (trunk, always deployable)
  ├── feature/host-bulk-delete
  ├── fix/session-stream-crash
  └── docs/add-api-examples
```

**Rules**:
- Direct commits to `main` are forbidden — always open PRs
- Feature branches must include tests for changed behavior
- Each PR requires Code Review + CI pass

## Making Changes

### 1. Find the right repository

| What you want to change | Repository |
|------------------------|------------|
| API endpoints, models, business logic | `taurus-backend` |
| UI, components, pages | `taurus-web` |
| Remote command execution, gRPC protocol | `taurus-executor` |
| Host daemon, heartbeat, program lifecycle | `taurus-supervisor` |
| Ticket authentication, JWT | `taurus-auth` |
| Scheduled task dispatch, HA election | `taurus-scheduler` |
| **Enterprise-only features** | `taurus_ee` (private repo) |

### 2. Create a feature branch

```bash
# Navigate to the submodule (NOT root repo)
cd taurus-backend

# Create branch
git checkout -b feature/add-bulk-host-delete

# Make changes, write tests
poetry run pytest tests/test_host_bulk.py

# Commit (submodule repo)
git add .
git commit -m "feat(host): add bulk delete endpoint"
git push -u origin feature/add-bulk-host-delete

# Go back to root, update submodule pointer
cd ..
git add taurus-backend
git commit -m "chore: update taurus-backend submodule"
git push
```

### 3. Keep the submodule pointer updated

After committing in a submodule, you MUST commit the pointer change in the root repo. Otherwise, teammates won't see your update.

```bash
# After pushing to submodule remote
cd ..                                    # back to root
git add taurus-backend                   # stage the pointer update
git commit -m "chore: bump taurus-backend to abc1234"
git push
```

## Code Style

### Python

```
80 chars / line, 4-space indent, no tabs
Black + isort for formatting
ruff for linting
mypy for type checking
Poetry for dependency management
Python 3.12+ (match minimum version in pyproject.toml)
```

Run: `poetry run ruff check && poetry run black --check .`

### TypeScript / Vue

```
2-space indent
ESLint + Prettier
Vitest for tests
pnpm for dependency management
```

Run: `pnpm run lint && pnpm run test`

### Commit Messages

Conventional Commits format:

```
type(scope): description

feat(host): add bulk delete endpoint
fix(session): prevent stream crash on EOF
docs(api): add examples for /api/taurus/hosts/
refactor(workflow): extract DAG validation into separate module
test(auth): add ticket expiration test
chore(deps): bump cryptography from 42.0 to 43.0
```

| Type | Description |
|------|-------------|
| `feat` | New user-facing feature |
| `fix` | Bug fix |
| `docs` | Documentation |
| `style` | Formatting, no code change |
| `refactor` | Code restructuring |
| `perf` | Performance improvement |
| `test` | Adding or fixing tests |
| `build` | Build system or external deps |
| `ci` | CI/CD configuration |
| `chore` | Miscellaneous |

## Testing

### Before pushing: minimum check

```bash
# Backend
cd taurus-backend
poetry run python manage.py check         # Django system check
poetry run pytest tests/                  # Unit tests

# Frontend
cd taurus-web
pnpm run test

# Executor
cd taurus-executor
poetry run pytest tests/unit/
```

### Where tests live

| Repo | Path | Framework |
|------|------|-----------|
| taurus-backend | `tests/` | pytest + pytest-django |
| taurus-web | `tests/` or colocated | Vitest |
| taurus-executor | `tests/unit/`, `tests/integration/` | pytest + pytest-asyncio |
| taurus-supervisor | `tests/` | pytest + pytest-asyncio |
| taurus-auth | `tests/` | pytest + pytest-django |

### Test naming

```python
def test_<scenario>_<expected_behavior>():
    pass

# Example
def test_host_bulk_delete_without_permission_returns_403():
    ...
def test_session_stream_on_eof_closes_gracefully():
    ...
```

## Security Considerations

### Never commit secrets

```bash
# WRONG
git commit -m "fix(db): update connection string"
# includes real password in conf/env.py!

# CORRECT
cp conf/env.example.py conf/env.py   # gitignored
git commit conf/env.example.py       # template only
```

Check before commit:

```bash
# Search for accidentally included secrets
git diff --cached | grep -i 'password\|secret\|key\|token'
```

### Certificate handling

- `taurus-backend/certs/*.key` — always gitignored, never distribute
- CA certificate `ca.crt` — safe to commit (public)
- Client certificates — generated per deployment, never committed

### License system

If you touch `taurus/editions/` or `taurus_ee/`:

1. **Never** add signing code to CE-reachable paths
2. **Never** commit private keys
3. **Always** verify the dual-condition gate works:
   ```bash
   TAURUS_DEV_BYPASS_LICENSE=1 python manage.py license_status --json
   ```

### Reporting security issues

Please **do not open public issues** for security vulnerabilities. Contact us at [security@taurus-ops.local].

## FAQ

**Q: Do I need all submodules to run?**
A: No. Minimum working set: `taurus-backend` + `taurus-web` + `taurus-auth`.

**Q: Can I work on EE features without the private repo?**
A: Yes. Write stubs in `taurus/ee_fallback.py` and thin wrappers in `views.py`/`serializers.py`. The EE implementation lives behind the gate — CE tests verify the gate works, EE tests live in the private repo.

**Q: Why are there two Django apps (taurus-backend, taurus-auth)?**
A: Auth is isolated for security. Executor verifies execution tickets directly with Auth via HTTP — no shared database, no trust boundary between executor and backend.

**Q: How do I run just the backend without executor?**
A: `TAURUS_DEV_BYPASS_EXECUTOR=1` (for development only) or use a mock executor client.

---

## License

By contributing, you agree that your contributions will be licensed under the project's GNU AGPLv3 (Community) or proprietary commercial license (Enterprise), depending on which repository you contribute to.
