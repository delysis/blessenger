"""Actual-app, muted synthetic-input check; not acoustic qualification."""
import importlib.util
import json
import re
import wave
import shutil
from pathlib import Path
import sys
import time
spec = importlib.util.spec_from_file_location('control', str(Path(__file__).with_name('blessenger-control.py')))
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)
import argparse
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('root', type=Path)
parser.add_argument('receipt', type=Path)
parser.add_argument('--fixtures', required=True, type=Path, help='Directory containing peter-age.wav and gabor-recall.wav')
args = parser.parse_args()
root = args.root
receipt = args.receipt
receipt.parent.mkdir(parents=True, exist_ok=True)
events = []
expected_chat = None
if receipt.exists():
    raise FileExistsError('Refusing to overwrite existing test evidence: ' + str(receipt))
def request(operation, **kwargs):
    result = control.request(root, dict(operation=operation, **kwargs), timeout=15)
    events.append(dict(operation=operation, arguments=kwargs, result=result, disk_free_bytes=shutil.disk_usage(root).free))
    receipt.write_text(json.dumps(events, indent=2) + '\n')
    if operation == 'status' and expected_chat is not None:
        assert result['selected'] == expected_chat, ('Selected chat changed outside the scripted journey', expected_chat, result)
    return result

def wait(predicate, timeout=90):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        status = request('status')
        if predicate(status):
            return status
        time.sleep(1)
    raise TimeoutError('App failed to reach required state; receipt preserved')

status = wait(lambda s: s['ready'] and not s['busy'])
assert '12B' in status['model'] and status['syntheticInput'] and status['outputMuted'] and not status['inCall'], status
contacts = request('contacts')['contacts']
peter = next(c['id'] for c in contacts if c['name'] == 'Peter Levine')
gabor = next(c['id'] for c in contacts if c['name'] == 'Gabor Maté')
chat = request('create_chat', contacts=[peter,gabor])['id']
request('select', id=chat)
expected_chat = chat
def transcript(contact):
    files = list((root/'Runtime'/'Contacts'/contact/'Calls'/'Conversations-v3').glob('*/TRANSCRIPT'))
    if not files: return []
    assert len(files) == 1
    return json.loads(json.loads(files[0].read_text())['historyJSON'])
offsets = {peter: len(transcript(peter)), gabor: len(transcript(gabor))}
greeting_before = request('status')['completedTurns']
request('call', id=peter)
def finish_turn(before):
    def complete(s):
        assert s['inCall'], 'Unexpected disconnect'
        assert not any(t in s.get('notice','') for t in ['INTERNAL:', 'RESOURCE_EXHAUSTED:', 'No space']), s
        return s['completedTurns'] > before and not s['responding'] and not s['recovering'] and s['pendingTurns'] == 0
    return wait(complete)
marker = '[Shared call context: quoted conversation, not a new request.]'
def imported(message): return message.get('content') and message['content'][0].get('text') == marker
checks=[]
active=peter
try:
    finish_turn(greeting_before)
    for contact, fixture in [(peter,'peter-age.wav'),(gabor,'gabor-recall.wav'),(peter,'peter-age.wav'),(gabor,'gabor-recall.wav')]:
        source = [m for m in transcript(active)[offsets[active]:] if not imported(m)]
        incoming_before = len(transcript(contact))
        request('participant', id=contact)
        before = request('status')['completedTurns']
        audio = args.fixtures/fixture
        with wave.open(str(audio),'rb') as w: duration=w.getnframes()/w.getframerate()
        request('inject_audio', path=str(audio.resolve()))
        time.sleep(duration+.3)
        state = finish_turn(before)
        assert state['participant'] == contact, state
        if contact != active:
            incoming = transcript(contact)
            blocks = [m for m in incoming[incoming_before:] if imported(m)]
            assert len(blocks)==1, ('Missing or duplicate imported context', blocks)
            parts=blocks[0]['content'][1:]
            islabel=lambda p:bool(re.match(r'^\[Call [0-9A-Fa-f-]{36}\.',p.get('text','')))
            actual=[p for p in parts if not islabel(p)]
            expected=[p for m in source for p in m['content']]
            assert actual==expected, 'Shared context differs from committed outgoing messages'
            assert all(active in p['text'] for p in parts if islabel(p))
            assert not any(p.get('text')==marker for p in actual), 'Recursive context export'
            offsets[active]=len(transcript(active))
            offsets[contact]=incoming_before+1
            checks.append(dict(outgoing=active,incoming=contact,imported=blocks[0],exact=True))
        active=contact
finally:
    request('hangup')
wait(lambda s:not s['inCall'] and not s['busy'] and not s['recovering'])
events.append(dict(passed=True,checks=checks,scope='Actual muted 12B app three handoffs and hangup; exact context attribution, no acoustic qualification'))
receipt.write_text(json.dumps(events,indent=2)+'\n')
print('Three exact handoffs and hangup passed')
