#!/usr/bin/env python3
"""Package the runtime's platform-specific dependency as an iOS framework.

Keep the upstream dylib bytes in the source checkout; only packaged copies have
install names changed. iOS apps embed frameworks, not loose non-system dylibs.
"""
import hashlib
import json
import pathlib
import plistlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
native = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root / '.build/native/patched/LiteRT-LM'
name = 'GemmaModelConstraintProvider'
install_name = f'@rpath/{name}.framework/{name}'
package = root / f'Vendor/{name}.xcframework'
package.mkdir(parents=True, exist_ok=True)
libraries = []
identities = {}
for slice_name, prebuilt, platform in [
    ('ios-arm64', 'ios_arm64', 'iPhoneOS'),
    ('ios-arm64-simulator', 'ios_sim_arm64', 'iPhoneSimulator'),
]:
    framework = package / slice_name / f'{name}.framework'
    framework.mkdir(parents=True, exist_ok=True)
    binary = framework / name
    binary.write_bytes((native / 'prebuilt' / prebuilt / f'lib{name}.dylib').read_bytes())
    binary.chmod(0o755)
    subprocess.run(['install_name_tool', '-id', install_name, str(binary)], check=True)
    info = dict(CFBundleExecutable=name, CFBundleIdentifier='local.blessenger.' + name,
                CFBundleName=name, CFBundlePackageType='FMWK', CFBundleVersion='1',
                CFBundleShortVersionString='1.0', MinimumOSVersion='15.0',
                CFBundleSupportedPlatforms=[platform])
    (framework / 'Info.plist').write_bytes(plistlib.dumps(info))
    runtime = root / 'Vendor/CLiteRTLM.xcframework' / slice_name / 'CLiteRTLM.framework/CLiteRTLM'
    subprocess.run(['install_name_tool', '-change', f'@rpath/lib{name}.dylib', install_name, str(runtime)], check=True)
    for target in [framework, runtime.parent]:
        subprocess.run(['codesign', '--force', '--sign', '-', str(target)], check=True)
    item = dict(LibraryIdentifier=slice_name, LibraryPath=f'{name}.framework',
                SupportedArchitectures=['arm64'], SupportedPlatform='ios')
    if platform == 'iPhoneSimulator':
        item['SupportedPlatformVariant'] = 'simulator'
    libraries.append(item)
    for file in [binary, runtime, framework / 'Info.plist']:
        identities[str(file.relative_to(root / 'Vendor'))] = hashlib.sha256(file.read_bytes()).hexdigest()
(package / 'Info.plist').write_bytes(plistlib.dumps(dict(
    AvailableLibraries=libraries, CFBundlePackageType='XFWK', XCFrameworkFormatVersion='1.0')))
manifest = json.dumps(identities, sort_keys=True, indent=2).encode()
(root / 'Vendor/runtime-ios-files.json').write_bytes(manifest)
(root / 'Sources/CallGemma/Resources/runtime-ios.json').write_text(json.dumps(
    {'sha256': hashlib.sha256(manifest).hexdigest()}) + '\n')
