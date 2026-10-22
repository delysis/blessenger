# Blessenger implementation ledger

The approved plan is active. This is a development integration, not a completed or qualified release.

## Implemented so far

- SwiftUI navigation split view, toolbar call/new-message/search/contact controls, compact composer; old title/model/prompt/voice chrome removed.
- Contact sheet: prompt, bundled voice preview, custom voice editor/import/record entry, wake-name field, original portrait selection.
- 14 previously qualified voice samples copied into resources. Original icon/portrait atlas copied with provenance. No old application code imported.
- SQLite WAL/FULL transactional records and event log; contact/thread/message identities, reactions, validated destinations and duplicate rejection. Actor-isolated IO. Indexed record access for writes.
- Text inference uses existing Gemma executor, separate contact/thread cache roots, canonical text transcript derived from committed messages, replay before restore, checkpoint publication after message commit.
- Direct calls select contact prompt/voice and their own hidden call cache directory. Dial/ring intent remains synchronous.
- Native file picker for image/audio/text/PDF, durable app-owned attachments, PDF text extraction, multimodal model inputs, Quick Look.
- Per-chat draft switching and captured send destination; saved unchanged contacts are no-ops.
- Speech playback uses generated text only. Delayed optional compile-time filler delivery remains unimplemented.
- macOS/iOS deployment floor 26.

## Qualification receipts

- Release build succeeded (first integration): /private/tmp/blessenger-build-2.log.
- Standalone storage smoke passed: /private/tmp/blessenger-store-smoke.swift.
- Packaged XCTest: 2 MessageStoreTests passed, /private/tmp/BlessengerStorage-20261020-b.xcresult, /private/tmp/blessenger-tests-2.log.
- Initial Release test attempt failed because ENABLE_TESTABILITY was absent; failure retained at /private/tmp/blessenger-tests-1.log. Re-run explicitly enables testability.
- Updated attachment/portrait/draft integration is under test in /private/tmp/BlessengerStorage-20261020-c.xcresult.
- The installed prior CallGemma app has NOT been replaced.

## Outstanding (do not claim complete)

- Packaged native UI exercise, functional real-model message/restart tests, crash injection across SQLite/transcript/checkpoint boundaries.
- Routing currently chooses the first participant for unaddressed groups; replace with relevant-responder routing. Explicit selected contact mentions work; robust range tracking, duplicate-name disambiguation, chat consultations and bounded persona summons remain.
- Shared relationship memory across chats/calls, provenance retrieval and contextual group exchanges remain. Existing isolated sessions are not shared memory.
- Group membership editing; group calls currently select first participant only and must be completed before release.
- Real voice-note recording/transcription and generated playable voice replies; attached audio currently passes to the model directly.
- Attachment thumbnails, image/model/audio qualification, missing/OCR file handling beyond explicit errors, search across message content.
- Full pending-generation journal/retry on failure; terminal recovery and no hidden native continuation after persistence failures.
- Wake detector training/calibration/acceptance, mute state machine, actual iPhone locked-screen/background qualification; existing background shutdown remains until a real supported alternative is qualified.
- Compile-time optional delayed filler scheduler (Hmm./Well.), correct heard transcript/cache handling, dedicated timings.
- Contact custom voice preview errors currently not surfaced; improve async save failure UX and durable drafts.
- Store snapshots currently load all messages for presentation; add pagination/thread-indexed read models before large-history qualification.
- Memory/CPU/startup/230ms substantive reply/cancellation/cache regression qualification; Mac and physical iPhone gates separate.
- iOS icon set and iOS build/platform UI validation.

Do not erase failed receipts, replace the installed app prematurely, or represent component checks as complete product qualification.

## Native acceptance update

- Updated MessageStoreTests again passed (2/2), receipt c.
- In `/private/tmp/Blessenger-interface-stage1.app`, native UI contact creation, portrait choice, conversation creation and real Gemma text reply passed. User prompt stored codeword `marigold`; model replied `marigold`.
- Forced SIGKILL of that test process, fresh launch, selected restored chat, asked for codeword: model again replied `marigold`. SQLite messages, canonical transcript and native CURRENT pointer retained in Qualification/Local/blessenger. This is one restart journey, not fault injection at every commit boundary. Actual native cache-load timing has not yet been inspected.
- Stage1 executable SHA256: acbb22142d745ba1182309256b9a053b2cdedbda974449f7622fba470476d441.
- Found and repaired missing atlas lookup (moved PNG into imageset), persistent extra search field (show on demand), and old narrow window restoration (new window identity/minimum width).
- Latest source Release build passed: /private/tmp/blessenger-build-5.log. Its package `/private/tmp/Blessenger-interface-stage2.app` passed deep code-sign verification and screenshot inspection shows the portrait and compact toolbar correctly. It is currently running idle. Subsequent CUA input attempts reported user-changed-app; no attempt made to override that safeguard.
- The current source manifest represents the latest source, not the exact earlier stage1 executable; the executable hash above identifies that tested package.

## Group routing and durable reply queue (2026-10-20)

The user explicitly replaced model-based responder selection: choose the latest responding current group member, or a random current member if nobody has replied. Explicit @mentions override it. There is no routing inference pass, and guests/users do not enter the default member selection.

Implemented:
- Atomic admission of user message + reply attempts; immutable prepared requests, frozen persona/prompt, queued/generating/completed/failed states, retry and startup resumption.
- Exactly-once reply publication in the same SQLite transaction as completion and automatic follow-ups. Up to four automatic follow-ups per initiating message; already visited recipients cannot loop. Explicitly addressed recipients are processed in mention order.
- Contact and `@#Chat` autocomplete, duplicate-name IDs, full-token boundary matching. Chat references produce guest replies with source attribution and do not change source history/membership.
- Context snapshots include current group exchanges and bounded recent relationship excerpts from other chats, with message/conversation/contact IDs. Shared call memory and scalable retrieval are still outstanding.
- Canonical model history uses the exact frozen request JSON; missing authoritative inputs fail closed. No reconstruction of old development-format replies.
- Transcript order follows SQLite insertion order rather than wall-clock dates, including after reaction updates.
- Group membership/name editor and per-conversation failed-work retry control.

Evidence:
- `/private/tmp/BlessengerRouting-20261020-a.xcresult`: 8/8 tests passed.
- `/private/tmp/BlessengerMessagingNative-20261020-a.xcresult`: real E4B packaged-host integration passed in 16.597s: saved codeword in Notes, explicit contact, recent-member dispatch, guest consultation, default-member selection after a guest, and autonomous @Ben reply. 13 messages committed, including 7 model replies. Receipt: `Qualification/Local/blessenger/routing-native-a/messages-initial.json`.
- `/private/tmp/BlessengerMessagingRestore-20261020-a.xcresult`: separate test-host process restored the same data and recalled marigold; 7 routing/queue checks also passed. Receipt: `routing-native-a/messages-restore.json`.
- `/private/tmp/BlessengerRouting-20261020-b.xcresult`: 22/22 routing/queue/storage/canonical-history/heard-journal tests passed. Includes an injected SQLite abort after reply publication starts, proving reply + status + followups roll back together; retry commits once. Includes wall-clock reversal ordering.
- iOS simulator build currently running, log `/private/tmp/blessenger-ios-build-1.log`. Device inventory shows simulators only: no physical iPhone is connected. This does not block software implementation, but physical-device/background/latency claims remain unqualified.

Earlier 'outstanding' descriptions of first-member routing, missing consultations, absent bounded summons, and missing membership editing are superseded by this section. UI interaction for the new controls still needs packaged verification; the native integration test exercises the real runtime/store, not gestures.

## Platform follow-up and current processes

