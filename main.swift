// wispr-media-pause — pauses now-playing media when Wispr Flow starts
// dictating, resumes it when dictation stops. Built because Wispr Flow's own
// "Mute music while dictating" feature works by setting the system mute flag
// on the default output device — and many USB audio interfaces (e.g. the
// Arturia MiniFuse 1) expose no CoreAudio mute control at all, so the mute
// call silently fails and music plays straight through dictation. This
// pauses instead of muting, so it works on any output device.
//
// Trigger: tails Wispr's own log for the two markers it emits around a
// dictation, rather than guessing from keystrokes. Media control: AppleScript
// sent to specific players (Spotify, Music) via an /usr/bin/osascript
// subprocess, sending explicit pause/play (never a toggle — a toggle would
// start music that wasn't playing).
//
// Why not MediaRemote: this daemon originally used the private MediaRemote
// framework (dlopen/dlsym of MRMediaRemoteSendCommand /
// MRMediaRemoteGetNowPlayingApplicationIsPlaying). Confirmed dead on this
// machine on macOS 26.5.2 for unentitled processes — reads report no
// now-playing session even while Spotify is audibly playing, and sends
// return true but are silently dropped. AppleScript control of Spotify and
// Music was proven working from this machine instead: reads return accurate
// player state and pause/play round-trips work, so that's what drives media
// control now.

import Foundation
import CoreAudio

// MARK: - CLI flags

var logPath = NSHomeDirectory() + "/Library/Logs/Wispr Flow/main.log"
var resumeDelayMs = 700
var failsafeMin = 15
var probeMode = false
// Comma-separated substrings (matched case-insensitively) against the
// current default output device's name. Empty = feature off, behaviour
// unchanged from before this flag existed.
var skipOutputs: [String] = []

do {
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--log": if let v = it.next() { logPath = v }
        case "--resume-delay-ms": if let v = it.next(), let n = Int(v) { resumeDelayMs = n }
        case "--failsafe-min": if let v = it.next(), let n = Int(v) { failsafeMin = n }
        case "--probe": probeMode = true
        case "--skip-output":
            if let v = it.next() {
                skipOutputs = v.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        default: break
        }
    }
}

// MARK: - logging

let logLock = NSLock()
let isoFormatter = ISO8601DateFormatter()

func log(_ msg: String) {
    logLock.lock(); defer { logLock.unlock() }
    print("[\(isoFormatter.string(from: Date()))] \(msg)")
    fflush(stdout)
}

func fail(_ msg: String) -> Never {
    log("FATAL: \(msg)")
    exit(1)
}

// MARK: - output device

// Public CoreAudio API only (no MediaRemote-style private framework games
// here) — synchronous and cheap enough to call fresh on every start marker.
func defaultOutputDeviceName() -> String? {
    var addr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var dev = AudioObjectID(0)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr, dev != 0 else { return nil }
    var nameAddr = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertyName,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var cf: CFString? = nil
    var nameSize = UInt32(MemoryLayout<CFString?>.size)
    let st = withUnsafeMutablePointer(to: &cf) {
        AudioObjectGetPropertyData(dev, &nameAddr, 0, nil, &nameSize, $0)
    }
    return st == noErr ? (cf as String?) : nil
}

// MARK: - AppleScript media control

// Supported players. `tell application "X"` to a NON-RUNNING app LAUNCHES
// it, so every script below guards with `if application "X" is running`
// (that test does not launch) before ever sending a `tell`.
let players = ["Spotify", "Music"]

let osaQueue = DispatchQueue(label: "wispr-media-pause.osascript", attributes: .concurrent)

// Runs `osascript -e <source>` as a subprocess (not NSAppleScript, which has
// thread/blocking issues), enforcing a 5s timeout. Delivers trimmed stdout
// via completion, called on osaQueue — call sites hop back to stateQueue
// themselves, exactly like the old MediaRemote callback did.
func runOSAScript(_ source: String, completion: @escaping (String) -> Void) {
    osaQueue.async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

        let sema = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in sema.signal() }

        do {
            try process.run()
        } catch {
            log("WARNING: failed to launch osascript: \(error)")
            completion("")
            return
        }

        let waitResult = sema.wait(timeout: .now() + 5)
        if waitResult == .timedOut {
            log("WARNING: osascript timed out after 5s, killing")
            process.terminate()
            _ = sema.wait(timeout: .now() + 1)
            completion("")
            return
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        completion(output)
    }
}

// One osascript invocation that checks every player, guarded so a
// non-running app is never launched, and builds a "Name:state;" result
// string. Returns a [player: state] dictionary; a player missing from the
// output (osascript failure/timeout) is simply absent — treated as not
// playing by callers.
func queryPlayerStates(_ completion: @escaping ([String: String]) -> Void) {
    let body = players.map { app in
        """
        if application "\(app)" is running then
            tell application "\(app)"
                set s to player state as string
            end tell
        else
            set s to "not running"
        end if
        set r to r & "\(app):" & s & ";"
        """
    }.joined(separator: "\n")
    let source = "set r to \"\"\n" + body + "\nreturn r"
    runOSAScript(source) { output in
        var states: [String: String] = [:]
        for entry in output.split(separator: ";") {
            let parts = entry.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            states[String(parts[0])] = String(parts[1])
        }
        completion(states)
    }
}

// Replaces queryIsPlaying(_:) — returns the players currently reporting
// state "playing". Unknown/empty output = not playing.
func queryPlayingApps(_ completion: @escaping ([String]) -> Void) {
    queryPlayerStates { states in
        completion(players.filter { states[$0] == "playing" })
    }
}

