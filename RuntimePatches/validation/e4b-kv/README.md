# Pinned Gemma 4 E4B KV metadata

These files record bounded reads of the published
`litert-community/gemma-4-E4B-it-litert-lm` artifact at immutable revision
`e6a3892a8c22cf87ff99583996149cf3cb32452b`. The complete model was not downloaded
or executed. `ranges.json` records the exact immutable URL, byte intervals, and
SHA-256 receipts for 10,383,264 bytes of consulted metadata chunks. Chunks can
include neighboring FlatBuffer data. This is not a model execution result or
QAT provenance claim.

`shapes.json` records every input/output tensor shape and element-type enum for
the target decode, prefill_128, prefill_1024, and verify signatures and the draft
signature. `sections.json` records the container sections. `llm_metadata.pb` is
the exact 12,192-byte metadata section at [16384,28576). Its field summary and
the absence of an ExecutorMetadata section are recorded separately.

The target has 48 INT8 KV inputs: 20 K/V pairs with head width 256 and four pairs
with head width 512, all with two KV heads and a full-position axis 32003. There
is no 1152 local-ring axis in this artifact. Verify has four input positions.
The drafter consumes one K/V pair of each head width. The pinned schema maps
TensorType 9 to INT8; `summary.json` gives the schema source commit, Git blob,
SHA-256, model LFS hash, and grouped counts.

`composite_ops.json` records the operator index, operator table offset, options
table offset, and actual name for each observed StableHLO composite. Decode
was fully scanned: 2712 operators, including 24 `odml.cache_update`, 84
`odml.runtime_bmm`, and 302 `odml.rms_norm`. The verify scan is explicitly
partial: 2066/2801 operators were visited, observing 24 cache updates and 58
runtime matrix multiplications before the next uncached metadata range. The
final scan was cache-only and downloaded zero bytes. The earlier bounded read
stopped at its per-call 8 MiB limit; no completeness claim is made for verify.

Operator field interpretation comes from the exact pinned LiteRT
`tflite/converter/schema/schema.fbs`: BuiltinOperator 206 is
STABLEHLO_COMPOSITE; Operator field 12 is the builtin_options_2 table;
StableHLOCompositeOptions field 0 is its name. A table offset in
`composite_ops.json` is relative to target section base 1354334208. Add the base
to locate it in the immutable artifact. The range receipts provide the consulted
FlatBuffer bytes for independent bounded retrieval.

The 32003 dimension is a **runtime resize placeholder**, not an architectural
maximum-context assertion. At the pinned LiteRT-LM source:

- `runtime/executor/magic_number_configs_helper.cc:80–109` recognizes a prime
  dimension greater than 10 as a magic number.
- Lines 118–155 infer context size from the prefill/decode mask's last dimension.
- Lines 244–271 accept a positive requested size strictly below the placeholder;
  otherwise they choose the largest multiple of 256 below it.
- Lines 310–315 install that replacement for all signatures.

Thus a requested size 32768 follows the fallback to 32000 in this pinned path.
Qualification explicitly uses an aligned request no greater than 32000 so the
declared capacity agrees with compilation. The current app's smaller E4B memory
policy stays below that boundary.

The source's existing cache-update parser maps the graph to unsigned byte
storage while retaining the original INT8 tensor reference. The exact source
trace and focused Shared Metal transfer patch are supplied separately; this
directory establishes the actual artifact's shapes and operation names.
