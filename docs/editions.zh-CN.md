# 社区版 vs 企业版 — 分离设计

[English](editions.md)

## 目录

1. [Feature 边界](#feature-边界)
2. [双条件 Gate](#双条件-gate)
3. [物理分离](#物理分离)
4. [License 安全模型](#license-安全模型)
5. [设计考量](#设计考量)

---

## Feature 边界

Taurus Stack 定义 77 个 feature code。每个 Edition 携带一个固定子集：

| Edition | Feature Code | 数量 |
|---------|--------------|------|
| **社区版** | 核心主机管理、基础命令执行、简单工作流 | 37 |
| **企业版** | 全 77 个 — 含审批、HA、多主机、HA 调度、通知等 | 77 |

完整列表见 `taurus/editions/features.py`。每个 feature 是 `UPPER_SNAKE_CASE` 常量：

```python
# 企业版专属示例
F_APPROVAL_WORKFLOW
F_HA_SCHEDULER
F_NOTIFICATION_WEBHOOK
F_PROGRAM_INSTALL_POLICY
F_SCRIPT_PERMISSION_BASIC
...
```

---

## 双条件 Gate

Edition 检查是**两层 AND** 门控——必须同时满足：

```python
# taurus/editions/loader.py

class EditionGate:
    def has_feature(self, feature_code: str) -> bool:
        if self.name == "enterprise":
            lic = self.edition.license_status
            if not lic.get("valid"):
                return False   # 第二层：License 必须有效
        return self.edition.has_feature(feature_code)  # 第一层：Edition 必须持有该 Feature
```

**为什么两层？** 第一层（edition name）在 import 时确定。第二层（license validity）在运行时检查。攻击者就算把 `taurus_ee/` 拷进 CE 仓库能过第一层，但过不了第二层——因为 RSA 签名无法伪造。

### Django 自动发现

```python
# taurus-backend/application/settings.py
INSTALLED_APPS = [
    ...,
    *(["taurus_ee"] if importlib.util.find_spec("taurus_ee") else []),
]
```

Django 通过文件系统 presence 自动发现 `taurus_ee`。CE 模式下包未安装 → `find_spec` 返回 None → `taurus_ee` 不出现在 `INSTALLED_APPS`。无 import 错误、无运行时崩溃。

### Thin Wrapper 模式

Views 和 Serializers 统一使用 `try/except ImportError` 模式：

```python
# taurus/serializers.py

class _ScriptApprovalSerializer(BaseSerializer):
    """Thin Wrapper — EE 实现在 taurus_ee。"""
    try:
        from taurus_ee.serializers.script_approval import (
            _EEScriptApprovalSerializer,
        )
    except ImportError:
        _EEScriptApprovalSerializer = None

    def __init__(self, *args, **kwargs):
        if self._EEScriptApprovalSerializer is None:
            raise EEFeatureNotAvailable("Script Approval 需要企业版")
        super().__init__(*args, **kwargs)
```

此模式在 `views.py` 中约 16 处、`serializers.py` 中约 10 处。每个 wrapper 对应 `taurus/ee_fallback.py` 中的 stub。

---

## 物理分离

```
taurus-stack/                              ← CE git 仓库（公开）
├── taurus-backend/
│   ├── taurus/
│   │   ├── editions/                     ← CE + EE 逻辑都在这里
│   │   ├── ee_fallback.py                ← 缺 taurus_ee 时的 stub
│   │   └── views.py / serializers.py     ← try/except 薄封装
│   └── .gitignore: taurus_ee/
│
├── taurus_ee/                             ← EE git 仓库（私有）
│   ├── license.py                        ← RSA-PSS-SHA256 纯验签
│   ├── apps.py
│   ├── services/ 审批/HA/通知/
│   ├── workflow_units/
│   └── management/commands/
│
└── scripts/license_signer.py              ← 签发器（gitignored，内部）
    └── scripts/secrets/license_signer_privkey.pem
```

**CE 仓库永久排除**：
- `taurus_ee/` — 整个企业版包
- `scripts/license_signer.py` — 签发工具
- `scripts/secrets/*.pem` — 签发私钥
- `taurus-backend/certs/*.key` — CA 私钥

**零泄露保证**：`git add .` 在 CE 克隆中永远不会包含 `.key`、`.pem`、签发代码或 `taurus_ee/`。首次 commit 后验证 `git ls-files | grep -E '\.(key|pem)$|taurus_ee|license_signer'` — 返回空。

### 分发方式

| 目标 | 方式 | 内容 |
|------|------|------|
| **开源 CE** | `git clone taurus-stack` | 除 `taurus_ee/` 外全部 |
| **EE 客户** | `pip install taurus_ee-*.whl` | 同样代码 + `taurus_ee/` 打包为 wheel |
| **签名 License** | 签发服务器 → 邮件客户 | `.lic` 文件（JSON + RSA 签名） |

EE wheel 可在构建时用 PyArmor/Cython 混淆。即使不混淆，`license.py` 也是**纯验签**——只有 RSA 公钥在里面，无签发代码。

---

## License 安全模型

### 签发端（私有签名服务器）

```bash
# 一次性密钥生成
openssl genrsa -out license_signer_privkey.pem 2048
openssl rsa -in license_signer_privkey.pem -pubout -out license_signer_pubkey.pem

# 部署：私钥只在签发服务器（chmod 600, gitignored）
# 公钥嵌入 taurus_ee/license.py (_PUBLIC_KEY_PEM 常量)
```

### License 签发

```bash
export TAURUS_SIGNER_PRIVKEY_PATH=/path/to/privkey.pem

python scripts/license_signer.py issue \
    --customer-id CUST-001 \
    --customer-name "Acme Corp" \
    --tier professional \
    --days 365 \
    --max-hosts 500 \
    --max-users 100 \
    --output /tmp/acme.lic
```

签发器生成 JSON payload：

```json
{
  "customer_id": "CUST-001",
  "customer_name": "Acme Corp",
  "tier": "professional",
  "issued_at": "2026-09-03T00:00:00Z",
  "expires_at": "2027-09-03T00:00:00Z",
  "features": ["APPROVAL_WORKFLOW", "HA_SCHEDULER", "..."],
  "quota": {"max_hosts": 500, "max_users": 100, "max_scheduled_tasks": 500},
  "machine_fp": null
}
```

然后用 `RSA-PSS-SHA256` 签名。签名覆盖 `json.dumps(payload, sort_keys=True, separators=(",", ":"))` —— 规范化 JSON 保证签名一致。

### License 验签 (taurus_ee/license.py)

```python
def verify_license_file(path: Path) -> LicenseStatus:
    raw = path.read_bytes()
    data = json.loads(raw)
    payload = data["payload"]       # JSON 字符串
    signature = b64decode(data["signature"])

    # 1. RSA-PSS-SHA256 签名检查
    verify_signature(payload.encode(), signature)  # 不匹配抛异常

    # 2. 过期检查
    if expires_at < now:
        raise LicenseExpired(...)

    # 3. 机器指纹匹配（可选，如果绑定）
    if machine_fp and machine_fp != compute_machine_fingerprint():
        raise LicenseMachineMismatch(...)

    return LicenseStatus(valid=True, ...)
```

### 防篡改能力

| 攻击 | 防御 |
|------|------|
| 修改 `expires_at` 续期 | RSA 签名覆盖整个 payload — 任何字节改变签名失效 |
| 修改 `features` 列表 | 同上 — 签名检查失败 |
| 拷 wheel + 绕过代码检查 | `has_feature()` 是单点 gate，被所有地方调用 |
| 从 wheel 提取私钥 | **不可能**。wheel 只有 RSA 公钥，无私钥。签发代码在 `scripts/license_signer.py` 从不分发 |
| 虚拟机迁移（如果绑定 `machine_fp`） | `machine_fp` 由 hostname + 主 MAC + `/etc/machine-id` 计算。任一改变破坏匹配 |

### Management Commands

```bash
# 查看当前 License 状态
python manage.py license_status
python manage.py license_status --json

# 导入签名 License
python manage.py license_import ./license.lic --force

# .lic 文件自动搜索顺序：
#   $TAURUS_LICENSE_FILE → /etc/taurus/license.lic
#   → /opt/taurus/license.lic → ~/.taurus/license.lic → ./license.lic
```

### 开发旁路

开发时可跳过验签：

```bash
export TAURUS_DEV_BYPASS_LICENSE=1
python manage.py runserver ...
```

**不是安全漏洞**——仅开发便利。生产部署中此变量永不设置。

---

## 设计考量

### 方案对比

| 方案 | 安全 | 复杂度 | 成本 | 选择 |
|------|------|--------|------|------|
| 1. DB feature flags | 弱（可编辑） | 低 | 低 | ❌ |
| 2. `if os.path.exists("/etc/enterprise")` | 无（秒破） | 低 | 低 | ❌ |
| 3. 单仓库 submodule | 中（submodule 可克隆） | 中 | 低 | ❌ |
| 4. 私有 wheel + 代码混淆 | 弱（可反编译） | 中 | 中 | ❌ |
| 5. **私有 wheel + RSA 签名 License + 双条件 Gate** | **强** | **中高** | **中** | **✅** |

### 为什么这个方案够强

- **私钥不出签发服务器**：`license_signer_privkey.pem` 只在签发服务器存在。任何仓库、任何 wheel 都没有。
- **客户代码纯验签**：`taurus_ee/license.py` 零签发代码。客户就算破解 wheel 混淆也无法伪造 License。
- **双门控**：Edition name 不够。必须 `edition == "enterprise"` **且** `license.valid == True` 同时通过。
- **签名防篡改**：payload 任何字节改变 → RSA-PSS 签名失效。
- **可选机器绑定**：可将 License 锁死到特定物理机器。
- **惰性加载 + 缓存**：License 进程内加载一次，文件变更需 `invalidate_cache()` 或重启。

### 攻击面分析

| 攻击向量 | 难度 | 防御 |
|----------|------|------|
| 逆向 wheel 找签发代码 | 不可能 — 根本没有 | 纯验签设计 |
| 从 wheel 提取 RSA 私钥 | 不可能 — 只有公钥 | 密码学分离 |
| 修改 .lic 里的 expires_at | 不可能 — 签名覆盖整个 payload | RSA-PSS-SHA256 |
| 修改 features 列表 | 不可能 — 同上 | RSA-PSS-SHA256 |
| 二进制层 patch 跳过签名检查 | 简单但要物理访问 | 不属于应用层威胁（OS 层攻击） |
| 替换 loader.py 去掉 gate | 简单但需要源码 | Release 版 PyArmor/Cython 混淆 |
| 找 API 侧信道返回 EE 特性 | 困难 — 每次检查都走 gate | 统一 has_feature() 调用 |
