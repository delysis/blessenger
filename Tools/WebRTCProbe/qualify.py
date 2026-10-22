#!/usr/bin/env python3
"""Bounded macOS WebRTC API probe. Does not open microphone/speakers or call a persona."""
import argparse, hashlib, json, pathlib, shutil, subprocess, urllib.request, zipfile
parser = argparse.ArgumentParser()
parser.add_argument('work', type=pathlib.Path)
parser.add_argument('receipt', type=pathlib.Path)
parser.add_argument('--roundtrip', action='store_true', help='Exchange Opus PCM and control data between two native peers')
args = parser.parse_args()
root = args.work.resolve()
root.mkdir(parents=True, exist_ok=True)
version = '155.0.0'
expected = 'cb9adacf2d6bbf598d1d9e3e6c16d8fb97ca987b5b697746891828f9dc068ffe'
archive = root / 'WebRTC-M155.xcframework.zip'
if not archive.exists():
    with urllib.request.urlopen(f'https://github.com/stasel/WebRTC/releases/download/{version}/{archive.name}', timeout=60) as response:
        with archive.open('wb') as output:
            shutil.copyfileobj(response, output)
assert hashlib.sha256(archive.read_bytes()).hexdigest() == expected, 'Framework checksum mismatch'
frameworks = root / 'framework'
with zipfile.ZipFile(archive) as bundle:
    for member in bundle.infolist():
        assert (frameworks / member.filename).resolve().is_relative_to(frameworks.resolve()), 'Unsafe archive path'
    # ditto preserves framework symlinks, unlike Python ZipFile.extractall.
subprocess.run(['/usr/bin/ditto', '-x', '-k', str(archive), str(frameworks)], check=True)
base = frameworks / 'WebRTC.xcframework'
shutil.copyfile(base / 'ios-arm64/WebRTC.framework/Headers/RTCAudioDevice.h', root / 'RTCAudioDevice.h')
source = 'roundtrip.m' if args.roundtrip else 'probe.m'
shutil.copyfile(pathlib.Path(__file__).with_name(source), root / source)
if args.roundtrip:
    shutil.copyfile(pathlib.Path(__file__).with_name('ProbeSupport.h'), root / 'ProbeSupport.h')
mac = base / 'macos-x86_64_arm64'
subprocess.run(['clang', '-fobjc-arc', '-fmodules', '-framework', 'Foundation', '-framework', 'AudioToolbox',
                '-F', str(mac), '-framework', 'WebRTC', '-Wl,-rpath,' + str(mac),
                str(root / source), '-o', str(root / 'probe')], check=True)
result = subprocess.run([str(root / 'probe')], capture_output=True, text=True, timeout=25)
args.receipt.parent.mkdir(parents=True, exist_ok=True)
args.receipt.write_text(json.dumps({'frameworkVersion':version,'archiveSHA256':expected,
    'sourceSHA256':hashlib.sha256((root/source).read_bytes()).hexdigest(),
    'supportSHA256':hashlib.sha256((root/'ProbeSupport.h').read_bytes()).hexdigest() if args.roundtrip else None,
    'exitCode':result.returncode, 'stderr':result.stderr,
    'result':json.loads(result.stdout) if args.roundtrip and result.stdout.startswith('{') else result.stdout.strip(),
    'scope':'native Opus PCM and data-channel roundtrip' if args.roundtrip else 'custom audio-device initialization, PCM callbacks, Opus SDP offer',
    'notVerified':(['browser interoperability','iPhone playback','ICE restart','TURN relay','app integration'] if args.roundtrip else
                   ['peer-to-peer connection','PCM encode/decode roundtrip','iPhone playback','ICE restart','TURN relay','app integration'])},indent=2)+'\n')
print(result.stdout.strip())
raise SystemExit(result.returncode)
