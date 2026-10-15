# WTF iPhone: to do

Findings from a full review of build 35 (five reviewers: listening, pipeline, Ask, screens, first run / App Store), checked against the code. Ordered roughly by severity within each group. Paths are under `ios/`.

## App Store blockers
- [x] **Privacy manifest missing**: no `PrivacyInfo.xcprivacy`, so App Store Connect rejects the upload (ITMS-91053). Add one to the app target: UserDefaults (CA92.1), file timestamps (C617.1), no tracking, no data collected.
- [x] **No privacy policy or recording explanation in the app** (guideline 5.1.1). Add a privacy policy link in Settings, and a first-run screen before the microphone prompt: what's recorded (including other people), how long it's kept, that it stays on the iPhone, how to stop and delete.
- [x] **Recording intents can finish with no Live Activity**: iOS's rules for recording intents don't allow this, and iOS 27 reportedly closes the app. Take `AudioRecordingIntent` off `WTFMenuIntent` (it reads answers aloud with the session active and no card). Don't start listening from a recording intent when Live Activities are off (explain how to turn them on). Re-request the card inside `perform` when already recording but the card has ended. (Intents.swift, ControlIntents.swift, ListeningActivity.swift)
- [x] Add `ITSAppUsesNonExemptEncryption = false` to the Info.plist (project.yml).
- [x] Remove `NSUserNotificationsUsageDescription` (not a real key; project.yml).
- [ ] Before submission: code signing is off in project.yml and CI has no archive/upload step. Decide whether the name "WTF" passes review / affects the age rating.

## Listening, pill and Lock Screen card
- [x] **"Recording" pill stays after WTF is closed or crashes (stop-only intent, cleared at launch, and goes stale after 15 min without updates: all done), and its Stop button can turn listening ON** (Stop is the toggle intent). Add a stop-only intent for the card/pill Stop. End stray cards at launch when not recording. Refresh a `staleDate` while recording and show "Not recording" when stale. (ListeningActivity.swift, ControlIntents.swift, WTFWidgets.swift)
- [x] **Audio engine released inside its own configuration-change handler** (new in build 35): Apple warns this can deadlock. Likely when AirPods go in or out. Move the restart off the notification thread and keep the old engine alive until later. (Recorder.swift `freshEngine`)
- [x] **A stop followed quickly by a start kills live transcription for the new session and splits its conversation.** The stop's tail (`pipeline.run()` → `LiveTranscriber.stop()` → `closeLatest()`) runs after the new start. Delete All (stop + start 0.6 s apart) nearly always hits it. Use a listening generation counter, and `catchUp()` instead of `run()`. (AppModel.swift `setListening`)
- [x] **One failed restart ends listening for good**: e.g. opening WTF during a call ('!pri') shows "WTF stopped listening" and it never resumes. Keep running/stalled on interruption-type errors and retry with back-off. (Recorder.swift `restart`, AppModel.swift `resumeIfNeeded`)
- [ ] **After iOS ends the card (~8 h) or it's swiped away, answers from the buttons vanish**: `showing` is only `activity != nil`. Check `activityState == .active`, restart the card when WTF comes forward or inside the intents, and keep `since` = `listeningSince` so the timer doesn't reset. (ListeningActivity.swift)
- [x] **WTF records its own voice**: read-aloud voice samples in Settings play through the speaker while listening and get transcribed (e.g. a "Dentist, Thursday" suggestion). Car kits count as headphones. Ignore recorded audio while ReadAloud is playing. (ReadAloud.swift, Recorder.swift, VoicePicker.swift)
- [x] **Control Center "WTF Listening" fails silently**: it tries the mic from the background and discards the result. Report the result (notification), or bring WTF forward. (ControlIntents.swift)
- [x] **"Stop WTF" / Stop Listening doesn't stick if `recording` is already false**: always clear the saved `listening` flag, end every card and cancel the "paused" notification. (Intents.swift `StopListeningIntent`)
- [x] **A deleted conversation's topics (and any answer) stay on the Lock Screen card**, and the cached "before that" backstory too. Refresh the card from `latestThreads()` after deletes. (AppModel.swift `remove`)
- [x] `setListening(false)` doesn't cancel the 3-minute "WTF has paused listening" notification. (AppModel.swift)
- [x] **No "starting" state, and start failures only show on Ask.** Listen on Timeline/Lists and the Settings toggle fail silently (the toggle snaps back), and the first start includes the speech model download with no progress or time limit. Add a busy state, an alert with the reason, "Open Settings" when the mic is denied, and a deadline on the download. (AppModel.swift, WTFApp.swift, SettingsView.swift, SpeechEngine.swift)
- [ ] **Pill and card exceed the 160 pt height limit** (≈169–185 pt with trail + 3 buttons), so buttons get clipped. Drop the trail in the pill, smaller circles (≈40/50), less padding; with an answer showing hide the topic. The 3-line answer cuts spoken recaps; allow ~4 smaller lines. (WTFWidgets.swift)
- [x] Pill shows "● Recording" and "Listening" at once: show only the topic in the centre.
- [x] `stopSpeaking` during `ReadAloud.prepare()` caches a cut-off answer that later presses replay. (ReadAloud.swift)
- [ ] Tapping the pill after WTF was killed: `wtf://listening` is ignored because `recording` is false, then listening restarts with no stop sheet. (Fixed: a stop pressed while a start is in flight is no longer overridden.) when the start finishes. (WTFApp.swift, AppModel.swift)
- [ ] Minor: `hasHeard` turns on for any kept recording before music is filtered out; `Recorder.running` read without the lock.

