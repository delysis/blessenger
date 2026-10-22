#!/usr/bin/env python3
"""Prepare the real pinned Alba/text cache case for PocketCacheRegressionTests."""
import argparse
import json
from pathlib import Path
import struct

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('english_pack', type=Path)
parser.add_argument('destination', type=Path)
args = parser.parse_args()
constants = args.english_pack / 'constants_bin'
voice = (constants / 'alba.safetensors').read_bytes()
header_size = struct.unpack_from('<Q', voice)[0]
header = json.loads(voice[8:8 + header_size])
payload = memoryview(voice)[8 + header_size:]
arrays = {}
for layer in range(6):
    key = f'transformer.layers.{layer}.self_attn/'
    cache = header[key + 'cache']
    assert cache['dtype'] == 'F32' and cache['shape'] == [2, 1, 126, 16, 64]
    start, end = cache['data_offsets']
    block_bytes = 126 * 1024 * 4
    assert end - start == 2 * block_bytes
    for index, kind in enumerate(('k_cache', 'v_cache')):
        data = bytearray(512 * 1024 * 4)
        data[:block_bytes] = payload[start + index * block_bytes:start + (index + 1) * block_bytes]
        arrays[f'{kind}{layer}'] = ([1, 512, 16, 64], data)
    offset = header[key + 'offset']
    assert offset['dtype'] == 'I64' and offset['shape'] == [1]
    position = struct.unpack_from('<q', payload, offset['data_offsets'][0])[0]
    assert position == 126
    arrays[f'position{layer}'] = ([1], struct.pack('<f', position))
tokens = [260] * 8 + [764, 270, 263]
table = (constants / 'text_embed_table.bin').read_bytes()
conditioning = bytearray(256 * 1024 * 4)
for i, token in enumerate(tokens):
    conditioning[i * 4096:(i + 1) * 4096] = table[token * 4096:(token + 1) * 4096]
arrays['conditioning'] = ([1, 256, 1024], conditioning)
arrays['valid_len'] = ([1], struct.pack('<f', len(tokens)))
args.destination.mkdir(parents=True, exist_ok=False)
for name, (_, data) in arrays.items():
    (args.destination / (name + '.f32')).write_bytes(data)
(args.destination / 'inputs.json').write_text(json.dumps({k: v[0] for k, v in arrays.items()}, indent=2) + '\n')
