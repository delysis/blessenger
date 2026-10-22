"""Cancel observed participant handoffs in the muted 12B app, then redial."""
import argparse
import importlib.util
import json
import time
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('root', type=Path)
parser.add_argument('receipt', type=Path)
parser.add_argument('--fixture', type=Path, required=True)
args = parser.parse_args()
if args.receipt.exists():
    raise FileExistsError(args.receipt)
spec = importlib.util.spec_from_file_location('control', Path(__file__).with_name('blessenger-control.py'))
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)
events = []
args.receipt.parent.mkdir(parents=True, exist_ok=True)
def record(event):
    events.append(event)
    args.receipt.write_text(json.dumps(events, indent=2) + '\n')
def request(operation, **kwargs):
    try:
        result = control.request(args.root, dict(operation=operation, **kwargs), timeout=15)
    except Exception as error:
        record(dict(operation=operation, arguments=kwargs, error=str(error)))
        raise
    record(dict(operation=operation, arguments=kwargs, result=result))
    return result

def wait(predicate, timeout=90, interval=.15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        state = request('status')
        if predicate(state):
            return state
        time.sleep(interval)
    raise TimeoutError('Required app state not observed; preserved receipt')

def idle(s):
    return not s['inCall'] and not s['busy'] and not s['recovering'] and not s['responding'] and s['pendingTurns'] == 0 and s['participantHandoffs'] == 0

def histories():
    return {str(p.relative_to(args.root)): json.loads(json.loads(p.read_text())['historyJSON'])
            for p in (args.root/'Runtime'/'Contacts').glob('*/Calls/Conversations-v3/*/TRANSCRIPT')}

state = request('status')
assert state['ready'] and idle(state) and state['syntheticInput'] and state['outputMuted'] and '12B' in state['model'], state
contacts = request('contacts')['contacts']
peter = next(c['id'] for c in contacts if c['name'] == 'Peter Levine')
gabor = next(c['id'] for c in contacts if c['name'] == 'Gabor Maté')
chat = request('create_chat', contacts=[peter, gabor])['id']
request('select', id=chat)
checks=[]
for outgoing, incoming in [(peter,gabor),(gabor,peter)]:
    before = request('status')['completedTurns']
    request('call', id=outgoing)
    call = request('status')['callID']
    assert call
    def same_call(s):
        assert s['inCall'] and s['callID'] == call and s['selected'] == chat, s
        assert not any(word in s['notice'] for word in ['INTERNAL:', 'RESOURCE_EXHAUSTED:', 'No space']), s
    def greeted(s):
        same_call(s)
        return s['completedTurns'] > before and not s['responding'] and not s['recovering']
    try:
        wait(greeted)
        request('participant', id=incoming)
        request('inject_audio', path=str(args.fixture.resolve()))
        def switching(s):
            same_call(s)
            return s['participantHandoffs'] > 0
        observed = wait(switching, timeout=20, interval=.01)
    finally:
        request('hangup')
    settled = wait(idle)
    assert settled['ready'], settled
    saved = histories()
    # Wait across later callbacks and confirm canceled work cannot append history.
    time.sleep(1)
    assert idle(request('status'))
    assert histories() == saved, 'Late work mutated committed history after hangup settled'
    checks.append(dict(call=call, outgoing=outgoing, incoming=incoming, observed=observed, stable_history=True))
# A fresh greeting proves the final canceled handoff did not poison the engine.
before = request('status')['completedTurns']
request('call', id=peter)
try:
    wait(lambda s: s['inCall'] and s['completedTurns'] > before and not s['responding'] and not s['recovering'])
finally:
    request('hangup')
wait(idle)
record(dict(passed=True, checks=checks, scope='Actual muted 12B app cancellation of two observed handoffs, stable post-hangup history and subsequent pickup; not acoustic qualification'))
print('Two observed handoff cancellations and subsequent pickup passed')
