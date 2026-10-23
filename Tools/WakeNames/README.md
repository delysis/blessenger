# Native phonetic wake-name experiment

This candidate is **not enabled in calls**. The held-out test found three false
activations among 21 negative clips. Validation performance is not a substitute
for that failure, or for a live speaker/echo test.

The pinned CPU Core ML speech aligner produces a CTC phonetic decode. A small
character-ngram classifier is trained entirely in Swift with Accelerate BLAS.
On this Mac, four-second feature extraction had a median of 61 ms and head
training took about 0.1 s. These are component timings, not routing latency.

Compile from the repository root:

```sh
swiftc -O Tools/WakeNames/phonetic-probe.swift -o /tmp/blessenger-wake-features
swiftc -O -Xcc -DACCELERATE_NEW_LAPACK \
  Qualification/Experimental/WakeNames/WakeNameClassifier.swift \
  Tools/WakeNames/train-head.swift -o /tmp/blessenger-wake-train
```

The feature tool accepts `MODEL DATASET NEW_OUTPUT train-validation|test`.
MODEL is the pinned `AudioModelPins.alignerDirectory` export. DATASET uses the
manifest produced by the earlier `make_dataset.py` research tool, with source
voices partitioned before augmentation. It excludes transformed training siblings
from this baseline and never reads the held-out test unless explicitly selected.
The training tool accepts `TRAIN_VALIDATION_JSON TEST_JSON NEW_OUTPUT_DIRECTORY`.
Its model remains local; only aggregate receipts belong in the repository.

The current corpus uses system synthetic voices. Automatic generation from the
contact voices is the requested next step, not a completed capability. Keep
training and model preparation out of capture, generation, and playback. No
trained head may be connected to live routing based solely on this experiment.
