#!/usr/bin/env python3
"""Install pinned corrected PocketTTS exports without a Python ML toolchain."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(data)
    return h.hexdigest()

def install(root, manifest, archive):
    if archive.stat().st_size != manifest['bytes'] or digest(archive) != manifest['sha256']:
        raise ValueError('Speech archive does not match pinned size and SHA-256')
    with tempfile.TemporaryDirectory(prefix='blessenger-speech-') as temporary:
        stage = Path(temporary)
        with tarfile.open(archive, 'r:gz') as tar:
            names = set()
            for member in tar:
                name = member.name
                if name not in manifest['files'] or name in names or not member.isfile():
                    raise ValueError('Unexpected archive member: ' + name)
                if Path(name).is_absolute() or '..' in Path(name).parts:
                    raise ValueError('Unsafe archive path')
                names.add(name)
                path = stage / name
                path.parent.mkdir(parents=True, exist_ok=True)
                with tar.extractfile(member) as source, path.open('wb') as target:
                    shutil.copyfileobj(source, target)
                if digest(path) != manifest['files'][name]:
                    raise ValueError('Speech asset failed verification: ' + name)
            if names != set(manifest['files']):
                raise ValueError('Incomplete speech archive')
        # Check every conflict before installing anything. Never replace local edits.
        for name, expected in manifest['files'].items():
            target = root / name
            if target.exists() and (not target.is_file() or digest(target) != expected):
                raise ValueError('Existing asset differs; preserve it and resolve explicitly: ' + str(target))
        for name in sorted(names):
            target = root / name
            if target.exists():
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            fd, temporary = tempfile.mkstemp(prefix='.speech-', dir=target.parent)
            try:
                with os.fdopen(fd, 'wb') as output, (stage / name).open('rb') as source:
                    shutil.copyfileobj(source, output)
                os.replace(temporary, target)
            finally:
                if os.path.exists(temporary): os.unlink(temporary)
    print('Verified and installed', len(manifest['files']), 'speech asset files')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', type=Path, help='Use an already downloaded pinned archive')
    args = parser.parse_args()
    manifest = json.loads((ROOT / 'Tools/speech-assets.json').read_text())
    if args.archive:
        install(ROOT, manifest, args.archive.resolve())
        return
    with tempfile.TemporaryDirectory(prefix='blessenger-download-') as temp:
        archive = Path(temp) / 'speech.tar.gz'
        print('Downloading pinned speech assets:', manifest['bytes'], 'bytes', flush=True)
        with archive.open('wb') as dest:
            for index, part in enumerate(manifest['parts']):
                print('Downloading part', index + 1, 'of', len(manifest['parts']), flush=True)
                with urllib.request.urlopen(part['url'], timeout=120) as source:
                    data = source.read(part['bytes'] + 1)
                if len(data) != part['bytes'] or hashlib.sha256(data).hexdigest() != part['sha256']:
                    raise ValueError('Speech archive part failed verification')
                dest.write(data)
        install(ROOT, manifest, archive)

if __name__ == '__main__': main()
