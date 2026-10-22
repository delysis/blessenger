#!/usr/bin/env python3
"""Package an explicit browser-runtime allowlist; never ship diagnostic pages."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import uuid

def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()

root = Path(__file__).resolve().parents[1]
destination = Path(sys.argv[1]) if len(sys.argv) == 2 else Path(os.environ['TARGET_BUILD_DIR']) / os.environ['UNLOCALIZED_RESOURCES_FOLDER_PATH'] / 'Browser'
speech = root / 'Browser/PocketTTS'
names = ['LICENSE-APACHE', 'LICENSE-MIT', 'blessenger-speech.mjs', 'playback.mjs',
         'speech-seed.mjs', 'reference.mjs', 'index.js', 'device.js', 'fetch.js', 'hub.js', 'simd.js', 'threads.js',
         'wav.js', 'worker.js', 'wasm/phonon_tts.js', 'wasm/phonon_tts_bg.wasm',
         'model/model.safetensors', 'model/config.json', 'model/tokenizer.json', 'model/voices.json']
voices = json.loads((speech / 'model/voices.json').read_text())['voices']
if len(voices) != 14 or len({voice['contact'] for voice in voices}) != 14:
    raise ValueError('Expected fourteen distinct contact voices')
for voice in voices:
    contact = str(uuid.UUID(voice['contact']))
    names.append(f'model/voices/{contact}.safetensors')
files = {f'PocketTTS/{name}': speech / name for name in names}
files['Earshot/earshot.mjs'] = root / 'Browser/Earshot/earshot.mjs'
files['Earshot/earshot.wasm'] = root / 'Browser/Earshot/target/wasm32-unknown-unknown/release/blessenger_browser_vad.wasm'
files['RTC/remote-audio.mjs'] = root / 'Browser/RTC/remote-audio.mjs'
records = {}
for name, source in files.items():
    digest = sha256(source)
    records[name] = {'sha256': digest, 'bytes': source.stat().st_size}
    target = destination / name
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists() or sha256(target) != digest:
        shutil.copy2(source, target)
encoded = json.dumps(records, sort_keys=True, separators=(',', ':')).encode()
manifest = {'revision': hashlib.sha256(encoded).hexdigest(), 'files': records}
(destination / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f'Packaged {len(records)} browser assets ({sum(r["bytes"] for r in records.values())} bytes)')