- Simulator Swift compilation succeeded, then linking identified three missing native streaming-audio symbols in the old iOS framework (`begin_audio_input`, `append_audio_input`, `finish_audio_input`). This is a runtime artifact mismatch, not a reason to remove streaming prefill.
- Added a 1024px iOS rendition of the original icon (resized original artwork only). This fixes the first simulator asset-catalog failure. Logs retained: `/private/tmp/blessenger-ios-build-1.log`, `/private/tmp/blessenger-ios-build-2.log`.
- Rebuilding the patched iOS runtime using `PATH=/Users/george/Documents/Codex/2026-10-20/ano/work/bin:$PATH bash Tools/build-ios-runtime.sh`. The first attempt lacked Bazel on PATH and failed; its log is retained. The actual build is live in exec session **33739**, log `/private/tmp/blessenger-ios-runtime-build-2.log`. Do not restart it merely because a later observation times out.
- Consolidated final Mac checks are live in exec session **15923**, log `/private/tmp/blessenger-routing-final-tests.log`, result `/private/tmp/BlessengerRoutingFinal-20261020.xcresult`. They include the real-model restore and routing/storage/canonical/heard-journal tests on the current Swift source.
- Attachment imports now retain their original chat destination across asynchronous decoding. Failed message admission restores the original draft instead of losing it.
- The stage2 development app remains separate from the installed app. Its test contact/history precede the new frozen-request schema; no backward compatibility is being added for that development data. Use a fresh messaging data directory for future UI qualification and the routed native receipts for current-format restart qualification.

## iOS runtime packaging and call/queue boundary

- The final routing run completed: `/private/tmp/BlessengerRoutingFinal-20261020.xcresult`, 23 XCTest checks plus four Swift Testing canonical-history checks, no failures. This includes a real-model restore on the current routing tree. Qualification receipt filenames now include UUIDs so repeated runs retain their evidence.
- The patched iOS native build completed (`blessenger-ios-runtime-build-2.log`); its archive SHA is `1b3e5f4ef7b6e2277c8e18c1a2e9491fc53838217176c335a0369e54868abb03`. Both streaming-prefill slices now link (`blessenger-ios-build-3.log`).
- Packaged simulator launch exposed a missing `libGemmaModelConstraintProvider.dylib` dependency. Added `Tools/package-ios-runtime.py` to wrap the upstream platform-specific binaries in an embedded XCFramework, rewrite packaged install names, sign the copies, and bind runtime identity to the packaged binary manifest. Upstream source binaries remain unchanged. `Tools/build-ios-runtime.sh` invokes it after extraction. The next simulator build/launch is being checked; a successful link alone did not establish launch acceptance.
- Group reply draining now rechecks call admission between replies. A call that starts during the preceding reply save leaves subsequent attempts queued. `/private/tmp/BlessengerCallQueue-20261020.xcresult` passed all four queue tests, including call-boundary resumption without duplicate replies or failed jobs. This is a component regression check; live call/group interaction remains to qualify.
- Packaging repair passed build and actual simulator launch (`blessenger-ios-build-4.log`, live console session 92368). `Qualification/Local/blessenger/ios-shell-packaged.png` shows the native compact sidebar. Launch used `CALL_GEMMA_TEST_HOST=1` to exercise presentation without downloading/preparing model assets; it is not an inference test.
- Screenshot inspection identified a compact-navigation omission: New Message existed only in the hidden detail pane. Added the iOS sidebar New Message control and explicit value-based NavigationLinks for conversation rows. This follow-up still needs a rebuild and interaction check.

## Voice-note integration in progress

- iOS compact-navigation build 5 succeeded; `ios-compact-compose.png` confirms the New Message control in the compact sidebar. Simulator GUI application is absent at the configured Xcode path, so gesture-based navigation acceptance is still open; screenshots establish rendering only.
- Added a dedicated voice-note recorder actor and sheet, separate from the short cloning-sample editor. Permission and audio configuration are off the UI executor; recording stops on dismissal/background, supports explicit stop/cancel, and attaches to the originally selected chat. Recordings enter app-owned attachment storage.
- Audio messages are durably admitted before transcription. A separate Gemma transcription conversation shares the loaded executor; its output is stored on the audio attachment and visible through the transcript control. Persona reply inputs use that durable transcript. Transcription does not enter a persona's cache as an extra exchange.
- Persona voice-note replies use the selected cloned voice and stream 24 kHz PCM into a file. The reply and attachment publish together only after audio rendering/import succeeds. Failed rendering leaves the attempt retryable; canonical cache reconciliation discards the unpublished generated suffix. File rendering does not open the playback engine or accumulate the complete PCM buffer.
- Voice-note bubbles expose play and transcript icons; original/response audio remain playable via native preview.
- The initial regression run (`/private/tmp/BlessengerVoiceNotes-20261020-a.xcresult`) passed 11 routing/queue/storage checks. The complete real-model voice-note test plus failure/relaunch regression is live in exec session **91500**, log `/private/tmp/blessenger-voice-note-tests-2.log`, result `/private/tmp/BlessengerVoiceNotes-20261020-b.xcresult`. Test fixture `work/voice-note-question.wav` asks 'What is two plus two?'. No end-to-end voice-note success claim until that run and packaged recording/playback checks pass.

### User correction: voice notes reuse calls; no transcription or pre-rendered replies

The user explicitly dropped transcription and requested text-backed, on-demand TTS for persona voice notes. This supersedes the preceding voice-note design. The old six-test pipeline run passed, but it validates the superseded implementation and is not acceptance evidence for the requested behavior.

- Removed transcription methods and offline reply rendering. User audio stays durable and is sent directly to Gemma. Persona replies publish as text with voice-note presentation, with no audio attachment generated at admission.
- Replaced the separate AVAudioRecorder pathway with `CallAudio.start(recording:)`: the same prepared microphone engine, capture pool, bounded stream and 16 kHz resampler feed a file-writing actor instead of VAD. Finishing drains accepted capture buffers before closing the file. This avoids a second microphone/configuration/conversion implementation.
- Playback uses the existing `SpeechOutput.beginResponse/append/finishResponse` path and `CallAudio` scheduling/backpressure/cancellation. An output-only graph is the necessary difference: note playback never requests mic permission or starts capture. Cancellation without a heard-call journal skips unnecessary partial-sentence reference completion; journaled call cancellation keeps its existing recovery behavior.
- New tests check direct audio requests, text-only voice replies, retry/reopen behavior, and frame-exact recording at the shared capture rate. Real-model/on-demand playback qualification is live in exec session **26146**, log `/private/tmp/blessenger-voice-note-tests-3.log`, result `/private/tmp/BlessengerVoiceNotes-20261020-c.xcresult`. Do not infer completion from the earlier pre-rendered test.
- Revised real-model/on-demand test passed (`BlessengerVoiceNotes-20261020-c.xcresult`): 7 checks total, real pipeline 13.028s including setup. Receipt `voice-notes-on-demand-a/voice-note-55F1C7E8-B6DC-45F3-8F46-C85393504971.json` stores user text empty with one original audio attachment, and assistant text `Four.` with zero attachments.
- Follow-up (`BlessengerVoiceNotes-20261020-d.xcresult`) passed the real pipeline, on-demand playback/cancellation, microphone-off assertions, recording frame preservation/relaunch checks and 12 heard-journal regression cases. Playback produced zero capture callbacks and left the capture engine stopped. Interrupting the long note leaves stored messages unchanged. Stop duration receipt: `voice-notes-on-demand-b/playback-stop-149FA1B4-757B-4E57-BBFD-45D36556AFB3.txt`.
- Packaged UI recording gestures, real-microphone recording through the shared path, and the updated iOS build remain to qualify. These tests do not establish latency for live voice-call responses or physical-iPhone support.

