# Native contact and call UI verification

Verified on macOS, October 22, 2026, with the signed Release app.

- Contact editor: conventional name input, no duplicate title or portrait carousel, bounded independently scrolling prompt editor. Checked the end of a long prompt without the previous blank trailing area.
- Isolated actual-app contact: loaded a local image, zoomed and repositioned its circular crop, saved it; imported the bundled Peter voice WAV, adjusted its end to eight seconds, named it, saved, and reopened the editor. The name persisted. Imported files are copied into app-owned storage.
- Call sheet: actual app presentation, connected timer, mute state and explicit hang-up. Synthetic speech injected while muted did not create a new turn; hang-up dismissed the sheet. This is UI/controller verification with the 12B model and muted synthetic audio, not a new acoustic speaker qualification.
- Release xcodebuild passed; installed bundle passed codesign --verify --deep --strict.

Image URL and clipboard import paths are implemented, but the controlled crop check above used a local file. Live microphone recording was not repeated in this UI check. Wake-name recognition remains experimental and is not qualified by these checks.
