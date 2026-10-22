"""Load the exact pinned upstream source with the reviewed patch, without editing it."""
from contextlib import contextmanager
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
RELATIVE_SOURCE = Path('models/tts/pocket_tts/coreml/convert_models/traceable/traceable_cond_prefill_ane.py')

@contextmanager
def patched_exporter(source):
    provenance = json.loads((ROOT / 'provenance.json').read_text())
    data = Path(source).read_bytes()
    if hashlib.sha256(data).hexdigest() != provenance['original_source_sha256']:
        raise ValueError('Exporter source does not match the pinned upstream revision')
    with tempfile.TemporaryDirectory(prefix='blessenger-exporter-') as temporary:
        directory = Path(temporary)
        target = directory / RELATIVE_SOURCE
        target.parent.mkdir(parents=True)
        target.write_bytes(data)
        subprocess.run(['patch', '--batch', '-p1', '-i', str(ROOT / '0001-exclude-padding-from-cache-writes.patch')],
                       cwd=directory, check=True, capture_output=True)
        spec = importlib.util.spec_from_file_location('blessenger_patched_conditioner', target)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        yield module.TraceableCondPrefillANE