## Shared recording and packaged voice-note acceptance

- Updated iOS simulator build passed (`blessenger-ios-build-6.log`). This includes shared call capture and on-demand voice-note playback; physical-device acceptance remains open.
- Real microphone qualification passed (`/private/tmp/BlessengerVoiceRecording-20261020-a.xcresult`, 6.370s): prewarm left capture stopped, two recordings produced 16 kHz audio, capture callbacks occurred only while recording, both stopped, and the prepared engine build count remained unchanged.
- Copied/signature-verified native package `/private/tmp/Blessenger-voice-notes.app` was exercised through CUA: created a fresh chat, opened recording, stopped and attached its recording to the draft, removed that test draft attachment, imported the known two-plus-two audio through the native file picker, sent it, and received a text-backed voice-note reply. The existing Qualification persona's prompt returns `marigold`; the separate Ada native integration test establishes the arithmetic response.
- The reply's Play button visibly changed to Stop during synthesis/playback and returned to Play; opening its text control showed the stored `marigold` text. Screenshot: `Qualification/Local/blessenger/mac-voice-note-packaged.png`. This is packaged behavior evidence, not an acoustic-quality measurement.
- Inspection found macOS omits the sidebar automatic Add Contact toolbar item. Added an always-reachable Contact action to the conversation-options menu with Shift-Command-N, plus native circular glass composer controls and an icon-only attachment menu. Build is live in session **43364**, log `/private/tmp/blessenger-ui-contact-build.log`; this UI follow-up still needs packaged inspection.
- `BlessengerVoiceNotes-20261020-e.xcresult` passed (15.390s): the known question was converted through the production `VoiceNoteRecording` writer, fed directly to Gemma, answered correctly, played on demand, and stopped within the existing cancellation gate. This qualifies the recording writer's actual WAV representation, not only arbitrary imported WAV input.
- The packaged Contact action is visible in the options menu even without a selected conversation. CUA twice rejected selecting it as a user-changed-app condition despite refreshing state; no further input was forced. The menu-level keyboard shortcut did not open the sheet, so it has been replaced/supplemented with native app Commands using focused-scene actions for Cmd-N and Shift-Cmd-N. Command build is live in session **4065**, log `/private/tmp/blessenger-command-build.log`. Packaged command/modal verification remains open.

## Native toolbar, avatar rail, and supplied contacts (2026-10-20)

- Replaced the desktop navigation container with an AppKit split controller hosting shared SwiftUI content. The sidebar cannot collapse; its narrow form uses portraits and single-line names. The toolbar uses a tracking separator and native navigation placement. iPhone retains NavigationSplitView.
- Removed Send, sidebar-toggle and ellipsis controls. Return sends; Shift-Return inserts a newline at the current selection. Packaged keyboard check caught and repaired Shift-Return incorrectly reaching onSubmit.
- Removed voice-note transcript presentation and its toggle; stored assistant text remains the on-demand TTS source. Reactions remain in the message context menu.
- Imported all 14 contacts from the original therapy_consult_personas.yaml. JSON-decoded prompts were compared exactly with all 14 original system_prompt fields. Matching voice-file existence and portrait atlas mappings were checked, including three voice-name aliases. Source SHA is recorded in Resources/contacts-provenance.json. Original names and prompts were not rewritten.
- Contacts and empty direct chats install transactionally, with stable IDs, only when the contact is absent. Repeated packaged launches retained 14 roster contacts without duplicates. Read-only database comparison confirmed exact saved name, prompt, voice and avatar matches. Existing user contact edits are not overwritten on launch.
- macOS builds and the populated iOS simulator build passed. Packaged header iterations exposed native toolbar control-height clipping; the contact title now lives outside that clipping and is positioned using the actual arranged panes. No new inference/audio/cache implementation was introduced for these UI changes.
- Search's initial native expanding item had an unacceptable collapsed/editing transition. It is being replaced with an explicit field state. Final Escape/cancel/click-away, rail resize, and contact-edit checks are still in progress; do not treat this entry as final acceptance of Search.

## 2026-10-20 — Inline composition, recording and message actions (qualification in progress)

- Removed NewConversation sheet and its implementation. New Message creates an unsaved inline draft with recipient chips, portrait/name filtering, keyboard arrows/Return/Escape, and stable contact identities. Sending materializes the thread; multiple recipients form a group. Packaged UI exercised Gabor/Peter autocomplete, group creation, real model reply and context-menu rename to `UI test group`.
- Sidebar names support editing after a subsequent click; menus expose Rename, Edit Contact/Group, Delete and Recently Deleted. Deletion is a persisted tombstone with Undo and explicit Restore; bundled roster installation does not recreate the deleted conversation. Message deletion likewise retains a recoverable record; Restore Deleted Messages and Undo recover it, and snapshots omit deleted messages from new inference contexts.
- Recording stays in the composer: one capsule during capture; after stop the separate cancel circle sits beside a capsule containing preview, waveform, duration and send. User-note playback no longer invokes Quick Look. File notes use an inline native audio transport, while persona notes synthesize only on Play with the existing PocketTTS manager, cloned voice, leading-silence gate and first-clause/sentence splitter. A bounded, current-note-only PCM buffer permits seeking in synthesized audio already available; no PCM is persisted into message storage. Notes currently cap synthesized playback storage at two minutes (11.52 MB PCM). Calls still use their existing streaming/journal path.
- Message menus now specify eleven locally frequency-ranked reactions, full picker, Reply, Copy, Share, Print, Delete. Emoji data is Unicode Emoji 16.0, 3,781 fully qualified entries, downloaded from https://unicode.org/Public/emoji/16.0/emoji-test.txt with Unicode license bundled. Native font rendering, category filtering, name search and all supplied tone sequences; Mac system character picker is also available. Menu visual acceptance still pending at this entry.
- `/private/tmp/BlessengerSeekableNotes-20261020.xcresult`: real Gemma audio-input/text-only reply/relaunch + synthesized note playback/pause/seek/cancel passed (27.124s). Synthesized playback stop 35.126 ms. Recorded-file startup test failed its 250 ms progress assertion with a Core Audio start error. Added checked start/retry and wait-for-real-playback-clock qualification; follow-up `BlessengerSeekableNotes-20261020-b.xcresult` running. Do not treat the first run as a full pass.
- Follow-up `BlessengerSeekableNotes-20261020-b.xcresult` passed all five selected tests. Real Gemma pipeline + generated note seek/pause/cancel/reopen passed; generated playback stop 37.613 ms. Recorded playback pause/seek/resume/cancel and no microphone callbacks passed (0.725s test). Deletion/recovery across reopen and capture-frame preservation passed. An additional guard keeps `stopVoiceNotePlayback()` a no-op when no note is active, preserving ongoing calls when selecting chats.
- iOS Simulator Release build `/private/tmp/blessenger-inline-ios.log` passed for the inline creation/playback/menu implementation. This is a compile result, not physical-device, locked-screen, or iOS presentation acceptance.
- Native context-menu visual check caught invisible text-only reaction palette items. Rendered native emoji images replace text-only palette labels. Native search field also needs explicit toolbar validation disabled while its item action is nil; otherwise AppKit can disable the custom field. Both changes await the following packaged visual check.

### 2026-10-20 — Print pagination and reaction-menu feedback

