#!/usr/bin/env swift
import AppKit
import ApplicationServices
import Darwin
import Foundation

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}
func json(_ value: Any) throws -> String {
    String(
        decoding: try JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self)
}
var interrupted: Int32 = 0
let fm = FileManager.default
let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(
    "Library/Application Support/AudioToAnki")
func log(_ text: String) {
    print(text)
    fflush(stdout)
}
func run(_ executable: String, _ arguments: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = arguments
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw Failure("Command failed: \(executable) (\(p.terminationStatus))")
    }
}
struct Snapshot: Decodable {
    struct Recording: Decodable {
        let path: String
        let duration: Double
    }
    let running: Bool
    let duration: Double
    let recordings: [Recording]
    let error: String?
}
final class Bridge {
    let folder: URL
    let session: String
    init(session: String) throws {
        self.session = session
        folder = root.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    deinit { try? fm.removeItem(at: folder) }
    func call(_ operation: String) throws -> Snapshot {
        let id = UUID().uuidString
        let reply = folder.appendingPathComponent(id + ".json")
        let command = folder.appendingPathComponent(id + ".ahcommand")
        let source = """
            var response;
            try {
              var s = app.sessionWithName(\(try json(session)));
              if (!s) throw new Error('Session not found');
              var recorders = s.blocks.filter(function(b) { return typeof b.fileTime === 'number'; });
              if (recorders.length !== 1) throw new Error('Expected exactly one recorder; found ' + recorders.length);
              if (\(try json(operation)) === 'start') {
                recorders[0].fileName = 'audiohijack-%date %time';
                s.start();
              }
              if (\(try json(operation)) === 'stop') s.stop();
              response = {running:s.running, duration:recorders[0].fileTime,
                recordings:s.recordings.map(function(f) { return {path:f.filePath, duration:f.fileTime}; }), error:null};
            } catch(e) { response = {running:false,duration:0,recordings:[],error:String(e)}; }
            app.runShellCommand('/usr/bin/printf %s ' + app.shellEscapeArgument(JSON.stringify(response)) + ' > ' + app.shellEscapeArgument(\(try json(reply.path + ".tmp"))) + ' && /bin/mv ' + app.shellEscapeArgument(\(try json(reply.path + ".tmp"))) + ' ' + app.shellEscapeArgument(\(try json(reply.path))));
            """
        try source.write(to: command, atomically: true, encoding: .utf8)
        try run("/usr/bin/open", ["-g", "-b", "com.rogueamoeba.audiohijack", command.path])
        let deadline = Date().addingTimeInterval(10)
        while !fm.fileExists(atPath: reply.path) {
            guard Date() < deadline else {
                throw Failure(
                    "Audio Hijack did not reply. Enable Allow execution of external scripts in its settings."
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: reply))
        try? fm.removeItem(at: reply)
        try? fm.removeItem(at: command)
        if let error = snapshot.error { throw Failure("Audio Hijack: \(error)") }
        return snapshot
    }
}
func anki(_ action: String, _ params: [String: Any] = [:]) throws -> Any {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:8765")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 10
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "action": action, "version": 6, "params": params,
    ])
    let semaphore = DispatchSemaphore(value: 0)
    // Completion finishes before the semaphore is signalled; this box is accessed sequentially.
    final class Reply: @unchecked Sendable {
        var data: Data?
        var error: Error?
        var status: Int?
    }
    let reply = Reply()
    URLSession.shared.dataTask(with: request) { data, response, error in
        reply.data = data
        reply.error = error
        reply.status = (response as? HTTPURLResponse)?.statusCode
        semaphore.signal()
    }.resume()
    semaphore.wait()
    if let error = reply.error { throw error }
    guard reply.status == 200, let data = reply.data,
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw Failure("Invalid AnkiConnect response for \(action)") }
    if let error = object["error"], !(error is NSNull) {
        throw Failure("AnkiConnect \(action): \(error)")
    }
    guard let result = object["result"] else { throw Failure("Missing AnkiConnect result") }
    return result
}
struct SilenceDetector {
    var previous = 0.0
    var lastProgress: TimeInterval
    var heardAudio = false
    mutating func update(duration: Double, now: TimeInterval, silence: Double) -> Bool {
        if duration > previous + 0.01 {
            lastProgress = now
            heardAudio = true
        }
        previous = duration
        return now - lastProgress >= (heardAudio ? silence : max(5, silence))
    }
}
struct TargetNote {
    let id: Int64
    let audio: String
}
func noteAudio(_ id: Int64) throws -> String {
    guard let notes = try anki("notesInfo", ["notes": [id]]) as? [[String: Any]],
        let fields = notes.first?["fields"] as? [String: [String: Any]],
        let audio = fields["SentenceAudio"]?["value"] as? String
    else { throw Failure("Target note is missing or has no SentenceAudio field") }
    return audio
}
func prepareTarget() throws -> TargetNote? {
    guard let ids = try anki("findNotes", ["query": "added:1"]) as? [Int64], let id = ids.max()
    else { throw Failure("No Anki notes added in the last day") }
    let target = TargetNote(id: id, audio: try noteAudio(id))
    if !target.audio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let alert = NSAlert()
        alert.messageText = "Overwrite existing audio?"
        alert.informativeText =
            "The latest Anki note already has SentenceAudio. Overwrite replaces it with the new recording."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Overwrite")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        app.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else {
            log("Cancelled; existing audio unchanged")
            return nil
        }
    }
    return target
}
func closeAnkiBrowser() throws {
    guard
        let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "net.ankiweb.anki" || $0.bundleIdentifier == "net.ankiweb.dtop"
                || $0.localizedName == "Anki"
        })
    else { return }
    let application = AXUIElementCreateApplication(app.processIdentifier)
    var value: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value)
            == .success,
        let windows = value as? [AXUIElement]
    else {
        throw Failure(
            "Cannot inspect Anki windows. Allow this script's launcher in macOS Accessibility settings."
        )
    }
    func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        AXUIElementCopyAttributeValue(element, key as CFString, &result)
        return result
    }
    func isBrowser(_ element: AXUIElement, depth: Int = 0) -> Bool {
        let identifier = attribute(element, kAXIdentifierAttribute) as? String ?? ""
        if identifier.contains("AnkiApp.Browser") { return true }
        guard depth < 3 else { return false }
        return (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).contains {
            isBrowser($0, depth: depth + 1)
        }
    }
    for window in windows
    where isBrowser(window)
        || (attribute(window, kAXTitleAttribute) as? String ?? "").hasPrefix("Browse")
        || (attribute(window, kAXTitleAttribute) as? String ?? "").hasPrefix("ブラウザー")
    {
        guard let closeValue = attribute(window, kAXCloseButtonAttribute),
            CFGetTypeID(closeValue) == AXUIElementGetTypeID()
        else {
            throw Failure("Cannot find Anki Browse window close button")
        }
        let close = unsafeBitCast(closeValue, to: AXUIElement.self)
        guard AXUIElementPerformAction(close, kAXPressAction as CFString) == .success else {
            throw Failure("Could not close Anki Browse window")
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            var current: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &current)
                == .success,
                let remaining = current as? [AXUIElement],
                !remaining.contains(where: { CFEqual($0, window) })
            {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        var current: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &current)
                == .success,
            let remaining = current as? [AXUIElement],
            !remaining.contains(where: { CFEqual($0, window) })
        else {
            throw Failure("Anki Browse window did not close; audio was not attached")
        }
    }
}
func attach(_ path: String, to target: TargetNote) throws {
    let id = target.id
    try closeAnkiBrowser()
    defer { _ = try? anki("guiBrowse", ["query": "nid:\(id)"]) }
    // Closing Browse saves pending edits; check the field again before updating it.
    guard try noteAudio(id) == target.audio else {
        throw Failure(
            "SentenceAudio changed since recording was approved; recording preserved at \(path)")
    }
    let url = URL(fileURLWithPath: path)
    let filename = url.lastPathComponent
    guard
        let stored = try anki(
            "storeMediaFile",
            ["filename": filename, "data": try Data(contentsOf: url).base64EncodedString()])
            as? String
    else { throw Failure("Could not store media") }
    _ = try anki(
        "updateNoteFields", ["note": ["id": id, "fields": ["SentenceAudio": "[sound:\(stored)]"]]])
    guard let notes = try anki("notesInfo", ["notes": [id]]) as? [[String: Any]],
        let fields = notes.first?["fields"] as? [String: [String: Any]],
        fields["SentenceAudio"]?["value"] as? String == "[sound:\(stored)]"
    else { throw Failure("Anki field verification failed; recording preserved at \(path)") }
    log("Attached \(stored) to note \(id)")
}
func main() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    let recordOnly = args.contains("--record-only")
    args.removeAll { $0 == "--record-only" }
    if args == ["--self-test"] {
        var d = SilenceDetector(lastProgress: 0)
        precondition(!d.update(duration: 0, now: 4, silence: 1))
        precondition(!d.update(duration: 1, now: 6, silence: 1))
        precondition(!d.update(duration: 1, now: 6.9, silence: 1))
        precondition(d.update(duration: 1, now: 7.1, silence: 1))
        precondition(!d.update(duration: 2, now: 8, silence: 1))
        var quiet = SilenceDetector(lastProgress: 0)
        precondition(quiet.update(duration: 0, now: 5.1, silence: 1))
        log("Silence detector tests passed")
        return
    }
    if args == ["--help"] {
        log(
            "Usage: audio-to-anki [--check | --status | --stop | --attach PATH]\nDefault: start recording; invoke again to stop and attach. Use --record-only to skip Anki. Silence stops automatically.\nEnvironment: ANKI_AUDIO_SESSION (Anki Audio), ANKI_AUDIO_SILENCE (1.0 seconds), ANKI_AUDIO_MAX_SECONDS (300)."
        )
        return
    }
    if args == ["--check"] {
        let bridge = try Bridge(
            session: ProcessInfo.processInfo.environment["ANKI_AUDIO_SESSION"] ?? "Anki Audio")
        let state = try bridge.call("status")
        log(
            "Audio Hijack bridge OK: running=\(state.running), duration=\(state.duration), recordings=\(state.recordings.count)"
        )
        _ = try anki("version")
        log("AnkiConnect OK")
        return
    }
    if args.count == 2 && args[0] == "--attach" {
        guard let target = try prepareTarget() else { return }
        try attach(args[1], to: target)
        return
    }
    guard args.isEmpty || args == ["--stop"] || args == ["--status"] else {
        throw Failure("Unknown arguments; use --help")
    }
    try fm.createDirectory(
        at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let fd = open(root.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw Failure("Cannot open recording lock") }
    defer { close(fd) }
    let stop = root.appendingPathComponent("stop")
    let phase = root.appendingPathComponent("phase")
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        guard errno == EWOULDBLOCK else { throw Failure("Cannot acquire recording lock") }
        if args == ["--status"] {
            log((try? String(contentsOf: phase, encoding: .utf8)) ?? "Starting")
            return
        }
        try Data().write(to: stop, options: .atomic)
        log("Stop requested (or already finalizing)")
        return
    }
    defer {
        flock(fd, LOCK_UN)
        try? fm.removeItem(at: phase)
        try? fm.removeItem(at: stop)
    }
    if args == ["--status"] {
        log("Idle")
        return
    }
    if args == ["--stop"] {
        log("Idle; nothing to stop")
        return
    }
    try? fm.removeItem(at: stop)
    try "Starting".write(to: phase, atomically: true, encoding: .utf8)
    let env = ProcessInfo.processInfo.environment
    guard let silence = Double(env["ANKI_AUDIO_SILENCE"] ?? "1.0"), silence >= 0.3,
        let maxSeconds = Double(env["ANKI_AUDIO_MAX_SECONDS"] ?? "300"), maxSeconds > silence
    else { throw Failure("Invalid silence or maximum duration") }
    let bridge = try Bridge(session: env["ANKI_AUDIO_SESSION"] ?? "Anki Audio")
    let initial = try bridge.call("status")
    guard !initial.running else {
        throw Failure(
            "Session is already running outside this program. Stop it before starting this controller."
        )
    }
    let target: TargetNote?
    if recordOnly {
        target = nil
    } else {
        guard let approved = try prepareTarget() else { return }
        target = approved
    }
    // A second invocation while the dialog was open cancels this start too.
    if fm.fileExists(atPath: stop.path) {
        log("Cancelled before recording")
        return
    }
    let baseline = Set(initial.recordings.map(\.path))
    signal(SIGINT) { _ in interrupted = 1 }
    signal(SIGTERM) { _ in interrupted = 1 }
    var needsStop = true
    defer { if needsStop { _ = try? bridge.call("stop") } }
    _ = try bridge.call("start")
    try "Recording".write(to: phase, atomically: true, encoding: .utf8)
    log("Recording; invoke again to stop. Silence timeout: \(silence)s")
    let started = ProcessInfo.processInfo.systemUptime
    var detector = SilenceDetector(lastProgress: started)
    while true {
        if interrupted != 0 || fm.fileExists(atPath: stop.path) {
            log("Manual stop")
            break
        }
        let state = try bridge.call("status")
        let now = ProcessInfo.processInfo.systemUptime
        if !state.running {
            log("Session stopped externally")
            break
        }
        if detector.update(duration: state.duration, now: now, silence: silence) {
            log("Silence detected")
            break
        }
        if now - started >= maxSeconds {
            log("Maximum duration reached")
            break
        }
        Thread.sleep(forTimeInterval: 0.2)
    }
    try "Finalizing".write(to: phase, atomically: true, encoding: .utf8)
    _ = try bridge.call("stop")
    needsStop = false
    // Wait for Audio Hijack to publish exactly one new session recording and finalize its file.
    let deadline = Date().addingTimeInterval(15)
    var lastPath = ""
    var lastSize: UInt64 = 0
    var stableSince = Date()
    while Date() < deadline {
        let state = try bridge.call("status")
        let fresh = state.recordings.filter { !baseline.contains($0.path) }
        if fresh.count > 1 {
            throw Failure(
                "Multiple new recordings; refusing to choose. Files preserved: \(fresh.map(\.path))"
            )
        }
        if let file = fresh.first, let attrs = try? fm.attributesOfItem(atPath: file.path),
            let size = attrs[.size] as? UInt64, size > 0
        {
            if file.path != lastPath || size != lastSize {
                lastPath = file.path
                lastSize = size
                stableSince = Date()
            } else if Date().timeIntervalSince(stableSince) >= 1 {
                log("Recording saved: \(file.path)")
                if recordOnly {
                    log("Record-only mode: Anki unchanged")
                    return
                }
                guard file.duration > 0.1 else {
                    throw Failure("Recording too short; preserved without attaching")
                }
                guard let target else { throw Failure("Missing target note") }
                try attach(file.path, to: target)
                return
            }
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    throw Failure(
        "No finalized recording appeared within 15 seconds. Check Audio Hijack's recordings; audio has not been deleted."
    )
}
func showAnkiUnavailable() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let alert = NSAlert()
    alert.messageText = "Anki isn’t available"
    alert.informativeText =
        "Open Anki and make sure AnkiConnect is enabled, then try again. Any recording already saved has been preserved."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    app.activate(ignoringOtherApps: true)
    alert.runModal()
}
do { try main() } catch {
    if (error as NSError).domain == NSURLErrorDomain {
        showAnkiUnavailable()
    }
    fputs("Audio to Anki: \(error)\n", stderr)
    exit(1)
}
