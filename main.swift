// wispr-media-pause — pauses now-playing media when Wispr Flow starts
// dictating, resumes it when dictation stops. Built because Wispr Flow's own
// "Mute music while dictating" feature works by setting the system mute flag
// on the default output device — and many USB audio interfaces (e.g. the
// Arturia MiniFuse 1) expose no CoreAudio mute control at all, so the mute
// call silently fails and music plays straight through dictation. This
// pauses instead of muting, so it works on any output device.
//
// Trigger (default, `--trigger mic`): watches every CoreAudio device that has
// input streams and treats "some input device started running" as dictation
// start and "all input devices stopped" as dictation stop. Newer Wispr Flow
// builds (seen on 1.6.1034) no longer write the log markers the original
// trigger relied on. The old log-tailing trigger is still available with
// `--trigger log` (and `--log <path>`). Media control: AppleScript
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
// "mic" (default): microphone activity. "log": tail Wispr's main.log for
// its start/stop markers (only works on Wispr builds that still write them).
var triggerMode = "mic"
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
        case "--trigger":
            if let v = it.next() {
                guard v == "mic" || v == "log" else {
                    print("unknown --trigger '\(v)' (expected mic or log)")
                    exit(2)
                }
                triggerMode = v
            }
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

// MARK: - input devices (mic trigger)

func audioObjectIDs(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                          mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
}

func audioUInt32(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : nil
}

func audioObjectName(_ obj: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    var cf: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let st = withUnsafeMutablePointer(to: &cf) {
        AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0)
    }
    return st == noErr ? ((cf as String?) ?? "device \(obj)") : "device \(obj)"
}

struct InputDevice {
    let id: AudioObjectID
    let name: String
    let hasOutput: Bool
    let runningSomewhere: Bool
}

// Re-enumerated on every call (cheap — a handful of devices), so devices
// that appear/disappear (Bluetooth headsets connecting, USB mics plugged
// in) are picked up without any listener bookkeeping.
func inputDevices() -> [InputDevice] {
    audioObjectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap { dev in
        guard !audioObjectIDs(dev, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).isEmpty else { return nil }
        let hasOutput = !audioObjectIDs(dev, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput).isEmpty
        let running = (audioUInt32(dev, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0
        return InputDevice(id: dev, name: audioObjectName(dev), hasOutput: hasOutput, runningSomewhere: running)
    }
}

// kAudioDevicePropertyDeviceIsRunningSomewhere is device-wide: on a device
// with BOTH input and output streams (USB interfaces like the MiniFuse,
// virtual devices) it is also true when something merely PLAYS through it
// — which would make music itself look like dictation and loop
// pause/resume. For such devices we additionally require that some process
// is actually capturing input (per-process HAL objects, macOS 14.2+). nil =
// that API is unavailable, in which case combined devices are ignored.
func anyProcessRunningInput() -> Bool? {
    let procs = audioObjectIDs(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
    guard !procs.isEmpty else { return nil }
    return procs.contains { (audioUInt32($0, kAudioProcessPropertyIsRunningInput) ?? 0) != 0 }
}

// Names of input devices currently in use for capture (empty = mic off).
func activeInputDeviceNames() -> [String] {
    let devs = inputDevices().filter { $0.runningSomewhere }
    guard !devs.isEmpty else { return [] }
    // Only pay for the process scan when a combined in+out device is running.
    let processInput = devs.contains { $0.hasOutput } ? (anyProcessRunningInput() ?? false) : false
    return devs.filter { !$0.hasOutput || processInput }.map { $0.name }
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
    let active = Set(activeInputDeviceNames())
    let devs = inputDevices()
    if devs.isEmpty { print("input devices: (none found)") }
    for d in devs {
        let use = active.contains(d.name) ? "IN USE" : "idle"
        let note = d.hasOutput ? " (also has output; device running=\(d.runningSomewhere))" : ""
        print("input: \(d.name): \(use)\(note)")
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

let logPipe = Pipe()
var lineBuffer = Data()
let newline = Data([0x0A])

func startLogTrigger() {
    logPipe.fileHandleForReading.readabilityHandler = { handle in
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
    tail.standardOutput = logPipe
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
}

// MARK: - mic trigger

// Simple poll rather than AudioObject property listeners: one cheap HAL
// read per input device every 250ms, devices re-enumerated each tick, no
// listener lifetime/re-registration edge cases. Debounced: the mic must be
// on for >= micOnDebounceMs before it counts as "started" (ignores brief
// device probes), and off for >= micOffDebounceMs before "stopped" (ignores
// a recorder briefly restarting mid-dictation).
let micPollMs = 250
let micOnDebounceMs = 250
let micOffDebounceMs = 500
let micQueue = DispatchQueue(label: "wispr-media-pause.mic")
var micActive = false          // debounced state, micQueue only
var micRawSince = Date()       // when the raw reading last changed
var micRawLast = false

func micTick() {
    let names = activeInputDeviceNames()
    let raw = !names.isEmpty
    let now = Date()
    if raw != micRawLast {
        micRawLast = raw
        micRawSince = now
    }
    let heldMs = Int(now.timeIntervalSince(micRawSince) * 1000)
    if raw && !micActive && heldMs >= micOnDebounceMs {
        micActive = true
        log("mic on: \(names.joined(separator: ", "))")
        handleStartMarker()
    } else if !raw && micActive && heldMs >= micOffDebounceMs {
        micActive = false
        log("mic off")
        handleStopMarker()
    }
}

func startMicTrigger() {
    // Let the HAL deliver its internal notifications on its own thread —
    // this process has no CFRunLoop running (dispatchMain), and without this
    // the HAL can serve stale property values.
    var rl: CFRunLoop? = nil
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyRunLoop,
                                          mScope: kAudioObjectPropertyScopeGlobal,
                                          mElement: kAudioObjectPropertyElementMain)
    _ = withUnsafePointer(to: &rl) {
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                   UInt32(MemoryLayout<CFRunLoop?>.size), $0)
    }

    // Seed with the current state so a mic already in use at launch (e.g.
    // a call in progress) is not treated as a fresh dictation start.
    micQueue.sync {
        let names = activeInputDeviceNames()
        micActive = !names.isEmpty
        micRawLast = micActive
        micRawSince = Date()
    }
    let timer = DispatchSource.makeTimerSource(queue: micQueue)
    timer.schedule(deadline: .now() + .milliseconds(micPollMs), repeating: .milliseconds(micPollMs),
                   leeway: .milliseconds(50))
    timer.setEventHandler { micTick() }
    timer.resume()
    micTimer = timer
    let devs = inputDevices().map { $0.name }
    log("wispr-media-pause started — trigger=mic (inputs: \(devs.joined(separator: ", "))), mic currently \(micActive ? "on" : "off"), resume-delay=\(resumeDelayMs)ms, failsafe=\(failsafeMin)min")
}
var micTimer: DispatchSourceTimer?

if triggerMode == "log" {
    startLogTrigger()
} else {
    startMicTrigger()
}

dispatchMain()
