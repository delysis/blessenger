#!/usr/bin/env python3
"""Loopback-only diagnostic signaling bridge. Never routes real microphone audio."""
import argparse, json, subprocess, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('binary', type=Path)
parser.add_argument('--port', type=int, default=8952)
args = parser.parse_args()
root = Path(__file__).resolve().parent
lock = threading.Lock()
process = None
result = None
origin = f'http://127.0.0.1:{args.port}'

class Handler(BaseHTTPRequestHandler):
    def reply(self, status, body, mime='application/json'):
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.headers.get('Host') != f'127.0.0.1:{args.port}':
            return self.reply(403, b'{}')
        if self.path == '/result':
            with lock: value = result
            return self.reply(200, json.dumps(value).encode())
        files = {'/': ('browser.html','text/html'), '/browser.js': ('browser.js','text/javascript'),
                 '/remote-audio.mjs': (root.parents[1]/'Browser/RTC/remote-audio.mjs','text/javascript'),
                 '/measure.js': ('measure.js','text/javascript')}
        if self.path not in files: return self.reply(404, b'{}')
        name, mime = files[self.path]
        self.reply(200, (root/name).read_bytes(), mime)

    def do_POST(self):
        global process, result
        if self.headers.get('Origin') != origin or self.headers.get('Host') != f'127.0.0.1:{args.port}':
            return self.reply(403, b'{}')
        try:
            size = int(self.headers.get('Content-Length','0'))
            if not 0 <= size < 262000: return self.reply(413, b'{}')
            value = json.loads(self.rfile.read(size) or b'{}')
            if self.path == '/start':
                with lock:
                    if process and process.poll() is None: return self.reply(409, b'{}')
                    result = None
                    process = subprocess.Popen([str(args.binary.resolve())], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                               stderr=subprocess.PIPE, text=True)
                    child = process
                timer = threading.Timer(25, lambda: child.kill() if child.poll() is None else None)
                timer.daemon = True; timer.start()
                offer = child.stdout.readline()
                if not offer: raise RuntimeError('Native peer did not create an offer')
                self.reply(200, offer.encode())
            elif self.path == '/answer':
                if value.get('type') != 'answer' or not isinstance(value.get('sdp'),str):
                    return self.reply(400, b'{}')
                with lock:
                    child = process
                    if not child or child.poll() is not None: return self.reply(409,b'{}')
                    child.stdin.write(json.dumps(value)+'\n'); child.stdin.flush()
                def finish():
                    global result
                    line = child.stdout.readline()
                    code = child.wait()
                    failure = child.stderr.read()
                    try: receipt = json.loads(line)
                    except (ValueError, TypeError): receipt = {'passed':False,'error':'Native peer failed'}
                    receipt.update(exitCode=code, stderr=failure)
                    with lock: result = receipt
                threading.Thread(target=finish, daemon=True).start()
                self.reply(200,b'{}')
            else: self.reply(404,b'{}')
        except (ValueError, OSError, RuntimeError): self.reply(500,b'{"error":"Signaling failed"}')

ThreadingHTTPServer(('127.0.0.1',args.port),Handler).serve_forever()