## Pipeline, data and deleting
- [x] **Summaries refuse sensitive talk**: `permissiveContentTransformations` only applies to `String` responses; `@Generable` summaries, list items, memory, topics, corrections and facts still throw `guardrailViolation`. The conversation shows "Summarising…" forever. Add a plain-text summary fallback (parse "Title:" + bullets). (Brain.swift)
- [x] **A failed summary is retried on every run, forever** (each new chunk re-runs up to 60 s of AI); with Apple Intelligence off, every unsummarised conversation is rescanned each chunk. Track attempts/last try, back off, give up with a fallback title, still run the later steps. (Pipeline.swift `think`/`summarise`, Models.swift)
- [x] **Deleting the conversation in progress brings its last words back**: the chunk being recorded and pending chunks become a new conversation. Cut off chunks recorded before the delete (like `wipedAt`) and clear LiveTranscriber's recent words. (AppModel.swift `remove`, Pipeline.swift `forget`, LiveTranscriber.swift)
- [x] **Action button can read out deleted content**: `Standby.refresh` sets `ready` after a ≤15 s AI call, undoing a `forget()` made meanwhile. Add a generation counter. (Standby.swift)
- [x] **List suggestions silently dropped by a loose duplicate check** (half the words in common, any conversation, events ignore dates): "Dentist appointment" blocks "Doctor's appointment"; "Mum's birthday" blocks "Dad's birthday"; "Milk" blocks "Milk chocolate". Require near-identical titles and the same day for events. (WTFCore ActionRules.swift `similar`, Pipeline.swift `suggest`)
- [x] **Lasting facts are deleted with their conversation on expiry** (default 7 days), contradicting Things WTF Knows. Detach facts (conversationID = nil) on expiry instead. (AppModel.swift `remove`)
- [x] **"Forget" on a person deletes on the background context while People shows them**: the same pattern as the old Delete All crash. Delete on `mainContext`. (Pipeline.swift `forgetPerson`, SettingsView.swift)
- [x] **`expireOld` runs twice at launch** (task + becoming active), so the second deletes already-deleted objects. Serialise it and skip ids already hidden. (WTFApp.swift, AppModel.swift)
- [x] **A deleted list item comes back as a suggestion** (duplicate check only sees items that still exist). Mark deleted items dismissed instead of deleting them. (ListsView.swift)
- [x] **Conversation memory merges different notes**: "ring the garage" + "ring the dentist" keeps only one; "Party at the Crown" + "Dinner at the Crown" keeps one. (WTFCore Understanding.swift `cleaned`)
- [ ] A retried failed chunk is appended after newer lines (recap quotes old words as "the last thing said"), or becomes a stray overlapping conversation. (Pipeline.swift `attach`)
- [x] **Transcripts go into iCloud/computer backups** (only `audio/` is excluded) while the app says "nothing is uploaded" / "stays on this iPhone". Exclude Application Support from backups, or change the wording. (Recorder.swift, SettingsView.swift)
- [x] Keep Transcripts only applies when the app comes forward; left listening in the background for days, old conversations stay. Run expiry periodically.
- [ ] Lower: Pipeline.swift:89 reads `chunk.start/end` inside a `@Sendable` closure (copy first); writes to a chunk after an await it may have been deleted in; `compact` drops "(…earlier part left out…)" markers; topics crossing midnight aren't found by `lines(of:)`; facts/AI list items never extracted if killed after the summary; done/dismissed items never cleaned up.

