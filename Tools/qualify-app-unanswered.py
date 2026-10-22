#!/usr/bin/env python3
"""Check confirmed-but-unheard input in a running, muted qualification app.

Run once with --fixture to cancel a confirmed input before playback. After the
app has been quit and relaunched, run with --resume-receipt pointing to that
receipt to check exact preservation and the next call. This does not qualify
speaker acoustics. Both modes use the app controller and real model.
"""
import importlib.util
import json
import argparse
import time
from pathlib import Path

spec = importlib.util.spec_from_file_location("control", Path(__file__).with_name("blessenger-control.py"))
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
parser.add_argument("receipt", type=Path)
mode = parser.add_mutually_exclusive_group(required=True)
mode.add_argument("--fixture", type=Path)
mode.add_argument("--resume-receipt", type=Path)
args = parser.parse_args()
root = args.directory.resolve()
receipt = args.receipt
if receipt.exists():
    parser.error("Choose a new receipt path; previous runs are preserved")
fixture = args.fixture.resolve() if args.fixture else None
events = []

def save():
    receipt.write_text(json.dumps(events, indent=2))

def request(operation, **arguments):
    result = control.request(root, dict(operation=operation, **arguments), timeout=15)
    events.append(dict(operation=operation, result=result))
    save()
    return result

def wait(predicate, seconds=60):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        state = request("status")
        if predicate(state):
            return state
        time.sleep(.2)
    raise AssertionError("App state did not settle")

state = wait(lambda s: s["ready"] and not s["busy"])
assert state["outputMuted"] and state["syntheticInput"] and not state["inCall"]
contact = "51F43A46-D1AB-5F92-A9B1-E08CCBD61C82"
if args.resume_receipt:
    previous = json.loads(args.resume_receipt.read_text())[-1]
    assert previous.get("passed") is True
    transcript = Path(previous["transcript"])
    assert transcript.is_relative_to(root), "Receipt belongs to another app root"
    def history():
        return json.loads(json.loads(transcript.read_text())["historyJSON"])
    assert history() == previous["history"], "History changed across relaunch"
    request("select", id=contact)
    request("call", id=contact)
    try:
        wait(lambda s: s["inCall"] and s["completedTurns"] > 0 and not s["responding"])
    finally:
        request("hangup")
    wait(lambda s: not s["inCall"] and not s["busy"] and not s["recovering"])
    current = history()
    assert current[:len(previous["history"])] == previous["history"]
    assert len(current) == len(previous["history"]) + 2
    assert current[-1]["role"] == "assistant"
    events.append(dict(passed=True, history=current, scope="Relaunch and subsequent call"))
    save()
    raise SystemExit(0)
request("create_chat", contacts=[contact])
request("select", id=contact)
request("call", id=contact)
try:
    wait(lambda s: s["inCall"] and s["completedTurns"] > 0 and not s["responding"])
    request("inject_audio", path=str(fixture))
    deadline = time.monotonic() + 20
    pending_path = None
    while time.monotonic() < deadline and pending_path is None:
        for path in (root / "Runtime").rglob("PENDING-SPEECH"):
            try:
                pending = json.loads(path.read_text())
            except (FileNotFoundError, json.JSONDecodeError):
                continue
            if pending.get("speculative", False):
                continue
            user = json.loads(pending["userJSON"])
            if not any(part.get("type") == "audio" for part in user["content"]):
                continue
            assert all(segment["playedFrames"] == 0 for segment in pending["segments"]), "Missed cancellation window"
            pending_path = path
            events.append(dict(confirmedPending=pending, path=str(path)))
            save()
            break
        time.sleep(.005)
    assert pending_path is not None, "No confirmed user input observed"
finally:
    request("hangup")
wait(lambda s: not s["inCall"] and not s["busy"] and not s["recovering"])
record = json.loads((pending_path.parent / "TRANSCRIPT").read_text())
history = json.loads(record["historyJSON"])
assert history[-1] == user, "Cancellation lost user input or published an unheard answer"
events.append(dict(passed=True, transcript=str(pending_path.parent / "TRANSCRIPT"), history=history))
save()
