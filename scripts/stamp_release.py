"""Stamp one release identity into server templates and the compiled controller."""
from datetime import datetime, timezone
import json
from pathlib import Path
import tomllib

root = Path(__file__).resolve().parents[1]
version = tomllib.loads((root / 'backend/pyproject.toml').read_text())['project']['version']
now = datetime.now(timezone.utc)
metadata = {
    'version': version,
    'built_at': now.isoformat(timespec='seconds').replace('+00:00', 'Z'),
    'label': f"v{version} · {now.strftime('%d.%m.%Y %H:%M:%S UTC')}",
}
for path in ('shared/release.json', 'control/assets/release.json'):
    target = root / path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
print(metadata['label'])
