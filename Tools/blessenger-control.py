#!/usr/bin/env python3
"""CLI for an explicitly launched, isolated packaged Blessenger process.

Launch with BLESSENGER_QUALIFICATION_DIRECTORY=/absolute/run/path.
Commands never create a second controller or bypass the application's state machine.
No fixture run qualifies physical microphone acoustics or audible onset.
"""
import argparse
import json
import os
from pathlib import Path
import time
import uuid


def request(root, command, timeout=120):
    inbox = Path(root) / 'Commands'
    inbox.mkdir(parents=True, exist_ok=True, mode=0o700)
    stem = f'{time.time_ns()}-{uuid.uuid4()}'
    temporary = inbox / (stem + '.tmp')
    target = inbox / (stem + '.request')
    response = inbox / (stem + '.response')
    temporary.write_text(json.dumps(command))
    os.replace(temporary, target)
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if response.exists():
            value = json.loads(response.read_text())
            if not value['ok']:
                raise RuntimeError(value['error'])
            return value['result']
        time.sleep(.05)
    raise TimeoutError(f'No response to {command["operation"]}; preserved request {target}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('operation')
    parser.add_argument('--id')
    parser.add_argument('--contacts', nargs='+')
    parser.add_argument('--path')
    parser.add_argument('--text')
    parser.add_argument('--fraction', type=float)
    parser.add_argument('--timeout', type=float, default=120)
    args = vars(parser.parse_args())
    root = args.pop('directory')
    timeout = args.pop('timeout')
    print(json.dumps(request(root, {k: v for k, v in args.items() if v is not None}, timeout), indent=2))