- Replaced the 700-point minimum print view with TextKit-measured content at the selected paper's printable width. Print text is explicitly black, top aligned, with automatic vertical pagination.
- Added shared SwiftUI button hover/pressed styling to compact actions, Share, emoji buttons, and expanded palette controls. Uses the system accent color and native Button semantics.
- Focused MessagePrintLayoutTests passed: short message under 100 points, printable width respected, long content exceeds one page without truncation. Receipt: `/private/tmp/blessenger-print-hover.log`.
- Release build passed (`/private/tmp/blessenger-print-hover-build.log`); fresh Blessenger.app package verified with codesign --deep --strict.
- Packaged native Print panel confirmed **Page 1 of 1** for the short hello message; Cancel used, no physical print submitted.
- Pointer-only hover could not be conclusively exercised with the available CUA pointer API (click/drag, no mouse move). Do not describe hover appearance or keyboard focus as visually qualified from this run. Hover and pressed implementation is present for user testing.

### 2026-10-20 — Connect committed call memory to messaging

- Dialing from the messaging shell now supplies the store. After asynchronous profile preparation and before capture, the controller registers a stable call ID and authoritative transcript start boundary. Ringing and synchronous UI intent remain ahead of this work.
- Hang-up finishes the memory boundary only after response cancellation and heard-text recovery. Store/contact configuration is changed inside the existing serialized configuration operation, after previous call teardown.
- New chat generation attempts prepend the contact's last two committed audio turns with call/contact/message-index provenance. The complete request is frozen by prepareAttempt; retries retain that exact request. Calls do not create message bubbles. Generated continuations and pending/cache files are not memory sources.
- Focused native-host tests passed: RelationshipMemoryTests (reopen, completed/open call boundaries, greeting exclusion, heard text, no other-contact leakage, no chat bubbles) and all four ConversationRoutingTests. Receipt: `/private/tmp/blessenger-call-memory-tests.log`.
- This integration is source/test-host qualified only. The currently delivered Blessenger.app still contains the preceding print/hover build. A real call-to-chat run and latency comparison remain required before replacing it with this integration. Chat-to-call context remains unconnected; group calls, wake qualification, and physical iPhone locked-screen evidence remain open.

### 2026-10-20 — Real contact call-to-chat qualification

- Added an opt-in native test-host journey through contact dialing, actual VAD/Gemma/PocketTTS/output, hang-up, and a subsequent real chat generation. Uses recorded 16 kHz PCM on the capture clock; not an acoustic latency measurement.
- First run failed with capture overrun and a Thread Performance Checker warning at synchronous player.stop. Preserved `/private/tmp/blessenger-real-call-memory-a.log` and `Qualification/Local/blessenger/call-memory-a`.
- clearPlayback now skips AVAudioPlayerNode.stop when queuedBuffers is zero. Queued playback still stops and records playback.player_stop duration. Generation IDs, heard progress, waiters and cancellation bookkeeping remain intact.
- Follow-up passed: heard reply "Four."; later chat answered "You asked what 2 plus 2 is." Provenance and exact heard text were included in the frozen request, with no call chat bubbles. Receipt: `Qualification/Local/blessenger/call-memory-b/call-memory-receipt.json`; native test log `/private/tmp/blessenger-real-call-memory-b.log` (five XCTest cases passed).
- Separate real synthesized voice-note pause/seek/resume/cancellation test passed: 30.183584 ms stop, no microphone capture for playback, persisted text unchanged. Receipt directory `Qualification/Local/blessenger/call-memory-cancel`; log `/private/tmp/blessenger-call-memory-cancel.log`.
- A lower-QoS warning also occurred at runtime.close during shutdown; not resolved by the drained-player change. One passing call does not establish a latency distribution or prove all capture stalls resolved.
- Mac Release and iOS Simulator builds passed (`/private/tmp/blessenger-memory-release.log`, `/private/tmp/blessenger-memory-ios.log`). Fresh codesign-verified outputs/Blessenger.app installed and launch confirmed with existing contacts/history. This replaces the prior print/hover package.
- devicectl currently reports only simulated iPhones, no physical iPhone. Physical-device locked-screen qualification and the 230 ms substantive reply distribution remain open, along with chat-to-call context, group calls and wake mode.

### 2026-10-20 — Chat-to-call memory and round-trip qualification

- During asynchronous call establishment, snapshot recent contact chat context from the store. Include its conversation/message/author provenance in the journaled pickup input. This adds no synchronous UI work or per-utterance retrieval.
- Pickup input is explicitly marked as a call event. Quoted audio inside its memory cannot be exported as a new spoken utterance on subsequent memory retrieval. The complete pickup input is preserved in normal transcript/cache reconciliation.
- New journal test passed: pickup context containing an audio reference survives commit exactly, but exports no spurious call utterance.
- Real native-host chat -> call -> chat test passed (19.501 s total test): chat teaches favorite color chartreuse; spoken question asks the favorite color; heard response is "Your favorite color is chartreuse."; subsequent chat recalls "You inquired about your favorite color." Calls created no additional chat bubbles. Receipt: `Qualification/Local/blessenger/chat-call-chat-a/call-memory-receipt.json`; log `/private/tmp/blessenger-chat-call-chat-a.log` (three tests passed).
- Twelve HeardTurnJournal XCTest cases and four ConversationHistory Swift Testing cases passed, including restart, speculation discard, unheard-tail rejection, and duplicate-publication prevention. Log `/private/tmp/blessenger-memory-journal.log`.
- Mac Release and iOS Simulator builds passed (`/private/tmp/blessenger-bidirectional-mac.log`, `/private/tmp/blessenger-bidirectional-ios.log`). Fresh codesign-verified outputs/Blessenger.app installed and launched.
- These are isolated native-host semantic and journal checks, not a physical iPhone or acoustic latency claim. Larger memory corpora, long multimodal inputs, group calls, wake mode and the substantive 230 ms distribution still require work/qualification.

### 2026-10-20 — Resident chat reconciliation after canonical edits (qualification running)

- Found identity-only text-session reuse: unchanged contact/chat/prompt could retain a resident transcript that no longer matched canonical messages.
- Track the canonical history associated with the resident text session. Reopen/reconcile when it changes. Before persistence, compare actual native history off the UI thread; rebuild from canonical history if an edit arrived during generation.
- Initial real-model regression failed safely at restore: the existing runtime intentionally rejects divergent caches. Preserved `/private/tmp/blessenger-resident-edits-a.log` and `Qualification/Local/blessenger/resident-edits-a`.
- Added explicit reconcileTranscript mode for text chat. It loads and validates cache metadata, reuses only an exact canonical prefix, and otherwise replays the canonical transcript without loading the divergent cache. Default call recovery remains strict/fail-closed. Historical cache files are preserved.
- Real-model regression tests deletion between turns and deletion between inference and persistence, then verifies published native cache history equals the canonical transcript exactly. Follow-up currently running under `/private/tmp/blessenger-resident-edits-b.log`.
- Follow-up passed: real model answered UNKNOWN after each of the two canonical-deletion scenarios; final published native history exactly matches the authoritative two-message transcript. Receipt: `Qualification/Local/blessenger/resident-edits-b/resident-reconciliation.json`; `/private/tmp/blessenger-resident-edits-b.log` records 13 XCTest cases plus 4 Swift Testing history cases passing.
- Mac Release and iOS Simulator builds passed (`/private/tmp/blessenger-edits-mac.log`, `/private/tmp/blessenger-edits-ios.log`). Fresh codesign-verified Blessenger.app installed and launch confirmed. This verifies canonical-history reconciliation, not permanent erasure of quoted facts from other retained messages/memories.

### 2026-10-20 — Shared longest-prefix restoration