## Ask and answers
- [x] **Questions about conversations are answered from the Lists**: "Ask About This" on "Team meeting…" gives "I haven't heard about any upcoming appointments"; "What did I promise Tom?" lists the to-dos. Skip list answers when `focus` is set; treat did/tell/told/decide/happened/who/why as past; to-do questions list only to-dos. (WTFCore Transcript.swift `ListAnswers`, AppModel.swift `ask`)
- [ ] **Deleted conversations' answers can survive**: answers are tagged only in `ask()`'s `defer`, so a delete mid-answer misses them, and Delete All mid-answer leaves an orphan. Tag as messages are added, and drop answers whose question was deleted. (AppModel.swift `ask`, `askAbout`, `answer`)
- [x] **Deleting any of the 12 most recent conversations (or its expiry) wipes recent answers**, because each answer is tagged with all 12. Tag only `focus` + `best`. (Pipeline.swift `notes`, AppModel.swift)
- [x] **Rewordings miss the quick path**: "What were we talking about?", "Where were we?", "Remind me what I was saying", "What was the last thing I said?". (WTFCore Prompts.swift `latest`)
- [ ] **General-question prompt isn't held to the 4k context** (12 titles + summaries unbudgeted; facts uncounted) → "Apple Intelligence couldn't answer that one". Budget the notes; retry smaller on context overflow. (WTFCore Prompts.swift `focused`, Understanding.swift `background`)
- [x] **No time limit on a streamed answer**: if it stalls, "Thinking…" stays and Ask is stuck until relaunch. Cancel after ~30 s with no new text. (AppModel.swift `answer`, Brain.swift `ask`)
- [x] **"Summarise my day so far" isn't a day summary** (generic prompt over the 12 latest from any day). Route to the Your Day recap. (AppModel.swift `ask`)
- [x] **Times aren't relative to now**: a recap of a conversation two days ago says "At 09:12 you were saying"; the latest/spoken prompts never say when the conversation was, so the AI says "you were just…" about yesterday. (WTFCore QuickRecap.swift `ago`, Prompts.swift)
- [x] Spoken fallback says "Then Speech cut in." and skips your newest words. (WTFCore QuickRecap.swift `spoken`)
- [x] **Follow-up buttons point at the wrong conversation** ("Summarise This" uses the latest, not the one asked about); "Add to Calendar" only switches tab; "Make a To-do List" only asks a question; they show under list answers and "not ready" messages too. (AskView.swift `FollowUps`)
- [x] **"Before that" window is used up by the reading** (a 15 s answer leaves ~5 s of the 20 s window); with nothing earlier, pressing again repeats the answer instead of "Nothing before that"; each step is logged as "WTF was I just on about?". (AppModel.swift `answerFromShortcut`, ReadAloud.swift)
- [x] Empty grey bubble when `tidy` strips everything ("Sure!"); raw framework error text in the error bubble; "Turn on listening…" shown while listening; Read My List gives only the weekday for far-off dates.
- [x] Unknown on device: whether the answer queues behind other AI work started by the flush, and whether Return in the multi-line field sends while busy (losing the question).

