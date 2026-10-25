#!/usr/bin/env python3
"""Run silent native PocketTTS corpus generation using an existing test build."""
import argparse
import pathlib
import plistlib
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('xctestrun', type=pathlib.Path)
p.add_argument('output', type=pathlib.Path, help='New evidence directory; never overwritten')
a = p.parse_args()
source = a.xctestrun.resolve(strict=True)
output = a.output.resolve()
output.mkdir(parents=True, exist_ok=False)
# Moving a test plan changes __TESTROOT__; bind it to the original products.
def resolve(value):
    if isinstance(value, str):
        return value.replace('__TESTROOT__', str(source.parent))
    if isinstance(value, list):
        return [resolve(v) for v in value]
    if isinstance(value, dict):
        return {k: resolve(v) for k, v in value.items()}
    return value
plan = resolve(plistlib.loads(source.read_bytes()))
target = plan['CallGemmaTests']
target.setdefault('EnvironmentVariables', {}).update({
    'CALL_GEMMA_TEST_HOST': '1',
    'CALL_GEMMA_WAKE_CORPUS': str(output / 'corpus'),
})
target['OnlyTestIdentifiers'] = ['WakeCorpusQualificationTests/testGenerateContactVoiceCorpus']
target['TestTimeoutsEnabled'] = False
bound = output / 'corpus.xctestrun'
bound.write_bytes(plistlib.dumps(plan))
with (output / 'generation.log').open('xb') as log:
    subprocess.run(['xcodebuild', 'test-without-building', '-xctestrun', str(bound),
                    '-destination', 'platform=macOS,arch=arm64', '-parallel-testing-enabled', 'NO',
                    '-resultBundlePath', str(output / 'generation.xcresult')],
                   stdout=log, stderr=subprocess.STDOUT, check=True)
if not (output / 'corpus' / 'COMPLETE').is_file():
    raise SystemExit('Test finished without a complete corpus; inspect generation.log')
print(output / 'corpus')
