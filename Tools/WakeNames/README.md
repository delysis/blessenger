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

The original corpus used system synthetic voices. The contact-voice experiment
below adds native synthesis; automatic app enrollment remains unfinished. Keep
training and model preparation out of capture, generation, and playback. No
trained head may be connected to live routing based solely on this experiment.

## Contact-voice corpus

`WakeCorpusQualificationTests/testGenerateContactVoiceCorpus` generates silent
16 kHz WAVs through the repaired native PocketTTS exports. It uses bundled
contacts only, never private user contact storage. Each conditioning voice says
all 14 names and the same 24 non-name phrases. Peter and Gabor train; Francine
validates; Judith is held out. Conditioning PCM hashes are checked for overlap,
seeds and source hashes are retained, and partial corpora have no COMPLETE marker.
There is no microphone or audio playback graph.

After a normal signed `xcodebuild build-for-testing`, run:

```sh
python3 Tools/WakeNames/generate-contact-corpus.py \
  /path/to/Build/Products/CallGemma_macosx27.0-arm64.xctestrun \
  /path/to/new-evidence-directory
```

The first corpus generated 320 clips in 44.110 seconds. With the unchanged
classifier and margin, held-out Judith speech scored 48/56 names, eight misses,
zero wrong names and zero false activations in 24 negatives. See
`Qualification/Experimental/WakeNames/contact-voices-07.json`. The negative
phrases overlap training: this measures voice generalization, not unseen-language
false activation. This candidate remains disabled. Automatic enrollment in the
contact editor, unseen speech, post-AEC playback and live routing are unfinished.