## Screens and UI
- [x] **Fix Words "Save" is likely white on white in dark mode** (`.confirmationAction` drawn filled with the white tint). Use a plain trailing button. (TimelineView.swift `FixWordsSheet`)
- [x] **Swipe-to-delete in Lists also switches tab** (TabSwipe's drag fires too). Turn TabSwipe off in Lists or while a row swipe is in progress. (ListsView.swift, WTFApp.swift)
- [x] **"Delete All Recordings…" deletes far more** (hand-added to-dos, typed facts, corrected words, people, Ask history) and doesn't say it can't be undone. Rename to "Delete All Data…" and list it all. (SettingsView.swift)
- [x] **Shortening Keep Transcripts silently deletes conversations** next time WTF opens. Add a footer (and a confirmation). (SettingsView.swift)
- [x] **Renaming a named speaker creates a second person** (only this conversation changes); People › Rename renames everywhere. "Rename You" for your own voice; invalid names silently ignored; the confirmation note is off-screen on long transcripts. (TimelineView.swift, Pipeline.swift `nameVoice`)
- [x] **Timeline long-press Delete has no confirmation** (the conversation page asks). (TimelineView.swift)
- [x] **Conversations can't be renamed** (still to do), and a failed summary leaves "Summarising…" for ever. Add Rename; show "Conversation" after a failure. (TimelineView.swift `displayTitle`)
- [x] "No Results / Check the spelling" shows when nobody's searching (first recording pending, or after deleting the last one). Use `searching && shown.isEmpty`. (TimelineView.swift)
- [x] Lists' tick button has no accessibility label ("circle, button"). (ListsView.swift)
- [x] Meaningful text in `.tertiary` (≈2:1 contrast): "Left hanging", "+ N more", "Writing it up…". Use `.secondary`. (TimelineView.swift, DayView.swift)
- [x] Stop sheet is a fixed 330 pt high; large text clips it. Use `.medium`. (WTFApp.swift)
- [x] Your Day can read "One conversation, at 10:42: Listening…." (placeholder titles in the plain recap). (DayView.swift, WTFCore Day.swift)
- [x] Time column (58 pt) wraps "10:42 AM" at large text; transcript times always 24-hour. (TimelineView.swift)
- [x] Raw system errors shown to users (AppModel.swift, SettingsView.swift).
- [x] Wording: "Threads" vs "topics"; "Not Now" dismisses permanently; "3 segments waiting / Process Now" is jargon; "New after 5 min of silence" doesn't say what's new; "Heard today…" while older suggestions stay; empty states say "Turn on listening" while listening; Your Day "To Do" vs Lists "To-dos".
- [ ] Check on device: tab bar selection with `.tint(.primary)`; system alerts/editor taking a white tint (e.g. Add to Calendar's "Add"); VoiceOver on rows using hidden `opacity(0)` links; a stop sheet that can't present leaves `stopSheet` true.

## First run, permissions and settings
- [x] Notification permission is asked at first launch with no context; if denied, "WTF stopped listening" and answers when not listening silently disappear. Ask when listening first starts. (WTFApp.swift)
- [x] Names from Contacts / Use My Calendar stay on after access is revoked in iOS Settings. Re-check on open. (SettingsView.swift, PersonalWords.swift)
- [x] Voice models: "Download (22 MB)" is offered while the same download runs from the first Listen, and `VoiceEngine.prepare` can start a second concurrent download. Coalesce. (VoiceEngine.swift, SettingsView.swift)
- [x] Diagnostics promises "no names" but the log records headphone names ("Sam's AirPods"). Log port types only. (ReadAloud.swift)
- [ ] `SpeechTranscriber` availability is never checked; the App Store will offer the app to every iOS 26 iPhone. Explain when the device can't transcribe.
- [ ] Design call: recap and list intents use `.alwaysAllowed`, so they read conversation content on a locked phone (and the card shows topics/answers). Consider a setting.
