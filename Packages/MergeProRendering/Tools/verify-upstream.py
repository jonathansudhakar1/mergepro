#!/usr/bin/env python3
"""Verify narrowly vendored upstream provenance; no network or source generation."""
import hashlib
import json
from pathlib import Path
root = Path(__file__).resolve().parents[1]
entries = json.loads((root / 'upstream-inventory.json').read_text())
for entry in entries:
    path = root / entry['path']
    assert path.is_file(), entry['path']
    assert hashlib.sha256(path.read_bytes()).hexdigest() == entry['sha256'], entry['path']
app_owned = {
    'Vendor/javascript/include/javascript.h', 'Vendor/python/include/python.h',
    'Vendor/yaml/include/yaml.h', 'Vendor/json/include/json.h',
    'Vendor/typescript/include/typescript.h', 'Vendor/typescript/tsx-include/tsx.h',
    'Vendor/oniguruma/src/config.h',
}
covered = {entry['path'] for entry in entries} | app_owned
extra = {str(path.relative_to(root)) for path in (root / 'Vendor').rglob('*') if path.is_file()} - covered
assert not extra, sorted(extra)
print(f'Verified {len(entries)} upstream hashes; {len(app_owned)} separately identified application-owned headers/config files.')