- Removed reconcileTranscript and the chat-edit special case. All restoration now selects the longest exact canonical prefix among published checkpoints, then prefills the authoritative suffix. Valid divergence falls back to a shorter retained prefix or empty context; malformed metadata/history remains an error.
- Retain at most eight distinct same-configuration checkpoints. Each generation contains an immutable prefix-records.json manifest published only by the atomic CURRENT update. Failed/unpublished generations and retired branches are not candidates. Retention cleanup runs after publication and preserves every referenced generation. Exact full-history matches stop the candidate search early.
- Store tests cover truncated histories, divergent branches, restored branches, runtime/prompt isolation, retention bound, retirement, corrupt candidate rejection and failed writes. `/private/tmp/blessenger-shared-prefix-a.log`: 20 XCTest plus 4 Swift Testing cases passed, including journal/history and real deletion reconciliation.
- Extended real-model test passes after both deletions (UNKNOWN), then after restoring the earlier branch (ORCHID-482917). Final native saved history equals authoritative history. Receipt `Qualification/Local/blessenger/shared-prefix-b/resident-reconciliation.json`; `/private/tmp/blessenger-shared-prefix-b.log`: 8 XCTest cases passed.
- First shared call regression failed before inference because the disk filled during model compilation; Xcode independently reported ENOSPC. Preserved `/private/tmp/blessenger-shared-prefix-call.log` and its run evidence. After that concrete failure, consolidated only generated Compiled caches for named runs from this session into work/qualification-compiled, recovering ~16 GiB. Kept transcripts, native conversation caches, receipts, and HF assets. Future isolated qualification runtimes should symlink Compiled to that shared cache instead of generating another 2.2 GiB copy.
- Repeated real chat-call-chat test passed in 17.213 s after space recovery, using the shared compiled cache. `/private/tmp/blessenger-shared-prefix-call-b.log`; receipt `Qualification/Local/blessenger/shared-prefix-call-b/call-memory-receipt.json`. This is semantic/recovery qualification, not a substantive latency distribution.
- Mac Release and iOS Simulator builds passed (`/private/tmp/blessenger-prefix-mac.log`, `/private/tmp/blessenger-prefix-ios.log`). Fresh codesign-verified Blessenger.app installed and launch confirmed. Retention is eight complete checkpoint histories, not arbitrary token-level KV truncation. Group calls, wake mode, physical-device qualification and substantive latency distributions remain open.


### Recipient header and sampling correction (2026-10-20)
- New-message recipient field occupies the desktop titlebar header between New Message and Call; suggestions remain below. Tab and Return accept the highlighted match; click accepts a suggestion.
- Recipient lookup suppresses contacts with only deleted direct conversations, keeping new contacts and live direct conversations available. Restoration re-enables suggestions; deleting a group does not suppress its members.
- Packaged Mac UI verified top-row alignment, Tab accepting Gabor, Return accepting Peter, clicking Judith, and no results for deleted Qualification. Five ConversationRouting tests passed; macOS and iOS Simulator builds passed for these changes.
- Quality investigation: live recent Gabor call/chat checkpoints used E4B revision e6a3892a8c22cf87ff99583996149cf3cb32452b with temperature 0.6, top-p 0.95, top-k 64, seed 0, 256 output tokens, thinking off. All 14 saved contact name/prompt/avatar/voice fields match bundled originals. Original YAML source hash matches provenance; recent live Gabor system prompts match the roster exactly.
- Changed every Gemma session to temperature 1.0 using one shared value for native sampler setup and checkpoint identity. Existing canonical transcripts remain authoritative; incompatible sampler checkpoints are not imported. Real resident deletion/publication-race/branch-restoration qualification passed at temperature 1.0 (/private/tmp/blessenger-temp-one-test.log).
- This is not a conversational-quality acceptance claim or a switch to 12B.
- Earlier three-turn call latency baseline failed with microphone overrun and AVAudioPlayerNode.stop main-thread performance warning (/private/tmp/blessenger-group-baseline-a.log). No passing latency distribution was obtained; preserve this failure for audio-stop follow-up.


### Playback reset barrier (2026-10-20)
- Measured blocking player.stop on the main actor in the failing full-call baseline. Cancellation now mutes immediately and executes player.stop/play on a separate actor. Every new scheduled frame awaits that reset and checks the playback epoch; teardown waits before pausing or reusing either audio graph.
- Playback ledger snapshots remain frozen at interruption; old completion callbacks only update their old confirmation object. A repeated real output-graph test exercised 12 cancel/reply cycles, exact new-response frame counts, completed text, pending-reset teardown and restart. VoiceNoteTests: 5 passed (/private/tmp/blessenger-audio-reset-tests.log).
- Measured immediate mute maximum 0.043542 ms; off-main reset maximum 22.833541 ms. AVAudioPlayerNode still reports an internal QoS inversion on the reset worker, not the main actor; this is not a claim that engine locking disappeared.
- Three-reply production capture/VAD/LM/TTS/output/persistence test passed in 52.638 seconds (/private/tmp/blessenger-audio-reset-call.log). Recorded speech feeds the real device capture clock. Transcript restoration assertions passed; this run did not reproduce the earlier microphone overrun.
- All three substantive reply latencies missed 230 ms: 548.556, 550.237, 619.186 ms. Gemma submit-to-first-text was 420.572, 351.894, 347.264 ms. Receipts and stage breakdown are in Qualification/Local/blessenger/audio-reset-call/latency-summary.json and latency.jsonl. Temperature is 1.0; fillers disabled. Device-clock onset estimates are not acoustic measurements. This small run does not establish consistency or solve VAD timing.


### Desktop model regression and capture qualification (2026-10-20)
- Correction to the initial conversational comparison: the earlier latency-audit/RESULTS.md explicitly measured 12B with MTP, not E4B. Its fast lead-in onset was not substantive answer onset. The current runtime identity JSON matches that preserved report.
- ModelPolicy had forced E4B on every machine. Restore the documented >=16 GiB selection of 12B/MTP, retaining available-memory admission and E4B on smaller devices. Temperature remains 1.0.
- Native logs establish E4B input window=816, shrink=4, streaming=false versus 12B window=1, shrink=1, streaming=true. E4B deferred 284-363 ms of audio processing to finishAudioInput. In the successful 12B run, finishAudioInput was approximately zero; clean-turn outstanding-prefill barriers were 0.01 and 18.37 ms.
- CaptureBufferPool previously treated try-lock contention as exhaustion. Replace the pool-wide lock with fixed per-buffer atomic acquire/release leases. 16,000 concurrent leases passed uniqueness and no-false-exhaustion checks; real exhaustion still returns nil. Optimized standalone benchmark receipts are retained; they are synthetic throughput measurements, not render callback tail-latency evidence.
- Split capture failures into pool exhaustion, invalid input buffer, and capture queue overflow. The next 12B run failed specifically with queue overflow and ~1.1 s capture age; the pool fix did not solve that failure. A profiler run subsequently reached a real reply but failed cache writes with ENOSPC. These failures are preserved.
- Ordinary XCTest runs enabled Xcode's performance checker; its warning coincided with the long scheduling gap. Use the already-existing CallGemmaLatency scheme for timing, retaining diagnostic runs separately. This is a suspected instrumentation contribution, not proof that all runtime scheduling stalls are absent.
- After clearing obsolete task-created app copies and regenerable scratch model compilation caches in response to ENOSPC, the 12B three-turn test passed with the latency scheme. The duplicate scratch E4B model hash matched the pinned HF artifact and was replaced with an HF-cache symlink; no user transcripts/models were discarded.
- 12B/MTP, temperature 1.0, fillers disabled, 4096-token qualification: substantive device-clock onset estimates 237.198, 315.502, 1127.458 ms. All miss 230 ms. The third question revoked a speculative endpoint; checkpoint restore took 1219 ms and the later prefill barrier 748 ms. Correct transcript restoration passed, but rebound latency remains a major open issue.
- Mac tests and iOS Simulator compilation passed. This does not establish physical iPhone support or production maximum-context performance. Full receipts are under Qualification/Local/blessenger/restore-12b-latency.

