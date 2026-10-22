# Audio-content regression corpus

These fixtures exercise the packaged application's live controllers, capture clock, endpointing, 12B inference, speech generation, journal, and inline playback. Launch a signed application with `BLESSENGER_QUALIFICATION_DIRECTORY` pointing to a fresh directory to isolate test data and mute its final output mixer. This does not qualify real microphone acoustics or echo cancellation. The app must report Gemma 4 12B IT.

Run from the CallGemma directory, replacing RUN with that isolated directory:

```sh
python3 Tools/qualify-app-calls.py RUN --question Qualification/Fixtures/audio-content/original-0.wav --two-utterances Qualification/Fixtures/audio-content/barge-in-two-questions.wav --question-set Qualification/Fixtures/audio-content/combined-questions.json --group-question-set Qualification/Fixtures/audio-content/group-questions.json --expect-endpoint '{"speculation":0.5,"strict":0.3,"tailMS":100}'
python3 Tools/qualify-app-voice-notes.py RUN --question Qualification/Fixtures/audio-content/original-0.wav
python3 Tools/qualify-app-relaunch.py RUN
```

The relaunch check deliberately SIGKILLs the idle isolated app after verifying its mode and executable hash. It compares transcript hashes immediately after restart, before another call can change them, then asks each persona to recall its previously supplied facts. It is not an in-flight journal/cache-boundary fault injection.

The original six question recordings and two-question barge-in recording are preserved from the earlier regression investigation. Their synthetic voice provenance was not recorded here. Held-out recordings use the installed macOS Daniel, Karen, Moira, and Rishi voices at 180 words/minute. Clinical and recall recordings use Samantha at the same rate. All are mono 16 kHz integer PCM. SHA256.json binds the recordings. The clinical questions are intentionally two sentences: their factual first sentence must remain in canonical history even when the next sentence interrupts an unheard response. The test checks both a correct answer and sufficient retained audio referenced by the transcript; orphan WAVs do not count.

The strict answer checks are test-fixture checks, not product filters. Original failed arithmetic/persona responses remain in the qualification receipts. Group clinical questions supplement them rather than rewriting persona prompts. Timing uses a fixed last-sample-above-1%-amplitude reference on the device clock, independent of VAD thresholds. It is a software reference rather than a microphone measurement of acoustic speech end.
