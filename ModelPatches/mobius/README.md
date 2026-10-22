# Corrected PocketTTS conditioning exports

Upstream: FluidInference/mobius, revision
`210d6b6d21177115babfece0de5e1795cffec2a2`, file
`models/tts/pocket_tts/coreml/convert_models/traceable/traceable_cond_prefill_ane.py`.
Supply that **unmodified** file to `--source`. The loader verifies its SHA-256
before applying the local patch in a disposable directory. It never edits the
supplied source. The patch prevents padding from writing any cache slot.

Use Python 3.12 with torch 2.7.1, coremltools 9.0, numpy 2.5.4, and pocket-tts
4.0.1. The export also checks the English configuration hash, including its
pinned Hugging Face weights and tokenizer revisions. Model access may require
accepting the upstream model license. Existing local model caches can be used.

From this directory:

```sh
python test_cache_writes.py --source /absolute/path/to/original/traceable_cond_prefill_ane.py
python export_small.py --source /absolute/path/to/original/traceable_cond_prefill_ane.py --output /absolute/path/to/new-export
swift compile-assets.swift /absolute/path/to/new-export /absolute/path/to/new-compiled-assets
```

Default exports are widths 16 and 256. `--widths 4 16 256` also produces the
benchmark-only width 4. Export output must be a new directory. Compilation
refuses to overwrite existing model folders. Neither command installs models
into the app or modifies the upstream cache.

The compiled models currently bundled in the app are identified by the file
hashes in `candidate-assets.json` and the app's `pocket-conditioners.json`.
Core ML compiler outputs are toolchain dependent: a re-export must receive a
fresh manifest and pass numerical, synthesized-audio, and actual-app checks
before replacing those assets. A successful export is not acceptance evidence.