### Speculative rebound stage isolation (2026-10-20)
- Added separate recovery writer-wait, disposal, create, lookup, native-load, and suffix-replay metrics. The three-question rebound-stages-b fixture passed transcript/restoration assertions.
- Rebound recovery: 1277.187 ms total, 1275.679 ms native load, 0.959 ms prefix lookup, 0.482 ms create, 0.000750 ms writer wait, no suffix replay. This localizes the delay inside native cache loading without yet attributing it to CRC, tensor copies, event waits, or internal contention.
- Preserved numeric receipts, test log, and analysis in Qualification/Local/blessenger/rebound-stages-b. Production maximum context and physical-device acceptance remain open.
- Follow-up rebound-profile passed transcript assertions but sampling caused audio overload warnings (not latency acceptance). Native-load subtree: 354/380 samples in outer mapped-file CRC, 10 inner CRC, 15 tensor copy, 1 unmap. Dominant observed work is checksum traversal, potentially including mapped-page faults; no lock-wait attribution. Profile and logs preserved.

### Background checkpoint read-ahead candidate (2026-10-20)
- Exact shipped Abseil checksum probe over 461,447,172 bytes: first mapping 1018.768 ms; repeated/resident traversals about 22 ms. Separate file with read advice and two-second lead time: first mapping 41.161 ms; advice issuance itself 110.168 ms. Mapping faults do not by themselves establish physical I/O time. Probe source/receipts retained under cache-read-probe.
- Added cancellable utility read-ahead after successful durable publication. It issues 8 MiB F_RDADVISE hints, owns no full-cache memory copy, and is not awaited by recovery or persistence flush. Superseding snapshots and close cancel prior traversal between requests. Hints are best-effort; no checksum or canonical-prefix validation is bypassed. CheckpointStore.save now returns the published state URL.
- rebound-read-ahead three-question Mac test passed transcript/restoration assertions, 12B/MTP, temperature 1, 4096 context, fillers off. Rebound native loads 101.601 and 70.576 ms; writer waits about 0.001 ms. Device-clock substantive onset estimates 236.535, 252.316, 346.751 ms: all still miss 230 ms. This single run is not consistency qualification, nor physical-device or maximum-context acceptance.
- Candidate source/build is not yet installed into outputs/Blessenger.app. iOS Simulator compilation passed (blessenger-read-ahead-ios.log). Cold restoration after shutdown still took 1034.672 ms in this run; read-ahead is advisory and cancelled on close, not a guarantee of residency across relaunch.

### Read-ahead repeat and VAD trace correlation (2026-10-20)
- rebound-read-ahead-repeat passed all fixture transcript/restoration assertions. Native rebound loads 94.464 and 69.300 ms; cold reopen 1101.747 ms. Estimated buffer onsets 225.294, 252.559, 337.783 ms; estimated non-silent signal onsets 226.127, 253.309, 339.783 ms. One of three met 230 ms. Preserve this distinction: software/device-clock estimates are not acoustic measurement.
- Remaining observed stages: submit to first text about 131-150 ms, first text to clause about 31 ms for short answers and 124 ms for the longer answer, synthesis about 25-34 ms. No arbitrary phrase splitting or temperature reduction was introduced.
- Added attempt-ID correlation between speculative/strict VAD threshold traces and response traces; analyzer now reports threshold-to-signal onset when exact IDs exist. Historical uncorrelated traces are not heuristically assigned to replies.
- vad-correlated-read-ahead passed transcript/restoration assertions. Estimated signal onset from strict VAD threshold: 176.916, 198.442, 315.681 ms; from estimated speech end: 226.558, 253.870, 354.544 ms. Only one of three passes the speech-end target. Correlated per-attempt evidence is preserved.
- Installed this tested macOS build into outputs/Blessenger.app after confirming idle state. Deep/strict signature verification passed; installed executable matches tested product SHA-256. Native sidebar and controls reopened successfully. This launch check is not a new acoustic call qualification.
- The correlated-trace build also passed iOS Simulator compilation. Physical iPhone, locked-screen calls, group-call integration, wake training and the full acceptance matrix remain incomplete.

### Shipping context capacity qualification (2026-10-20)
- This Mac reports 128 GiB physical memory; policy permits 32768 tokens for 12B. Existing contact checkpoints inspected separately were older 32000-token/MTP-off configurations; they do not prove the newly selected 12B context was previously qualified.
- shipping-context-32768 passed three-question transcript/restoration assertions at 32768 tokens, 12B/MTP, temperature 1, fillers disabled. Signal-onset estimates from speech end: 237.318, 268.828, 460.731 ms; strict-VAD-to-signal: 187.525, 213.216, 421.750 ms. All miss the speech-end target.
- Checkpoint files 931,209,220 bytes. Rebound native loads 182.938 and 140.507 ms; cold reopen 1160.095 ms. Capture pauses 77.579-201.632 ms. The 4096-token results must not stand in for this capacity.
- Added explicit model repository/revision/hash, context capacity, MTP, sampler, test CPU seconds and process peak RSS to future pipeline receipts. Resource scope includes two preparations and shutdown, not a physical-iPhone jetsam budget.
- devicectl still lists simulated devices only; no physical iPhone is available for locked-screen qualification.
- shipping-context-repeat passed with explicit provenance/resource receipt. Signal onset from speech end: 226.485, 263.841, 440.465 ms; from strict VAD: 176.785, 208.392, 401.725 ms. Across these two identical three-question fixtures, one of six meets 230 ms (not a general conversation distribution). Rebound loads 190.503/138.539 ms; cold reopen 1032.223 ms.
- Resource receipt: 27.361245 process CPU seconds, 3,652,567,040 bytes peak host RSS including call/restart/shutdown. RSS is not total Metal allocation, process physical footprint or physical-iPhone memory acceptance.

### Native dispatch stage isolation (2026-10-20)
- Added per-attempt native submission/admission/first-text markers, admission-lock duration and runtime queue duration. This separates controller submit (which precedes the streaming-audio finish barrier) from native generation. The 32768-token fixture passed transcript/restoration assertions.
- Completed turns: controller-submit to native-submit 0.858, 20.787, 114.396 ms; native-submit to native-first-text 138.634, 139.147, 147.887 ms; native-to-controller delivery 0.025, 0.020, 0.024 ms. Native submission call itself 0.397-0.430 ms. Admission lock maximum 0.000875 ms; runtime queue maximum 0.021209 ms. These measurements do not support Swift lock contention as the remaining bottleneck.
- Full production patch 0021 already includes verifier batches for remaining known tokens (>1). Initial partial-read suspicion that the remainder was serial was incorrect; no native patch was changed. Preserved historical verify-tail fixtures have matching outputs and serialization checks, but they do not substitute for current large-context qualification of a new change.
- Numeric receipts and test log retained under Qualification/Local/blessenger/native-dispatch-32768. New timing instrumentation is source/test-host qualified; installed app remains the prior read-ahead/correlated-VAD build.

