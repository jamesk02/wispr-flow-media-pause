# wispr-flow-media-pause

I built this for myself as a [Wispr Flow](https://wisprflow.ai) user: I use
an external USB audio interface, which doesn't get muted when playing
music/audio/audiobooks — so instead of muting the volume, this **pauses the
media**. You don't miss anything while transcribing via Wispr Flow. Enjoy.

A tiny macOS LaunchAgent, one Swift file, no dependencies.

## Why

Wispr Flow has a "Mute music while dictating" setting. It works by setting
the **system mute flag on your default output device** — and many USB audio
interfaces (Arturia MiniFuse, and anything else whose output level is a
hardware knob) expose **no mute control to macOS at all**. On those devices
Wispr's mute call fails with `kAudioHardwareBadObjectError`, the failure is
silently ignored, and your music plays straight through dictation and bleeds
into the microphone.

You can verify whether your interface is affected: with it selected as
output, press a volume key. If you get the "no control" HUD instead of a
moving volume bar, macOS has no software mute for that device and Wispr's
feature cannot work on it.

This tool sidesteps the whole problem: instead of muting the output device,
it **pauses the player** (Spotify and/or Apple Music) and resumes it
afterwards. That works on any output device — and pausing is arguably nicer
than muting anyway, since you don't lose a chunk of the track.

## How it works

- **Trigger (default): microphone activity.** Every 250 ms it checks every
  audio input device (not just the default one — e.g. the built-in mic while
  Bluetooth headphones are the output) via CoreAudio's
  `kAudioDevicePropertyDeviceIsRunningSomewhere`. Mic goes on (held for
  250 ms) = dictation started; all mics off (for 500 ms) = dictation stopped.
  Devices are re-enumerated every check, so headsets/USB mics that connect
  later are covered. Devices with both input and output (USB interfaces,
  virtual devices) only count when some process is actually capturing
  input, so music playing through them can't look like dictation.
- Newer Wispr Flow builds (seen on 1.6.1034) no longer write the log lines
  the original version tailed. The old log trigger is still available with
  `--trigger log` (start: `Acquired recording mutex for startRecording`,
  stop: `audioRecorder: Stopping audio capture` in
  `~/Library/Logs/Wispr Flow/main.log`).
- On start: checks Spotify and Apple Music via AppleScript (each check
  guarded with `if application "X" is running`, so it can never launch a
  player), pauses whichever are playing, and remembers exactly which.
- On stop: after a short delay (default 700 ms), resumes **only** the apps it
  paused — and skips any you manually resumed mid-dictation. If nothing was
  playing at start, it does nothing at stop: it will never start music you
  had stopped.
- Rapid stop/start (re-dictating immediately) keeps music paused with no
  blip. A generation counter discards stale in-flight queries, and a
  15-minute failsafe force-resumes if a stop is ever missed, so audio can't
  stay paused forever.
- On headphones (AirPods, etc.) music can't bleed into the dictation mic, so
  pausing is pointless — `--skip-output` skips it when the **current default
  output device's name** matches a comma-separated substring list, checked
  fresh on every start (stop still resumes normally, in case you
  switched output mid-dictation). Install with it via
  `./install.sh --skip-output AirPods`, and run `--probe` first to see the
  exact device name to copy.

## Install

Requires the Xcode Command Line Tools (`xcode-select --install`) for
`swiftc`.

```bash
git clone https://github.com/kierzio/wispr-flow-media-pause.git
cd wispr-flow-media-pause
./install.sh
```

That compiles the daemon to `~/.local/bin/wispr-media-pause`, installs a
LaunchAgent to `~/Library/LaunchAgents/`, and starts it. No sudo.

**First run:** the first time it actually pauses a player, macOS shows a
one-time Automation permission prompt ("wispr-media-pause wants to control
Spotify") — approve it. Because of that prompt, the very first dictation's
pause may not land; every one after will. If a prompt was ever denied:
System Settings → Privacy & Security → Automation → `wispr-media-pause` →
enable the player app(s).

Then turn **off** Wispr Flow's own "Mute music while dictating" setting so
the two mechanisms never stack on devices where Wispr's mute does work.

## Check it's working

```bash
~/.local/bin/wispr-media-pause --probe   # player/permission health check
tail -f ~/Library/Logs/wispr-media-pause.log
```

Play some music, dictate with Wispr, and watch the log:

```
[2026-08-15T19:14:54Z] start: paused Spotify
[2026-08-15T19:14:58Z] stop: resumed Spotify
```

## Flags

| Flag | Default | Purpose |
|---|---|---|
| `--trigger <mic\|log>` | `mic` | `mic`: any input device in use; `log`: tail Wispr's log for its markers (older Wispr builds only) |
| `--log <path>` | `~/Library/Logs/Wispr Flow/main.log` | log file to tail with `--trigger log` |
| `--resume-delay-ms <n>` | `700` | delay before resuming after a stop |
| `--failsafe-min <n>` | `15` | force-resume after this long if still paused; `0` disables |
| `--probe` | — | print each player's state, the default output, and each input device and whether it's in use, then exit |
| `--skip-output <list>` | — | skip pausing when the default output device name matches any comma-separated substring, e.g. `"AirPods"` — for headphones, where music can't bleed into the mic |

## Limitations & risks (honest ones)

- **Any app using the mic pauses music**, not just Wispr: Zoom/Meet calls,
  voice notes, Siri, a browser tab with mic access. Music resumes when the
  mic is released (only what this tool paused). A mic already in use when
  the agent starts is not treated as a new start.
- With `--trigger log`: depends on two exact strings in Wispr Flow's log
  (verified against Wispr Flow 1.6.531; gone in 1.6.1034).
- **Spotify and Apple Music only.** Browser audio (YouTube etc.) is out of
  reach — AppleScript only controls named apps.
- **Why not the system now-playing layer (MediaRemote)?** It would be
  app-agnostic, but as of macOS 26 it no longer works for normal processes:
  reads report no session even while music is audibly playing, and commands
  are accepted but silently dropped. Verified live before switching to
  AppleScript. (Beware when testing that path yourself: with nothing
  playing, a dropped command is indistinguishable from a working one.)
- Log trigger tested on macOS 26.5.2 with Wispr Flow 1.6.531; mic trigger
  built on macOS 15.5 with Wispr Flow 1.6.1034.

## Uninstall

```bash
./uninstall.sh
```

Removes the LaunchAgent and binary; leaves
`~/Library/Logs/wispr-media-pause.log` behind for reference.

## License

MIT — see [LICENSE](LICENSE).
