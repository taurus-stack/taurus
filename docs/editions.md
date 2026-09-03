# Community vs Enterprise Edition — Separation Design

[中文](editions.zh-CN.md)

## Table of Contents

1. [Edition Feature Boundary](#edition-feature-boundary)
2. [Dual-Condition Gate](#dual-condition-gate)
3. [Physical Separation](#physical-separation)
4. [License Security Model](#license-security-model)
5. [Why This Design](#why-this-design)

---

## Edition Feature Boundary

Taurus Stack defines 77 feature codes. Each edition ships with a fixed subset:

| Edition | Feature Codes | Count |
|---------|--------------|-------|
| **Community** | Subset — core host management, basic command execution, simple workflow | 37 |
| **Enterprise** | All 77 — includes Approval, HA, Multi-Host, Scheduler HA, Notification, etc. | 77 |

See `taurus/editions/features.py` for the complete `ALL_FEATURE_CODES` list. Each feature is a `UPPER_SNAKE_CASE` constant:

```python
# Example EE-only codes
F_APPROVAL_WORKFLOW
F_HA_SCHEDULER
F_NOTIFICATION_WEBHOOK
F_PROGRAM_INSTALL_POLICY
F_SCRIPT_PERMISSION_BASIC
...
```

---

## Dual-Condition Gate

The edition check is a **two-layer AND** gate — both must pass:

```python
# taurus/editions/loader.py

class EditionGate:
    def has_feature(self, feature_code: str) -> bool:
        if self.name == "enterprise":
            lic = self.edition.license_status
            if not lic.get("valid"):
                return False  # Layer 2: license must be valid
        return self.edition.has_feature(feature_code)  # Layer 1: edition must own the feature
```

**Why two layers?** Layer 1 (edition name) is checked at import time. Layer 2 (license validity) is checked at runtime. An attacker who copies `taurus_ee/` into the CE repo gets Layer 1 but fails Layer 2 — because they can't forge the RSA signature.

### Settings Discovery

```python
# taurus-backend/application/settings.py
INSTALLED_APPS = [
    ...standard Django apps...,
    *(["taurus_ee"] if importlib.util.find_spec("taurus_ee") else []),
]
```

Django auto-discovers `taurus_ee` by filesystem presence. If the package isn't installed (CE mode), `find_spec` returns None and `taurus_ee` is excluded from `INSTALLED_APPS`. No import errors, no runtime crashes.

### Thin Wrapper Pattern

Views and Serializers use a consistent `try/except ImportError` pattern:

```python
# taurus/serializers.py

class _ScriptApprovalSerializer(BaseSerializer):
    """Thin Wrapper — EE implementation lives in taurus_ee."""
    try:
        from taurus_ee.serializers.script_approval import (
            _EEScriptApprovalSerializer,
        )
    except ImportError:
        _EEScriptApprovalSerializer = None

    def __init__(self, *args, **kwargs):
        if self._EEScriptApprovalSerializer is None:
            raise EEFeatureNotAvailable("Script Approval requires Enterprise Edition")
        super().__init__(*args, **kwargs)
```

This pattern is repeated ~16 times in `views.py` and ~10 times in `serializers.py`. Each wrapper has a corresponding stub in `taurus/ee_fallback.py`.

---

## Physical Separation

```
taurus-stack/                              ← CE git repo (public)
├── taurus-backend/
│   ├── taurus/
│   │   ├── editions/                     ← Both CE & EE logic here
│   │   ├── ee_fallback.py                ← Stub for missing taurus_ee
│   │   └── views.py / serializers.py     ← Thin wrappers
│   └── .gitignore: taurus_ee/
│
├── taurus_ee/                             ← EE git repo (PRIVATE)
│   ├── license.py                        ← RSA-PSS-SHA256 verify ONLY
│   ├── apps.py
│   ├── services/ approval/ ha/ notification/
│   ├── workflow_units/
│   └── management/commands/
│
└── scripts/license_signer.py              ← Issuer (gitignored, private)
    └── scripts/secrets/license_signer_privkey.pem
```

**CE repo permanently excludes**:
- `taurus_ee/` — the entire enterprise package
- `scripts/license_signer.py` — signing tool
- `scripts/secrets/*.pem` — private signing key
- `taurus-backend/certs/*.key` — CA private key

**Zero leakage guarantee**: A `git add .` on a fresh CE clone will never include `.key`, `.pem`, signing code, or `taurus_ee/`. Verified by running `git ls-files | grep -E '\.(key|pem)$|taurus_ee|license_signer'` after initial commit — returns empty.

### Distribution

| Target | How | What's Inside |
|--------|-----|---------------|
| **Open source CE** | `git clone taurus-stack` | Everything except `taurus_ee/` |
| **EE Customer** | `pip install taurus_ee-*.whl` | Same code + `taurus_ee/` packaged as wheel |
| **Signed License** | Issuer → Email to customer | `.lic` file (JSON + RSA signature) |

EE wheel is optionally PyArmor/Cython-obfuscated at build time. Even if unobfuscated, `license.py` is **verify-only** — it contains an RSA public key but no signing code.

---

## License Security Model

### Issuer Side (Private Signing Server)

```bash
# One-time setup
openssl genrsa -out license_signer_privkey.pem 2048
openssl rsa -in license_signer_privkey.pem -pubout -out license_signer_pubkey.pem

# Deploy: private key only on signing server (chmod 600, gitignored)
# Embed public key into taurus_ee/license.py (_PUBLIC_KEY_PEM constant)
```

### License Issuance

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

Signer generates JSON payload:

```json
{
  "customer_id": "CUST-001",
  "customer_name": "Acme Corp",
  "tier": "professional",
  "issued_at": "2026-09-03T00:00:00Z",
  "expires_at": "2027-09-03T00:00:00Z",
  "features": ["APPROVAL_WORKFLOW", "HA_SCHEDULER", ...],
  "quota": {"max_hosts": 500, "max_users": 100, "max_scheduled_tasks": 500},
  "machine_fp": null
}
```

Then signs with `RSA-PSS-SHA256`. The signature is computed over `json.dumps(payload, sort_keys=True, separators=(",", ":"))` — canonicalized JSON guarantees consistent signatures.

### License Verification (taurus_ee/license.py)

```python
def verify_license_file(path: Path) -> LicenseStatus:
    raw = path.read_bytes()
    data = json.loads(raw)
    payload = data["payload"]       # JSON string
    signature = b64decode(data["signature"])

    # 1. RSA-PSS-SHA256 signature check
    verify_signature(payload.encode(), signature)  # raises on mismatch

    # 2. Expiration check
    if expires_at < now:
        raise LicenseExpired(...)

    # 3. Machine fingerprint match (optional, if bound)
    if machine_fp and machine_fp != compute_machine_fingerprint():
        raise LicenseMachineMismatch(...)

    return LicenseStatus(valid=True, ...)
```

### Anti-Tampering Properties

| Attack | Mitigation |
|--------|------------|
| Modify `expires_at` to extend validity | RSA signature covers the entire payload — any byte change invalidates the signature |
| Modify `features` list | Same — signature check fails |
| Copy wheel + bypass check in code | `has_feature()` is the single gate point, called everywhere. Cannot bypass without modifying both `loader.py` and re-signing the entire wheel (which requires obfuscation cracking) |
| Extract signing key from wheel | **Impossible**. Wheel contains only the RSA public key, not the private key. Signing code lives in `scripts/license_signer.py` which is never distributed. |
| Virtual machine migration (if `machine_fp` bound) | `machine_fp` is computed from hostname + primary MAC + `/etc/machine-id`. Changing any of these breaks the fingerprint match. |

### Management Commands

```bash
# Check current license status
python manage.py license_status
python manage.py license_status --json

# Import a signed license file
python manage.py license_import ./license.lic --force

# Auto-discovery search order for .lic files:
#   $TAURUS_LICENSE_FILE env → /etc/taurus/license.lic
#   → /opt/taurus/license.lic → ~/.taurus/license.lic → ./license.lic
```

### Debug Bypass (Dev Only)

During development you can bypass license checks:

```bash
export TAURUS_DEV_BYPASS_LICENSE=1
python manage.py runserver ...
```

This is **not a security hole** — it's a development convenience. In production deployment, this env var is never set.

---

## Why This Design

### What We Considered

| Approach | Security | Complexity | Cost | Chosen? |
|----------|----------|------------|------|---------|
| 1. Feature flags in DB | Weak (editable) | Low | Low | ❌ |
| 2. `if os.path.exists("/etc/enterprise")` | None (trivial bypass) | Low | Low | ❌ |
| 3. Single repo, EE code split into submodule | Medium (git submodule can be cloned) | Medium | Low | ❌ |
| 4. Private wheel + code obfuscation only | Weak (can be decompiled) | Medium | Medium | ❌ |
| 5. **Private wheel + RSA-PSS-SHA256 signed License + Dual-Condition Gate** | **Strong** | **Medium-High** | **Medium** | **✅** |

### Why It's Strong

- **Private key never leaves issuer**: `license_signer_privkey.pem` exists only on the signing server. Never in any repo, never in any wheel.
- **Verify-only in customer code**: `taurus_ee/license.py` has zero signing code. Customers cannot forge licenses even if they crack wheel obfuscation.
- **Two-layer gate**: Edition name alone is insufficient. Both `edition == "enterprise"` AND `license.valid == True` must pass.
- **Tamper-resistant signature**: Any modification to the license payload invalidates the RSA-PSS signature.
- **Machine fingerprint (optional)**: Can tie a license to a specific physical machine.
- **Lazy loading**: License is loaded once per process, cached. File changes require `invalidate_cache()` or restart.

### Attack Surface Analysis

| Attack Vector | Difficulty | Defense |
|--------------|------------|---------|
| Reverse-engineer wheel to find signing code | Impossible — it's not there | Verify-only design |
| Extract RSA private key from wheel | Impossible — only public key exists | Cryptographic split |
| Modify expires_at in .lic | Impossible — signature covers entire payload | RSA-PSS-SHA256 |
| Modify features list | Impossible — same as above | RSA-PSS-SHA256 |
| Patch Python binary to skip signature check | Easy but detectable | Not our problem (binary-level attack) |
| Replace `loader.py` to remove gate | Easy but requires source access | PyArmor/Cython obfuscation in release |
| Find side-channel (API returns EE features despite gate) | Hard — gate is called at every feature check | Consistent `has_feature()` usage |