### Shared initial speaker selection (2026-10-20)
- Replaced the call button's unconditional first-participant selection with shared ConversationRouting.initialResponder: most recent present contact in non-deleted thread history, otherwise random current participant. Unaddressed message routing uses the same function. User/guest/removed-contact messages and other chats cannot choose a speaker; duplicate names remain distinguished by UUID.
- Six routing tests passed, including deleted-message exclusion and no-eligible-contact behavior. This is source/test-host qualification, not full group-call delivery; the installed package has not been updated for this change.
- Group calls remain incomplete: controller currently binds one persona journal/runtime context/voice and one memory-call record. Sequential participant switching, spoken-name resolution and cancellation of all participant work require integration before claiming group-call support. Reuse the existing microphone/playback pipeline rather than opening one per persona.
- iOS Simulator build passed for shared initial-speaker selection and the native-dispatch timing instrumentation. Physical-device and packaged group-call qualification remain open.

### Atomic participant call-memory sessions (2026-10-20)
- Added durable CallMemorySession records associating one UI call with independent participant source ranges. registerCall validates a complete roster, distinct contacts/directories and transcript boundaries, then atomically closes preceding open ranges and publishes all participant sources/session. The existing single-contact controller path delegates to this API.
- finishCall validates all ranges before one transaction, is idempotent, and never extends a range already closed by a newer call. Session records remain outside visible chat history.
- Canonical directory identity explicitly marks directories even before creation. Regression tests exposed Foundation's creation-dependent trailing-directory representation; without normalization, late teardown could include a newer call's answer twice. The fix passed the delayed-teardown regression.
- Memory suite: five tests passed, one opt-in real-call test skipped. Includes multi-contact isolation/reopen, no chat bubbles, rejected roster atomicity and late teardown. Two failed intermediate runs retained alongside the passing run. A separate real call-to-chat test is now running; no packaged group-call claim is made.
- Real E4B call-to-chat qualification failed at the 120-second startup deadline before inference: AVAudioEngine.inputNode/AVAudioIOUnit blocked in Core Audio proxy calls. After the assertion and stuck shutdown, SIGTERM stopped only the verified isolated test host; xcodebuild ended TEST FAILED. Stack sample and full log preserved under call-session-live. No Core Audio service reset, runtime retry or live-call acceptance claim.
- iOS Simulator build passed. Memory changes are not installed into the user app; full live-call and group-voice integration remain open.

### Frozen call roster and cancelled hardware admission (2026-10-20)
- Call button now passes the entire eligible participant roster plus the shared initial-speaker selection into CallController. CallRoster freezes persona IDs/prompts/voices at dial time, rejects empty/duplicate/missing-speaker rosters, and produces separate per-contact transcript directories. Single-person dial delegates to the same entry point.
- Call startup registers all roster memory sources atomically; one selected persona still owns the current live runtime/voice. This preserves membership through dialing but does not yet implement live participant switching, spoken-name routing or sequential group voices. Those remain required.
- PreparedAudioEngine checks cancellation before preparation, before accepting a constructed graph, before hardware start and immediately after native start. Native synchronous Core Audio calls remain uninterruptible; the checks reject late success and stop a cancelled start on return, not a guarantee of bounded platform-call completion.
- Seven focused tests passed: memory isolation/session boundaries/roster freezing plus cancellation before prewarm, which verifies zero graph builds, running engine and capture callbacks. No new microphone initialization was required by these tests. Existing real-call/Core Audio startup failure remains unresolved; source is not packaged into the user app.
- iOS Simulator compilation passed for the roster/cancellation changes. Full live Mac and physical-iPhone acceptance remain open.

### Reuse immutable voice conditioning (2026-10-20)
- SpeechOutput retains up to sixteen cloned voice prompts, keyed by SHA-256 of decoded, normalized sample PCM and CPU/ANE backend. No file-path or timestamp identity; edited content at the same URL cannot reuse stale conditioning. FluidAudio's cloned prompt is immutable value data; sessions build independent synthesis state.
- Re-selecting the active voice preserves prepared leads; switching voices invalidates active leads. Validation and persistence commit precede activation. A superseded asynchronous voice request cannot activate or commit after a newer request.
- Real encoder qualification passed in the packaged XCTest host: unchanged sample, switch to built-in and back, identical audio at another path, replacement with different audio at the same path, and restoration of the original cached voice. Assertions count actual clone invocations. This does not re-open the accepted quality of the supplied voices and does not establish complete group-call playback qualification.
- Mac build passed; source remains uninstalled. Live participant handoff, distinct sequential group playback, Core Audio startup reliability, and physical iPhone qualification remain open.
- iOS Simulator compilation also passed. This is compilation evidence, not physical-device or locked-screen inference acceptance.

### Prepared voice audio retention (2026-10-21)
- Participant handoff inspection found greeting synthesis would still repeat after each voice switch. SpeechOutput now retains prepared lead PCM/alignment alongside the exact conditioning/backend identity, with shared eviction of cloned conditioning and its audio. Built-in voice audio is separated by backend as well.
- Selection clears the configured greeting/reply lists until the caller configures them again, but retains validated synthesized audio. A superseded asynchronous preparation cannot publish its result into a newer voice selection.
- Real-model test now synthesizes the same greeting under two distinct voice samples, asserts a separate synthesis for the second voice, and verifies no additional synthesis when returning to the original. The original content-identity clone checks remain in the test. This is preparation reuse evidence, not end-to-end group handoff or latency acceptance.
- Final source passed the real encoder/synthesis test in the Mac XCTest host and iOS Simulator compilation. Logs: Qualification/Local/blessenger/voice-lead-reuse. Changes remain uninstalled; participant routing/handoff, shared-call context, and complete platform qualification remain required.

### Current call-to-chat integration qualification (2026-10-21)
- Fresh packaged test-host run passed testRealContactCallFeedsChatMemory with the current roster, call-session storage, cancellation-admission, voice-conditioning and prepared-audio changes. The E4B/4096/MTP-off semantic fixture heard "Two plus two is four."; the later chat answered "You asked for the sum of two and two." Its request included the actual call ID, contact ID, message provenance, source user audio and heard reply. Calls created no chat bubbles; audio was stopped at teardown.
- Evidence: Qualification/Local/blessenger/call-session-live-voice-reuse/test.log and call-memory-receipt.json. This is a current passing fixture, not a 12B latency or group-call acceptance result.
- The earlier call-session-live startup failure remains valid evidence. This run still logged a voice-processing stream timeout and approximately eleven seconds before capture-graph preparation advanced. Do not describe startup reliability as fixed.
- The qualification runner now requires a fresh named evidence directory, preventing accidental reuse of earlier transcripts or overwriting failure evidence.
- Current audio lifecycle fixture passed six starts across cold/prewarmed modes; each mode retained one graph across three calls and microphone callbacks ceased after pause. First cold start returned in 1677 ms; prewarmed start in 79 ms; subsequent starts in 44–46 ms. Main-actor maximum observed gap was 12.493 ms and synchronous stop returned in 0.128–0.235 ms. Stop-return time is not full hardware shutdown duration. Evidence: Qualification/Local/blessenger/audio-lifecycle-current. An initial mistyped test-class selector executed zero tests; its log is retained and is not acceptance evidence.
- Neither passing fixture establishes broad audio-route reliability, physical iPhone behavior, full group-call handoff or the 230 ms substantive response target. Installed user bundle has not been replaced by these test-host builds.

