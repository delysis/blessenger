#!/usr/bin/env python3
"""Compare every physical tensor byte, ignoring only V3 header padding/version."""
import hashlib
import json
import struct
import sys
from pathlib import Path

STATE_OFFSET = 16 * 1024 * 1024 + 8192


def read_header(stream):
    magic, key_size, metadata_size, state_size, token, checksum = struct.unpack(
        "<8sQQQII", stream.read(40)
    )
    assert magic == b"LRTLMCS2"
    assert key_size + metadata_size + 40 <= STATE_OFFSET
    key = stream.read(key_size)
    metadata = json.loads(stream.read(metadata_size))
    stream.seek(STATE_OFFSET)
    assert stream.read(8) == b"LRTSTATE"
    header_size = struct.unpack("<Q", stream.read(8))[0]
    assert 0 < header_size <= 65536
    header = json.loads(stream.read(header_size))
    version = header.pop("version")
    assert version in (2, 3), "Comparison requires physical Metal serialization"
    payload_size = sum(tensor["bytes"] for tensor in header["tensors"])
    assert state_size == 16 + header_size + payload_size + 4
    return key, metadata, token, header, payload_size, version


def compare(path):
    reference = Path(str(path) + ".full-reference")
    with path.open("rb") as actual, reference.open("rb") as expected:
        left = read_header(actual)
        right = read_header(expected)
        assert left[:-1] == right[:-1], "Snapshot metadata or tensor descriptors differ"
        assert left[-1] == 3 and right[-1] == 2
        digest = hashlib.sha256()
        remaining = left[4]
        while remaining:
            count = min(remaining, 1024 * 1024)
            a, b = actual.read(count), expected.read(count)
            assert len(a) == count and len(b) == count
            assert a == b, f"Physical tensor bytes differ with {remaining} bytes remaining"
            digest.update(a)
            remaining -= count
        assert len(actual.read()) == 4 and len(expected.read()) == 4
        return {
            "snapshot": str(path),
            "physical_tensor_bytes": left[4],
            "tensor_count": len(left[3]["tensors"]),
            "payload_sha256": digest.hexdigest(),
            "equal": True,
            "scope": "All tensor descriptors, state metadata, and physical tensor bytes; framing CRCs validated separately by runtime restore.",
        }


if __name__ == "__main__":
    print(json.dumps([compare(Path(arg)) for arg in sys.argv[1:]], indent=2))
