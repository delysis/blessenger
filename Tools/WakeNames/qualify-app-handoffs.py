#!/usr/bin/env python3
"""Exercise named handoffs through the packaged app's real call controller.

Requires an isolated synthetic-input launch and a validated, normally enrolled
head. Never installs a model or overrides its acceptance flag. Acoustic and
human interruption acceptance are explicitly outside this test's scope.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import time
import wave

spec = importlib.util.spec_from_file_location('control', Path(__file__).resolve().parents[1] / 'blessenger-control.py')
ctl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ctl)
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('directory', type=Path)
p.add_argument('corpus', type=Path)
p.add_argument('--exact-only', action='store_true', help='Verify decoded complete names while approximate enrollment is unavailable')
a = p.parse_args()
root, corpus = a.directory.resolve(), a.corpus.resolve()
receipt = root / 'wake-handoffs.json'
if receipt.exists():
    raise SystemExit('Preserve the prior receipt; use a new isolated run directory')
rows = json.loads((corpus / 'manifest.json').read_text())
checks, events = [], []
owned_call = None

def cmd(operation, **args):
    value = ctl.request(root, dict(operation=operation, **args), timeout=30)
    events.append(dict(time=time.time(), operation=operation, arguments=args, result=value))
    (root / 'wake-journey.json').write_text(json.dumps(events, indent=2))
    return value

def wait(predicate, seconds=120, live=False):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        state = cmd('status')
        if live and (not state['inCall'] or state['callID'] != owned_call):
            raise RuntimeError('Unexpected call termination or replacement: ' + json.dumps(state))
        if predicate(state):
            return state
        time.sleep(.2)
    raise TimeoutError(json.dumps(state))

def idle():
    return wait(lambda s: not s['dialing'] and not s['responding'] and not s['recovering'] and not s['pendingTurns'], live=True)

def inject(text):
    row = next(r for r in rows if r['text'] == text and r['voice'] == 'judith_herman')
    source = corpus / row['path']
    target = root / ('input-' + str(len(events)) + '.wav')
    with wave.open(str(source), 'rb') as audio:
        assert (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) == (16000, 1, 2)
        pcm = audio.readframes(audio.getnframes())
    # Input clock runs at device rate; retain the whole fixture plus settling.
    with wave.open(str(target), 'wb') as audio:
        audio.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
        audio.writeframes(pcm + bytes(32000))
    cmd('inject_audio', path=str(target))
    return len(pcm) / 32000 + 1

try:
    state = wait(lambda s: s['ready'] and not s['busy'])
    assert not state['inCall'], 'Do not take over an existing call'
    assert state['syntheticInput'] and state['outputMuted'], state
    assert state['model'] == 'litert-community/gemma-4-12B-it-litert-lm', state
    wake = cmd('wake_status')
    assert not wake['ready'] if a.exact_only else wake['ready'], wake
    checks.append('Exact names without approximate enrollment' if a.exact_only else 'Validated approximate enrollment loaded')
    people = cmd('contacts')['contacts']
    peter, gabor = [next(c['id'] for c in people if c['name'] == name) for name in ['Peter Levine', 'Gabor Maté']]
    thread = cmd('create_chat', contacts=[peter, gabor])['id']
    cmd('call', id=peter)
    owned_call = wait(lambda s: s['inCall'])['callID']
    started = idle()
    assert started['callWakeFingerprint'] == wake['fingerprint'], 'Call did not freeze the qualified wake model'
    checks.append('12B group greeting completed')
    for text, expected in [('Could you speak more slowly?', peter), ('Hey Gabor.', gabor), ('Hey Peter.', peter)]:
        before = idle()['completedTurns']
        duration = inject(text)
        time.sleep(duration)
        result = wait(lambda s: s['completedTurns'] > before and not s['responding'] and not s['pendingTurns'] and not s['recovering'], live=True)
        assert result['participant'].lower() == expected.lower(), (text, result)
        checks.append('Correct recipient after ' + text)
    # Cancel an actual generated reply with a differently addressed utterance.
    before = idle()['completedTurns']
    inject('Peter, what do you think?')
    wait(lambda s: s['responding'] and s['fixtureRemainingFrames'] == 0, live=True)
    time.sleep(inject('Hey Gabor.'))
    result = wait(lambda s: s['participant'].lower() == gabor.lower() and s['completedTurns'] > before and not s['responding'] and not s['pendingTurns'] and not s['recovering'], live=True)
    checks.append('Named interruption completed and call stayed connected')
    cmd('hangup')
    wait(lambda s: not s['inCall'] and not s['busy'])
    owned_call = None
    checks.append('Explicit hang-up released the call')
    assert cmd('create_chat', contacts=[gabor, peter])['id'] == thread, 'Duplicate group thread'
    cmd('call', id=gabor)
    owned_call = wait(lambda s: s['inCall'])['callID']
    idle()
    before = cmd('status')['completedTurns']
    time.sleep(inject('Hey Peter.'))
    wait(lambda s: s['participant'].lower() == peter.lower() and s['completedTurns'] > before and not s['responding'] and not s['pendingTurns'], live=True)
    checks.append('Repeated group call and reverse handoff completed')
    passed, error = True, None
except Exception as exception:
    passed, error = False, str(exception)
finally:
    if owned_call is not None:
        current = cmd('status')
        if current['inCall'] and current['callID'] == owned_call:
            cmd('hangup')
            wait(lambda s: not s['inCall'] and not s['busy'])
    receipt.write_text(json.dumps(dict(passed=passed, checks=checks, error=error,
        scope='Actual packaged 12B app, held-out synthetic speaker at device rate, muted output; no physical echo or human barge-in claim'), indent=2))
print(receipt.read_text())
raise SystemExit(0 if passed else 1)
