#!/usr/bin/env python3
"""Repeated interruption regression in an isolated packaged app.
Synthetic PCM and muted output do not qualify speaker echo cancellation.
"""
import argparse
import importlib.util
import json
import time
from pathlib import Path

spec = importlib.util.spec_from_file_location("control", Path(__file__).with_name("blessenger-control.py"))
control = importlib.util.module_from_spec(spec)
spec.loader.exec_module(control)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
parser.add_argument("--question", type=Path, required=True)
args = parser.parse_args()
root = args.directory.resolve()
receipt = root / "prefix-reuse-result.json"
checks = []

def command(operation, **fields):
    result = control.request(root, dict(operation=operation, **fields), timeout=15)
    with (root / "prefix-reuse-journey.jsonl").open("a") as file:
        file.write(json.dumps(dict(time=time.time(), operation=operation, result=result)) + "\n")
    return result

def wait(predicate, seconds=90, live=False):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        status = command("status")
        if live and not status["inCall"]:
            raise AssertionError("Unexpected disconnect: " + json.dumps(status))
        if predicate(status):
            return status
        time.sleep(.1)
    raise AssertionError("Timed out: " + json.dumps(status))

def events():
    records = []
    for path in (root / "Diagnostics").glob("latency*.jsonl"):
        records.extend(json.loads(line) for line in path.read_text().splitlines())
    return sorted((event for record in records for event in record["events"]), key=lambda e: int(e["uptime_ns"]))

start = max((int(e["uptime_ns"]) for e in events()), default=0)
try:
    status = wait(lambda s: s["ready"] and not s["busy"])
    assert status["syntheticInput"] and status["outputMuted"], status
    assert status["model"] == "litert-community/gemma-4-12B-it-litert-lm", status
    contact = next(p["id"] for p in command("contacts")["contacts"] if p["name"] == "Gabor Maté")
    command("create_chat", contacts=[contact])
    command("call", id=contact)
    wait(lambda s: not s["dialing"] and not s["responding"] and not s["recovering"], live=True)
    command("inject_audio", path=str(args.question.resolve()))
    # Interrupt three replies after speech begins. Each interruption must retain
    # the already canonical prefix, even when the next response is interrupted.
    for index in range(3):
        wait(lambda s: s["status"] == "Speaking", live=True)
        time.sleep(.15)
        command("inject_audio", path=str(args.question.resolve()))
        wait(lambda s: s["recovering"] or s["status"] != "Speaking", live=True)
    wait(lambda s: not s["responding"] and not s["recovering"] and not s["pendingTurns"], live=True)
    command("hangup")
    wait(lambda s: not s["inCall"] and not s["busy"])
    # Flushes are asynchronous; wait for the call-stop receipt, not a fixed sleep.
    deadline = time.monotonic() + 10
    while not any(e["event"] == "capture.stop" and int(e["uptime_ns"]) > start for e in events()):
        assert time.monotonic() < deadline, "Missing call-stop trace"
        time.sleep(.1)
    selected = [e for e in events() if int(e["uptime_ns"]) > start and e["event"] == "checkpoint.prefix_selected"]
    replays = 0
    previous = 0
    for event in selected:
        cached, canonical = int(event["cached_messages"]), int(event["canonical_messages"])
        assert cached >= previous, f"Replayed an already rebuilt prefix: {event}; required {previous} messages"
        if canonical > cached:
            replays += 1
            previous = canonical
    assert replays >= 2, f"Did not exercise repeated recovery: {selected}"
    checks.append("At least two interrupted-prefix rebuilds; subsequent restores include all previously rebuilt messages")
    receipt.write_text(json.dumps(dict(passed=True, checks=checks, prefixes=selected, scope="packaged 12B app, synthetic PCM, muted"), indent=2))
except Exception as error:
    receipt.write_text(json.dumps(dict(passed=False, checks=checks, error=str(error)), indent=2))
    raise
finally:
    command("hangup")
