# Speech asset attribution

PocketTTS weights: Kyutai, https://huggingface.co/kyutai/pocket-tts,
revision 19f95fe2df36e79fbd9f10008595cc4c977a0fcc, English April 2026.
Licensed under CC BY 4.0 (included). No endorsement is implied.
Model card: https://huggingface.co/kyutai/pocket-tts

Core ML exports derived using FluidInference/mobius at
210d6b6d21177115babfece0de5e1795cffec2a2 (Apache 2.0, included).
Blessenger modifications: padding excluded from cache writes; transformer GELU
matched to the upstream implementation; 16/256-token conditioning shapes.
Source and patches are in ModelPatches/mobius; compiled file hashes are in
Sources/CallGemma/Resources/pocket-speech-models.json.

Browser voice conditioning states were derived from the bundled canonical
reference clips using PocketTTS. The source clip hashes and contact mapping are
in Browser/PocketTTS/model/voices.json. They are application assets, not recordings
of user conversations. Model weights and compiled exports live in a versioned
GitHub release asset, not Git history. Gemma is not redistributed in that asset.
