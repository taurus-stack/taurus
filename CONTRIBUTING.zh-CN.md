# Taurus Stack 贡献指南

[English](CONTRIBUTING.md)

感谢你对 Taurus Stack 的贡献兴趣！本项目是多仓库架构，本文档说明跨仓库开发的工作方式。

## 仓库布局

本仓库是 **git submodule 聚合仓库**，各服务独立仓库：

```
taurus-stack/                      ← 根仓库（submodule 聚合）
├── taurus-backend/     [submodule]    Django 4.2 + dvadmin
├── taurus-web/         [submodule]    Vue 3 + TypeScript
├── taurus-executor/    [submodule]    Python + gRPC
├── taurus-supervisor/  [submodule]    Python + asyncio
├── taurus-auth/        [submodule]    Django 票据服务
├── taurus-scheduler/   [submodule]    APScheduler
└── taurus_ee/          [私有]         企业版（不公开）
```

## 开发环境搭建

```bash
# 克隆（带 submodule）
git clone --recurse-submodules https://github.com/taurus-ops/taurus-stack.git
cd taurus-stack

# 每个 submodule 独立安装依赖
cd taurus-backend && poetry install && cd ..
cd taurus-web && pnpm install && cd ..
```

各服务专属搭建指南见对应子仓库 `README.md`。

## 分支策略

Trunk-based 工作流 + feature 分支：

```
main (主干，始终可部署)
  ├── feature/host-bulk-delete
  ├── fix/session-stream-crash
  └── docs/add-api-examples
```

**规则**:
- 禁止直接 commit 到 `main` — 必须走 PR
- Feature 分支必须包含对应测试
- 每个 PR 需要 Code Review + CI 通过

## 开发流程

### 1. 找准仓库

| 想改什么 | 哪个仓库 |
|----------|----------|
| API、Model、业务逻辑 | `taurus-backend` |
| UI、组件、页面 | `taurus-web` |
| 远程执行、gRPC 协议 | `taurus-executor` |
| 主机守护、心跳、程序生命周期 | `taurus-supervisor` |
| 票据鉴权、JWT | `taurus-auth` |
| 定时任务派发、HA 选举 | `taurus-scheduler` |
| **企业版专属** | `taurus_ee`（私有仓库） |

### 2. 创建分支开发

```bash
# 进入子仓库（不是根仓库）
cd taurus-backend

# 创建分支
git checkout -b feature/add-bulk-host-delete

# 开发 + 测试
poetry run pytest tests/test_host_bulk.py

# 提交（子仓库内）
git add .
git commit -m "feat(host): add bulk delete endpoint"
git push -u origin feature/add-bulk-host-delete

# 回到根仓库，更新 submodule 指针
cd ..
git add taurus-backend
git commit -m "chore: update taurus-backend submodule"
git push
```

### 3. 别忘记更新 submodule 指针

子仓库 push 后，**必须**在根仓库 commit 指针变更。否则队友看不到你的代码。

```bash
cd ..                                    # 回根仓库
git add taurus-backend                   # stage 指针更新
git commit -m "chore: bump taurus-backend to abc1234"
git push
```

## 代码风格

### Python

```
80 字符/行，4 空格缩进
Black + isort 格式化
ruff 代码检查
mypy 类型检查
Poetry 依赖管理
Python 3.12+
```

执行: `poetry run ruff check && poetry run black --check .`

### TypeScript / Vue

```
2 空格缩进
ESLint + Prettier
Vitest 测试
pnpm 依赖管理
```

执行: `pnpm run lint && pnpm run test`

### Commit Message

Conventional Commits 格式：

```
type(scope): description

feat(host): add bulk delete endpoint
fix(session): prevent stream crash on EOF
docs(api): add examples for /api/taurus/hosts/
refactor(workflow): extract DAG validation into separate module
test(auth): add ticket expiration test
chore(deps): bump cryptography from 42.0 to 43.0
```

| 类型 | 说明 |
|------|------|
| `feat` | 新用户功能 |
| `fix` | Bug 修复 |
| `docs` | 文档 |
| `style` | 格式调整，不改逻辑 |
| `refactor` | 代码重构 |
| `perf` | 性能优化 |
| `test` | 添加/修复测试 |
| `build` | 构建系统/外部依赖 |
| `ci` | CI/CD 配置 |
| `chore` | 杂项 |

## 测试

### Push 前最低检查

```bash
# Backend
cd taurus-backend
poetry run python manage.py check         # Django system check
poetry run pytest tests/                  # 单元测试

# Frontend
cd taurus-web
pnpm run test

# Executor
cd taurus-executor
poetry run pytest tests/unit/
```

### 测试位置

| 仓库 | 路径 | 框架 |
|------|------|------|
| taurus-backend | `tests/` | pytest + pytest-django |
| taurus-web | `tests/` 或 colocated | Vitest |
| taurus-executor | `tests/unit/`, `tests/integration/` | pytest + pytest-asyncio |
| taurus-supervisor | `tests/` | pytest + pytest-asyncio |
| taurus-auth | `tests/` | pytest + pytest-django |

### 测试命名

```python
def test_<场景>_<预期行为>():
    pass

# 示例
def test_host_bulk_delete_without_permission_returns_403():
    ...
def test_session_stream_on_eof_closes_gracefully():
    ...
```

## 安全注意事项

### 永不提交密钥

```bash
# 错误！
git commit -m "fix(db): update connection string"
# conf/env.py 里包含了真实密码！

# 正确
cp conf/env.example.py conf/env.py   # gitignored
git commit conf/env.example.py       # 只提交模板
```

提交前检查：

```bash
git diff --cached | grep -i 'password\|secret\|key\|token'
```

### 证书处理

- `taurus-backend/certs/*.key` — 始终 gitignored，永不分发
- CA 证书 `ca.crt` — 可提交（公开证书）
- Client 证书 — 每次部署生成，永不提交

### License 系统

如果修改 `taurus/editions/` 或 `taurus_ee/`：

1. **禁止** 在 CE 可达路径中添加签发代码
2. **禁止** 提交私钥
3. **必须** 验证双条件 Gate 正常：
   ```bash
   TAURUS_DEV_BYPASS_LICENSE=1 python manage.py license_status --json
   ```

### 安全漏洞报告

请**不要**在公开 Issue 中报告安全问题。联系 [security@taurus-ops.local]。

## FAQ

**Q: 需要所有 submodule 才能运行吗？**
A: 不用。最小集：`taurus-backend` + `taurus-web` + `taurus-auth`。

**Q: 没有私有仓库能开发 EE 功能吗？**
A: 可以。在 `taurus/ee_fallback.py` 写 stub，在 `views.py`/`serializers.py` 写薄封装。Gate 后面的 EE 实现在私有仓库——CE 测试验证 Gate 工作正常。

**Q: 为什么两个 Django 服务（backend, auth）？**
A: Auth 独立出来是安全设计。Executor 直接通过 HTTP 验证 Auth 的执行票据——不共享数据库，Executor 和 Backend 之间无信任边界。

**Q: 没有 executor 能单独跑 backend 吗？**
A: 可以。开发时设 `TAURUS_DEV_BYPASS_EXECUTOR=1` 或用 mock executor client。

---

## License

贡献代码意味着同意你的贡献按照项目的 GNU AGPLv3（社区版）或专有商业 License（企业版）授权，取决于你贡献的仓库。
