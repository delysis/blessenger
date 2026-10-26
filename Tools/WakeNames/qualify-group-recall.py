#!/usr/bin/env python3
"""Check named, bidirectional factual recall in an isolated packaged 12B app.

Uses macOS Samantha speech at device rate, muted output, ordinary contact prompts,
and the normally accepted enrollment. This is not physical-speaker acceptance.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import time
import wave

spec = importlib.util.spec_from_file_location('control', Path(__file__).resolve().parents[1] / 'blessenger-control.py')
ctl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ctl)
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('directory', type=Path)
a = p.parse_args()
root = a.directory.resolve()
receipt = root / 'group-recall.json'
if receipt.exists() or list((root / 'Runtime/Contacts').glob('*/Calls/Conversations-v3/*/TRANSCRIPT')):
    raise SystemExit('Use a fresh isolated app directory; preserve previous runs')
journey, checks, answers, fixtures = [], [], [], []
owned_call = None

def cmd(operation, **args):
    result = ctl.request(root, dict(operation=operation, **args), timeout=15)
    journey.append(dict(time=time.time(), operation=operation, arguments=args, result=result))
    (root / 'group-recall-journey.json').write_text(json.dumps(journey, indent=2))
    return result

def wait(predicate, live=False, limit=120):
    end = time.monotonic() + limit
    while time.monotonic() < end:
        state = cmd('status')
        if live and (not state['inCall'] or state['callID'] != owned_call):
            raise RuntimeError('Unexpected call termination or replacement')
        if predicate(state):
            return state
        time.sleep(.5)
    raise TimeoutError(json.dumps(state))

def idle(s):
    return not s['dialing'] and not s['responding'] and not s['recovering'] and not s['pendingTurns'] and not s['fixtureRemainingFrames']

def synthesize(key, text):
    aiff, wav = root / (key + '.aiff'), root / (key + '.wav')
    subprocess.run(['say', '-v', 'Samantha', '-o', str(aiff), text], check=True)
    subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16@16000', '-c', '1', str(aiff), str(wav)], check=True)
    with wave.open(str(wav), 'rb') as f:
        params, pcm = f.getparams(), f.readframes(f.getnframes())
    with wave.open(str(wav), 'wb') as f:
        f.setparams(params)
        f.writeframes(pcm + bytes(32000))
    fixtures.append(dict(key=key, text=text, sha256=hashlib.sha256(wav.read_bytes()).hexdigest()))
    return wav

def replies(contact):
    paths = list((root / 'Runtime/Contacts' / contact / 'Calls/Conversations-v3').glob('*/TRANSCRIPT'))
    if not paths:
        return []
    if len(paths) != 1:
        raise RuntimeError('Ambiguous persona transcript')
    history = json.loads(json.loads(paths[0].read_text())['historyJSON'])
    return [''.join(c.get('text', '') for c in m['content'] if isinstance(c, dict))
            for m in history if m['role'] == 'assistant']

def inject(wav, expected):
    before = cmd('status')['completedTurns']
    count = len(replies(expected))
    cmd('inject_audio', path=str(wav))
    state = wait(lambda s: idle(s) and s['completedTurns'] > before, live=True)
    assert state['participant'].lower() == expected.lower(), ('Wrong recipient', state)
    after = replies(expected)
    assert len(after) > count, 'No new reply from the intended participant'
    answers.append(dict(contact=expected, fixture=wav.name, reply=after[-1]))
    return after[-1]

def words(text):
    return re.findall(r"[a-z]+", text.lower())

def assert_recall(chosen, recalled):
    # Require an explicit short source answer; never use a semantic judge or
    # count the same persona answering twice as cross-participant recall.
    key = words(chosen)
    while key and key[0] in ('a', 'an', 'the'):
        key.pop(0)
    assert 1 <= len(key) <= 3, ('Source answer was not an unambiguous short choice', chosen)
    target = words(recalled)
    assert any(target[i:i + len(key)] == key for i in range(len(target))), (chosen, recalled)

try:
    state = wait(lambda s: s['ready'] and not s['busy'])
    assert state['syntheticInput'] and state['outputMuted'] and not state['inCall'], state
    assert state['model'] == 'litert-community/gemma-4-12B-it-litert-lm', state
    for _ in range(120):
        wake = cmd('wake_status')
        if wake['ready']:
            break
        time.sleep(.5)
    assert wake['ready'], 'Accepted wake model did not load'
    people = cmd('contacts')['contacts']
    peter, gabor = [next(c['id'] for c in people if c['name'] == n) for n in ['Peter Levine', 'Gabor Maté']]
    choice = synthesize('animal-choice', 'Peter, choose one unusual animal. Say only its name.')
    recall = synthesize('animal-recall', 'Gabor, what animal did Peter just choose?')
    other = synthesize('instrument-choice', 'Gabor, choose one unusual musical instrument. Say only its name.')
    back = synthesize('instrument-recall', 'Peter, what musical instrument did Gabor just choose?')
    thread = cmd('create_chat', contacts=[peter, gabor])['id']
    cmd('call', id=peter)
    owned_call = wait(lambda s: s['inCall'])['callID']
    state = wait(idle, live=True)
    assert state['callWakeFingerprint'] == wake['fingerprint'], 'Call froze a different or absent wake model'
    checks.append('Packaged 12B call froze the accepted wake model')
    selected = inject(choice, peter)
    repeated = inject(recall, gabor)
    assert_recall(selected, repeated)
    checks.append('Gabor recalled the animal Peter actually chose')
    selected = inject(other, gabor)
    repeated = inject(back, peter)
    assert_recall(selected, repeated)
    checks.append('Peter recalled the instrument Gabor actually chose')
    cmd('hangup')
    wait(lambda s: not s['inCall'] and not s['busy'])
    owned_call = None
    assert cmd('create_chat', contacts=[gabor, peter])['id'] == thread
    checks.append('Hang-up completed; reverse roster reused the group')
    trace = [json.loads(line) for line in (root / 'Diagnostics/latency.jsonl').read_text().splitlines()]
    failures = [e for batch in trace for e in batch.get('events', []) if e['event'] == 'turn.failed']
    assert not failures, failures
    checks.append('No failed turn hidden by later recovery')
    passed, error = True, None
except Exception as exc:
    passed, error = False, str(exc)
finally:
    if owned_call:
        state = cmd('status')
        if state['inCall'] and state['callID'] == owned_call:
            cmd('hangup')
            wait(lambda s: not s['inCall'] and not s['busy'])
    receipt.write_text(json.dumps(dict(passed=passed, error=error, checks=checks, answers=answers,
        fixtures=fixtures, scope='Packaged 12B app; unfamiliar synthesized speech, muted output. No physical echo acceptance.'), indent=2))
print(receipt.read_text())
raise SystemExit(0 if passed else 1)