func controlApps(_ verb: String, _ apps: [String]) {
    guard !apps.isEmpty else { return }
    let source = apps.map { app in
        """
        if application "\(app)" is running then
            tell application "\(app)" to \(verb)
        end if
        """
    }.joined(separator: "\n")
    runOSAScript(source) { _ in }
}

func pauseApps(_ apps: [String]) {
    controlApps("pause", apps)
}

func playApps(_ apps: [String]) {
    controlApps("play", apps)
}

// MARK: - state (all mutated on stateQueue)

let stateQueue = DispatchQueue(label: "wispr-media-pause.state")
var pausedApps: [String] = []
var pendingResume: DispatchWorkItem?
var failsafe: DispatchWorkItem?
// Bumped on every marker; lets an in-flight async osascript query (or an
// already-running pendingResume item) detect it's been superseded by a
// newer marker and bail instead of acting on stale state.
var gen = 0

func armFailsafe() {
    failsafe?.cancel()
    guard failsafeMin > 0 else { failsafe = nil; return }
    let item = DispatchWorkItem {
        if !pausedApps.isEmpty {
            let apps = pausedApps
            playApps(apps)
            pausedApps = []
            log("failsafe: forced resume of \(apps.joined(separator: ", ")) after \(failsafeMin)min — missed stop marker?")
        }
    }
    failsafe = item
    stateQueue.asyncAfter(deadline: .now() + .seconds(failsafeMin * 60), execute: item)
}

func handleStartMarker() {
    stateQueue.async {
        gen += 1
        let g = gen
        pendingResume?.cancel()
        pendingResume = nil
        if !pausedApps.isEmpty {
            log("start: duplicate marker, already paused by us")
            armFailsafe()
            return
        }
        if !skipOutputs.isEmpty, let name = defaultOutputDeviceName() {
            let lower = name.lowercased()
            if skipOutputs.contains(where: { lower.contains($0.lowercased()) }) {
                log("start: output '\(name)' matches skip-output, not pausing")
                return
            }
        }
        // Name lookup failing just falls through to normal pausing below —
        // fail toward the pre-existing behaviour rather than skip blind.
        queryPlayingApps { result in
            stateQueue.async {
                guard g == gen else {
                    log("start: superseded, not pausing")
                    return
                }
                if !result.isEmpty {
                    pauseApps(result)
                    pausedApps = result
                    log("start: paused \(result.joined(separator: ", "))")
                } else {
                    log("start: nothing playing")
                }
                armFailsafe()
            }
        }
    }
}

func handleStopMarker() {
    // No skip-output check here, deliberately: if music was paused on a
    // previous dictation and the user switched output (e.g. unplugged
    // headphones) mid-flow, this path must still resume whatever pausedApps
    // says we paused — skip-output only ever suppresses new pausing.
    stateQueue.async {
        gen += 1
        let g = gen
        failsafe?.cancel()
        failsafe = nil
        pendingResume?.cancel()
        guard !pausedApps.isEmpty else {
            log("stop: nothing to resume")
            return
        }
        let item = DispatchWorkItem {
            queryPlayingApps { result in
                stateQueue.async {
                    guard g == gen else {
                        log("stop: superseded, not resuming")
                        return
                    }
                    let toResume = pausedApps.filter { !result.contains($0) }
                    let alreadyResumed = pausedApps.filter { result.contains($0) }
                    for app in alreadyResumed {
                        log("stop: user already resumed \(app)")
                    }
                    if !toResume.isEmpty {
                        playApps(toResume)
                        log("stop: resumed \(toResume.joined(separator: ", "))")
                    }
                    pausedApps = []
                }
            }
        }
        pendingResume = item
        stateQueue.asyncAfter(deadline: .now() + .milliseconds(resumeDelayMs), execute: item)
    }
}

// MARK: - probe mode (permission troubleshooting)

// Under launchd the daemon binary triggers its own macOS Automation
// permission prompt per player app on first control attempt. --probe lets
// that be exercised synchronously from a terminal, one line per player.
if probeMode {
    let sema = DispatchSemaphore(value: 0)
    queryPlayerStates { states in
        for app in players {
            let state = states[app] ?? "not running"
            if state == "not running" {
                print("\(app): not running")
            } else {
                print("\(app): running, \(state)")
            }
        }
        sema.signal()
    }
    sema.wait()
    if let name = defaultOutputDeviceName() {
        print("default output: \(name)")
    } else {
        print("default output: (unknown)")
    }
    exit(0)
}

// MARK: - log tailing

let startMarker = "Acquired recording mutex for startRecording"
let stopMarker = "audioRecorder: Stopping audio capture"

func processLine(_ line: String) {
    if line.contains(startMarker) {
        handleStartMarker()
    } else if line.contains(stopMarker) {
        handleStopMarker()
    }
}

let pipe = Pipe()
var lineBuffer = Data()
let newline = Data([0x0A])

pipe.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty else { return }
    lineBuffer.append(data)
    while let r = lineBuffer.range(of: newline) {
        let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<r.lowerBound)
        lineBuffer.removeSubrange(lineBuffer.startIndex..<r.upperBound)
        if let line = String(data: lineData, encoding: .utf8) {
            processLine(line)
        }
    }
}

let tail = Process()
tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
tail.arguments = ["-F", "-n", "0", logPath]
tail.standardOutput = pipe
tail.standardError = FileHandle.nullDevice
tail.terminationHandler = { proc in
    log("tail exited (status \(proc.terminationStatus)) — exiting for launchd restart")
    exit(1)
}

do {
    try tail.run()
} catch {
    fail("failed to launch /usr/bin/tail: \(error)")
}

log("wispr-media-pause started — tailing \"\(logPath)\", resume-delay=\(resumeDelayMs)ms, failsafe=\(failsafeMin)min")

dispatchMain()
