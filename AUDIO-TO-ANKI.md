Run `./anki-audio.swift` to start the Audio Hijack session “Anki Audio”. Run it again to stop and attach the recording. Ctrl+G uses this script through `.skhdrc`; output goes to `/tmp/anki-audio.log`.

The file is an executable Swift script (`#!/usr/bin/env swift`); no build step, packages, or Shortcuts workflow is required. It uses Audio Hijack's supported `.ahcommand` JavaScript bridge for session control and recorder status, and Foundation for everything else. Requires Swift command line tools, Audio Hijack with external scripts enabled, and Anki with AnkiConnect on localhost:8765.

Silence detection relies on the Recorder block removing/pausing on silence (the existing “Anki Audio” configuration). It stops after 1 second without recorder duration advancing after audio begins, or 5 seconds if no audio begins. If you disable silence removal in Audio Hijack, this signal no longer detects silence. A 300-second limit provides a fallback. Set `ANKI_AUDIO_SILENCE`, `ANKI_AUDIO_MAX_SECONDS`, or `ANKI_AUDIO_SESSION` to override defaults. Keep one Recorder block in this session.

A process lock makes a second invocation request a stop, including while the first invocation is starting. The first process keeps ownership through finalization and attachment. SIGINT/SIGTERM also request a stop. Force-killing the process cannot run cleanup; if this happens, stop the session in Audio Hijack before restarting the script. The script leaves Audio Hijack open and does not quit other sessions.

Both stop paths wait for exactly one new recording from this session and for its file size to stabilize. The script uploads that file with AnkiConnect, selects the newest note matching `added:1` before recording begins, replaces its `SentenceAudio`, and reads the field back to verify it. It preserves the original audio on failure and prints its path. Anki field updates are not retried automatically to avoid ambiguous duplicate operations.

Commands:

```sh
./anki-audio.swift --check          # Read-only check of Audio Hijack and AnkiConnect
./anki-audio.swift --status
./anki-audio.swift --stop           # Stops only if this controller is active
./anki-audio.swift --record-only    # Tests capture and stop without changing Anki
./anki-audio.swift --attach '/full/path/to/recording.mp3' # Retry attachment
./anki-audio.swift --self-test
```

Validation: Swift interpreter self-tests and live connectivity checks passed. Live capture tests exercised silence-stop and second-invocation stop with Anki updates disabled. Actual note replacement was not exercised against the personal collection.

Audio Hijack API: https://www.rogueamoeba.com/support/knowledgebase/?showArticle=AH-Scripting-API
External command files: https://www.rogueamoeba.com/support/knowledgebase/?showArticle=AH-Scripting-Triggering

New recordings use `audiohijack-%date %time` in Audio Hijack, for example `audiohijack-20250411 1719.mp3`. The Anki upload keeps the recording filename. Audio Hijack and AnkiConnect resolve filename collisions rather than overwriting different recordings. The Recorder’s existing MP3 format is retained.

Before recording, the script checks the target note’s SentenceAudio. If it is nonempty, a native Cancel / Overwrite dialog appears, with Cancel as the default. The selected note stays fixed throughout recording. If its audio field changes before attachment, the script preserves the recording and refuses to overwrite the changed field. Manual `--attach` retries use the same confirmation.

After recording finishes and its file is finalized, the script closes Anki Browse if present, updates the target note, then reopens that same note. Browse is left alone throughout recording. Closing Browse saves pending editor changes; if SentenceAudio changed since approval, attachment is cancelled and the recording is preserved. Accessibility permission is required for the launcher (such as skhd or Terminal); inability to inspect or close the window stops attachment with an error. Anki must be running and reachable before a normal recording begins. Manual `--attach` uses the same close/update/reopen sequence.

If the AnkiConnect connection fails, a native “Anki isn’t available” dialog asks you to open Anki and enable AnkiConnect. The technical error remains in the log.