### Group-call participant admission (2026-10-21)
- Added stable-ID participant selection for the frozen call roster. The next audio-input stream waits for the outgoing response/interruption and participant activation before native prefill; its response waits for that same activation before choosing the journal. Runtime context and cloned voice change while the existing capture/playback engine remains in place.
- A group call's header now provides a native participant menu. Selection is for the next input boundary, not a mid-sentence persona swap. Unknown IDs are rejected. Hang-up cancels and joins every registered handoff task; each task has an independent identity and checks call identity across asynchronous preparation.
- Real two-contact qualification passed in group-participant-boundary-directed: initial contact greeted with Bessel conditioning; requested contact answered with Francine conditioning. Only the requested contact received the user's call turn, graph build count stayed one, and the later explicitly addressed chat included that contact's call memory/provenance. Two distinct persisted conditioning hashes are recorded. The first run's call assertions passed but its later unaddressed group-chat assertion failed because the permitted random responder was the other contact; this failed fixture and its receipt are retained.
- This is explicit participant handoff, not completed group-call behavior. Spoken-name detection/routing, shared attributed call context, bounded autonomous participant replies, interruption/route-change matrix, native menu interaction and physical-device qualification remain required. User app is not yet replaced.
- Final source, including the native menu and independent handoff-task IDs, passed the real group fixture again (group-participant-boundary-final) and iOS Simulator compilation. Neither build has been installed over the user's bundle yet.

## 2026-10-21: native portrait atlas overflow and stability hold

- Replaced SwiftUI atlas cropping in ContactAvatar with individual portrait assets and explicitly sized copied NSImages for the native menu bridge. Preserved all fourteen identities and original illustrations.
- Release build and two targeted portrait/native-menu regression checks pass; evidence: Qualification/Local/blessenger/avatar-bridge-regression. Not promoted to installed Blessenger pending native call/crash qualification.
- Correction to earlier native process disappearance: user crash report establishes malloc free-block corruption, not a clean quit. The SwiftUI/sidebar stack is the detection site, not an established corruption origin. Original report preserved under Qualification/Local/blessenger/native-heap-corruption.

## 2026-10-21: shipping configuration reproduces native corruption

- Added opt-in BLESSENGER_SHIPPING_REPRO to real contact call/chat qualification: pinned 12B/MTP, 32768 context, original bundled Bessel/Gabor prompts/voices, preceding Bessel chat reply, then call/handoff.
- AddressSanitizer run failed. Before the recorded utterance, greeting reported `Start a speech response before adding text.` Later prefill hit a heap-buffer-overflow in native FillAttentionMask: memset writes 1024 bytes beginning at the end of a 1152-byte Metal memory allocation. This supplies an actual corrupting write, unlike the original sidebar allocation detection stack. Exact dimensions/caller state and relationship to the original crash still require investigation.
- Evidence: Qualification/Local/blessenger/shipping-chat-call-asan/{test.log,asan-report.txt,result.json}. Do not treat the restarted test host's zero-test summary as a pass; xcodebuild exited 65 and marked the test failed.
- Installed app remains unmodified; call reliability and native memory safety remain release blockers.

## 2026-10-21: native repair candidate under build

- Located a dispatch mismatch in patch 0021: PrefillInternal reused the decode graph for one-token short prefill but sent kPrefill to its local ring attention mask. This falls through to absolute indexing for a single-row decode mask. Patch 0024 sends kDecode for the decode signature, preserving verifier/prefill modes for those signatures.
- Patch 0023 adds extent/index guards before mask writes and rejects absolute history positions exceeding a mask row, with exact dimensions in the error. Patch 0024 adds a native test for a 288-column, 256-token-ring, single-row mask at timestep 512, invalid extents, and preservation of padding. Patches apply cleanly; native compilation/test qualification pending.
- Diagnostic-only native-attention-guard build intentionally interrupted before completion after finding the dispatch error. Repair build uses work/native-attention-fix, log /private/tmp/blessenger-native-attention-fix.log. No runtime qualification claimed.
- Fixed custom-work-directory packaging: build-runtime.sh now passes its work directory to package-runtime.sh rather than inadvertently copying the old default runtime back over a new custom build. Shell syntax checks pass.
- Added response-phase diagnostics and differentiated missing playback graph/ledger errors; no call lifecycle behavior change yet.

## 2026-10-21: runnable native regression and clean-build repair

- Corrected regression expectations to distinguish the 288-slot physical ring from the 256-token attention window. Patch 0024 now adds a dedicated `//runtime/executor:attention_mask_bounds_test` target; the upstream broad utils test file had no target in this checkout.
- Stopped native-attention-fix build to include that runnable target. Candidate-v2 then failed during compilation because the historical patch series omitted runtime/util/tracked_state_output.h. Compared all original staged added files against the fresh checkout: this was the only absent file. Compared existing historically patched file contents: differences were confined to the expected executor dispatch and BUILD changes.
- Patch 0025 restores the exact existing TrackedStateOutput header into the reproducible series; no cache API behavior changes. Candidate-v2 failure preserved in Qualification/Local/blessenger/native-attention-repair.
- Current running build: work/native-attention-candidate-v3; log /private/tmp/blessenger-native-attention-candidate-v3.log. Native tests, shipping ASAN repeat, and packaged interaction qualification remain pending. No installed bundle replacement.


### 2026-10-21: native corruption repair and quieter hosted tests

The shipping 12B ASAN replay reproduced a native attention-mask heap overwrite after chat-to-call transition. Decode-signature short prefill selected the prefill mask mode, allowing absolute timestep indexing into a bounded ring mask. Runtime patches 0023/0024 add bounds rejection and select decode mode; the dedicated native ring-mask regression passes. Patch 0025 restores a header omitted from the historical patch series. Custom-workdir packaging now copies the runtime actually built.

The repaired replay initially failed only its raw-JSON heard-text assertion. It now compares decoded content exactly; `shipping-chat-call-asan-decoded-receipt` passed, including participant handoff, relationship memory, follow-up chat and shutdown. Both failed and successful receipts remain preserved. This is hosted-test evidence, not packaged-app acceptance.

Hosted macOS tests now suppress automatic presentation of the test-host window. Hosted audio defaults to muted final mixer output and muted ringback/recorded-note playback; inference, PCM rendering and playback callbacks remain active. `CALL_GEMMA_TEST_AUDIBLE=1` opts a hosted test into audible output (from xcodebuild, use `TEST_RUNNER_CALL_GEMMA_TEST_AUDIBLE=1`). Normal launches remain audible. Muted tests cannot qualify acoustic output, echo cancellation, or audible onset. Packaged 12B repeated-call, contact switching, barge-in and hang-up qualification remains pending.


Packaged 12B qualification exposed a separate regression: two live calls terminated with capture queue overflow. Original queue capacity is 16 callbacks (about 170 ms at the observed 512 frames/48 kHz); measured queue delay reached 263-313 ms. The native sample caught repeated window layout. CallController published an unused microphone level on every VAD chunk, invalidating the entire observed messaging shell. The level event/publication has been removed; microphone diagnostic text now has a separately observed object used only by the diagnostic sheet. The attempted larger-buffer candidate was abandoned and not installed; queue/pool remain 16/32. A regression check asserts diagnostic changes do not notify the messaging controller. Native repeat qualification is pending.

### Removal and status audit (2026-10-21)
- Removed prepared opening-audio synthesis/storage/playback and forced response-prefix handling from Swift, native patch series, and qualification driver. Greetings now use the ordinary generated-text-to-speech path. Historical diagnostic receipts are retained.
- Contact-name detection remains unimplemented: the persisted wakeName field is not a detector. Required work includes on-device multi-voice example generation, frozen speech embeddings, per-name classifier training off UI/audio threads, real held-out/confusable-name qualification, and stable-ID routing in active group calls. Failed qualification must leave the detector disabled.
- Group participant selection and handoff exist; spoken-name selection and fully qualified multiparty calls remain incomplete.

- Removal verification completed for macOS and both iOS runtime slices. The packaged 12B lifecycle journey passed, but follow-up content qualification failed on repeated unrelated output. Fresh measured onset estimates: 274.393, 943.512, 311.787 ms (3/3 over 230 ms); these do not constitute release qualification. Receipts: Qualification/Local/blessenger/app-without-openers-stress-01/RESULTS.md.
