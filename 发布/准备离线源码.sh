#!/bin/bash
# 仅用于已解压的源码候选包；从随包公共上游 bundle 恢复固定引擎身份。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="$ROOT/ThirdParty/ntfs-3g"
PIN=7f0f841fc52cf719106c5c93bafe465004e36816
if [[ -e "$ENGINE/.git" ]]; then
  [[ "$(git -C "$ENGINE" rev-parse HEAD)" == "$PIN" ]] || { echo '既有引擎仓库版本不符，停止。' >&2; exit 1; }
  echo '固定版本引擎仓库已就绪。'
  exit 0
fi
[[ -f "$ROOT/ThirdParty/ntfs-3g.bundle" ]] || { echo '缺少随包的公共引擎 bundle。' >&2; exit 1; }
# 验证文件没有被修改，再恢复 Git 元数据；不会重置或覆盖源码。
python3 - "$ROOT" <<'PY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]); manifest=json.loads((root/'源码清单.json').read_text())
for name, record in manifest['文件'].items():
 if name.startswith('ThirdParty/ntfs-3g/') or name=='ThirdParty/ntfs-3g.bundle':
  if hashlib.sha256((root/name).read_bytes()).hexdigest()!=record['SHA256']:
   raise SystemExit('源码或bundle哈希不匹配，停止：'+name)
PY
git -C "$ENGINE" init -q
git -C "$ENGINE" fetch -q "$ROOT/ThirdParty/ntfs-3g.bundle" "$PIN"
git -C "$ENGINE" reset --mixed -q "$PIN"
git -C "$ENGINE" diff --quiet
git -C "$ENGINE" diff --cached --quiet
echo '固定版本源码身份已离线恢复；可按 README 构建。'
