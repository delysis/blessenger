#!/usr/bin/env python3
"""Verify real TLS, authorization and a model download lasting over 20 seconds."""
import hashlib
import http.client
import json
from pathlib import Path
import socket
import ssl
import sys
import time

assets, config_root, receipt = map(Path, sys.argv[1:])
config = json.loads((config_root / 'configuration.json').read_text())
manifest = json.loads((assets / 'manifest.json').read_text())
context = ssl.create_default_context()
certificate = (config_root / 'Blessenger.cer').read_bytes()
context.load_verify_locations(cadata=ssl.DER_cert_to_PEM_cert(certificate) if not certificate.startswith(b'-----') else certificate.decode())
def request(path, authenticated):
    connection = http.client.HTTPSConnection(config['host'], 8944, context=context, timeout=30)
    connection.sock = context.wrap_socket(socket.create_connection(('127.0.0.1', 8944), timeout=30), server_hostname=config['host'])
    headers = {'Host': config['host'] + ':8944'}
    if authenticated:
        headers['Cookie'] = 'blessenger=' + config['session']
    connection.request('GET', path, headers=headers)
    return connection, connection.getresponse()

name = 'PocketTTS/model/model.safetensors'
path = '/runtime/' + manifest['revision'] + '/' + name
connection, response = request(path, False)
assert response.status == 401
response.read(); connection.close()
connection, response = request('/runtime/' + manifest['revision'] + '/manifest.json', True)
assert response.status == 404
response.read(); connection.close()
connection, response = request(path, True)
assert response.status == 200
assert "'wasm-unsafe-eval'" in response.getheader('Content-Security-Policy')
assert "'unsafe-eval'" not in response.getheader('Content-Security-Policy')
start = time.monotonic(); digest = hashlib.sha256(); size = 0
while chunk := response.read(262144):
    digest.update(chunk); size += len(chunk)
    time.sleep(.03)
elapsed = time.monotonic() - start
connection.close()
assert size == manifest['files'][name]['bytes']
assert digest.hexdigest() == manifest['files'][name]['sha256']
assert elapsed > 20
result = {'passed': True, 'bytes': size, 'seconds': elapsed, 'sha256': digest.hexdigest(),
          'unauthenticatedStatus': 401, 'unlistedAssetStatus': 404,
          'scope': 'Actual CompanionHTTP over verified TLS, bounded writes, throttled download; diagnostic listener, not installed app'}
receipt.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))
