# WTF for iPhone

"WTF was I just on about?" — an iPhone app that listens through the day, transcribes on the device,
tells voices apart, follows the conversation's topics, and tells you where you lost the thread.
Everything stays on the iPhone.

- iOS 26, iPhone with Apple Intelligence (15 Pro or later).
- Speech: Apple's SpeechAnalyzer, transcribed live as you talk.
- Voices: FluidAudio's Core ML ports of pyannote segmentation and WeSpeaker (22 MB, downloaded once).
- AI: Apple's on-device model (Foundation Models) for summaries, list items, the thread map and answers.
- Live Activity on the Lock Screen and Dynamic Island; "Hey Siri, WTF was I saying?" answers out loud.

## Build

GitHub Actions builds an unsigned IPA on every push to `ios/` (Releases, `ios-build-N`). Install it
with AltStore or SideStore.

On a Mac with Xcode 26: `brew install xcodegen`, `cd ios && xcodegen generate`, open `WTF.xcodeproj`.

The shared logic (`ios/WTFCore`) has its own tests: `cd ios/WTFCore && swift test`.
