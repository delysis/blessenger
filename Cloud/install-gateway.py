#!/usr/bin/env python3
"""Install the user's outbound bridge as a login service; no credential files."""
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import time

root = pathlib.Path(__file__).resolve().parent
node = shutil.which('node')
if not node:
    raise SystemExit('Node.js is required')
label = 'com.blessenger.gateway'
folder = pathlib.Path.home() / 'Library/LaunchAgents'
logs = pathlib.Path.home() / 'Library/Logs/Blessenger'
folder.mkdir(parents=True, exist_ok=True)
logs.mkdir(parents=True, exist_ok=True)
plist = folder / (label + '.plist')
config = {
    'Label': label,
    'ProgramArguments': [node, str(root / 'mac-gateway.mjs')],
    'WorkingDirectory': str(root),
    'RunAtLoad': True,
    'KeepAlive': True,
    'ThrottleInterval': 30,
    'ProcessType': 'Background',
    'StandardOutPath': str(logs / 'gateway.log'),
    'StandardErrorPath': str(logs / 'gateway-error.log'),
}
domain = f'gui/{os.getuid()}'
existing = subprocess.run(['launchctl', 'print', f'{domain}/{label}'], capture_output=True)
unchanged = existing.returncode == 0 and plist.exists() and plistlib.loads(plist.read_bytes()) == config
if not unchanged:
    if existing.returncode == 0:
        subprocess.run(['launchctl', 'bootout', f'{domain}/{label}'], check=True)
        for _ in range(50):
            if subprocess.run(['launchctl', 'print', f'{domain}/{label}'], capture_output=True).returncode != 0:
                break
            time.sleep(0.1)
        else:
            raise SystemExit('Previous gateway is still stopping; no replacement started')
    plist.write_bytes(plistlib.dumps(config))
    plist.chmod(0o600)
    subprocess.run(['launchctl', 'bootstrap', domain, str(plist)], check=True)
print('Installed Blessenger gateway login service')

# Preserve the normal identity while selecting the deployed HTTPS QR route.
configuration = pathlib.Path.home() / 'Library/Application Support/Blessenger/Companion/configuration.json'
value = json.loads(configuration.read_text())
value['publicOrigin'] = 'https://blessenger.georgewalkeriv.workers.dev'
temporary = configuration.with_suffix('.json.tmp')
with open(temporary, 'w', opener=lambda path, flags: os.open(path, flags, 0o600)) as stream:
    json.dump(value, stream)
os.replace(temporary, configuration)
print('Selected HTTPS pairing address; restart the app when idle to refresh its QR')
