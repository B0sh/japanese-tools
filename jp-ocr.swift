#!/usr/bin/env swift
import AppKit
import ApplicationServices
import Darwin
import Vision

struct OCRFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func japaneseText(in url: URL) throws -> String {
    // Vision's newer API is asynchronous. Run it off the main thread so AppKit
    // can still build and run the preview on the script's original main thread.
    final class Reply: @unchecked Sendable {
        var result: Result<String, Error>?
    }
    let reply = Reply()
    let finished = DispatchSemaphore(value: 0)
    Task.detached {
        do {
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = [Locale.Language(identifier: "ja-JP"),
                                            Locale.Language(identifier: "en-US")]
            request.automaticallyDetectsLanguage = true
            request.usesLanguageCorrection = true
            let observations = try await request.perform(on: url)
            let text = observations.compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            reply.result = .success(text)
        } catch {
            reply.result = .failure(error)
        }
        finished.signal()
    }
    finished.wait()
    guard let result = reply.result else { throw OCRFailure("OCR did not return a result") }
    return try result.get()
}

func activate() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.activate(ignoringOtherApps: true)
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
    else { throw OCRFailure("Invalid AnkiConnect response for \(action)") }
    if let error = object["error"], !(error is NSNull) {
        throw OCRFailure("AnkiConnect \(action): \(error)")
    }
    guard let result = object["result"] else { throw OCRFailure("Missing AnkiConnect result") }
    return result
}
func closeAnkiBrowser() throws {
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == "net.ankiweb.anki" || $0.bundleIdentifier == "net.ankiweb.dtop" || $0.localizedName == "Anki"
    }) else { return }
    let application = AXUIElementCreateApplication(app.processIdentifier)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement] else {
        throw OCRFailure("Cannot inspect Anki windows. Allow this script's launcher in macOS Accessibility settings.")
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
    for window in windows where isBrowser(window)
        || (attribute(window, kAXTitleAttribute) as? String ?? "").hasPrefix("Browse")
        || (attribute(window, kAXTitleAttribute) as? String ?? "").hasPrefix("ブラウザー") {
        guard let closeValue = attribute(window, kAXCloseButtonAttribute),
              CFGetTypeID(closeValue) == AXUIElementGetTypeID() else {
            throw OCRFailure("Cannot find Anki Browse window close button")
        }
        let close = unsafeBitCast(closeValue, to: AXUIElement.self)
        guard AXUIElementPerformAction(close, kAXPressAction as CFString) == .success else {
            throw OCRFailure("Could not close Anki Browse window")
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            var current: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &current) == .success,
               let remaining = current as? [AXUIElement],
               !remaining.contains(where: { CFEqual($0, window) }) { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        var current: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &current) == .success,
              let remaining = current as? [AXUIElement],
              !remaining.contains(where: { CFEqual($0, window) }) else {
            throw OCRFailure("Anki Browse window did not close; text was not saved")
        }
    }
}
func copyToLatestCard(_ text: String) throws {
    guard let ids = try anki("findNotes", ["query": "added:1"]) as? [Int64], let id = ids.max() else {
        throw OCRFailure("No Anki notes added in the last day")
    }
    try closeAnkiBrowser()
    defer { _ = try? anki("guiBrowse", ["query": "nid:\(id)"]) }
    func sentence() throws -> String {
        guard let notes = try anki("notesInfo", ["notes": [id]]) as? [[String: Any]],
              let fields = notes.first?["fields"] as? [String: [String: Any]],
              let value = fields["Sentence"]?["value"] as? String else {
            throw OCRFailure("The latest note has no Sentence field")
        }
        return value
    }
    _ = try sentence()
    _ = try anki("updateNoteFields", ["note": ["id": id, "fields": ["Sentence": text]]])
    guard try sentence() == text else { throw OCRFailure("Anki Sentence field verification failed") }
}
func showPreviewError(_ error: Error) {
    activate()
    let alert = NSAlert()
    if (error as NSError).domain == NSURLErrorDomain {
        alert.messageText = "Anki isn’t available"
        alert.informativeText = "Open Anki and make sure AnkiConnect is enabled, then try again. Your text is still in the preview."
    } else {
        alert.messageText = "Couldn’t save to Anki"
        alert.informativeText = String(describing: error)
    }
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
}

final class OCRPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { NSApp.stopModal(withCode: .cancel) }
}
final class PreviewActions: NSObject {
    @objc func copyText(_ sender: Any?) { NSApp.stopModal(withCode: .OK) }
    @objc func copyToCard(_ sender: Any?) { NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: 1002)) }
    @objc func cancel(_ sender: Any?) { NSApp.stopModal(withCode: .cancel) }
}
func preview(image: NSImage, text: String) {
    activate()
    let actions = PreviewActions()
    let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1024, height: 768)
    let width = min(760.0, max(420.0, visible.width - 160))
    let imageHeight = min(300.0, max(80.0, visible.height * 0.35))
    let textHeight = min(190.0, max(100.0, visible.height * 0.23))
    let gap = 14.0
    let footer = 52.0
    let padding = 16.0
    let content = NSView(frame: NSRect(x: 0, y: 0, width: width + padding * 2,
                                     height: imageHeight + gap + textHeight + footer + padding))
    let panel = OCRPanel(contentRect: content.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.isMovableByWindowBackground = true
    panel.hasShadow = true
    panel.backgroundColor = .windowBackgroundColor
    content.wantsLayer = true
    content.layer?.cornerRadius = 12
    content.layer?.masksToBounds = true
    panel.contentView = content
    let imageView = NSImageView(frame: NSRect(x: padding, y: footer + textHeight + gap, width: width, height: imageHeight))
    imageView.image = image
    imageView.imageScaling = .scaleProportionallyUpOrDown
    content.addSubview(imageView)

    let scroll = NSScrollView(frame: NSRect(x: padding, y: footer, width: width, height: textHeight))
    scroll.borderType = .bezelBorder
    scroll.hasVerticalScroller = true
    let editor = NSTextView(frame: scroll.contentView.bounds)
    editor.isRichText = false
    editor.font = NSFont.systemFont(ofSize: 20)
    editor.string = text
    editor.isVerticallyResizable = true
    editor.isHorizontallyResizable = false
    editor.autoresizingMask = [.width]
    editor.textContainer?.widthTracksTextView = true
    editor.textContainerInset = NSSize(width: 10, height: 10)
    scroll.documentView = editor
    content.addSubview(scroll)
    let copy = NSButton(title: "Copy", target: actions, action: #selector(PreviewActions.copyText(_:)))
    copy.bezelStyle = .rounded
    copy.keyEquivalent = "\r"
    copy.frame = NSRect(x: padding + width - 90, y: 12, width: 90, height: 28)
    let cancel = NSButton(title: "Cancel", target: actions, action: #selector(PreviewActions.cancel(_:)))
    cancel.bezelStyle = .rounded
    cancel.keyEquivalent = "\u{1b}"
    cancel.frame = NSRect(x: padding + width - 190, y: 12, width: 90, height: 28)
    let card = NSButton(title: "Copy to Latest Card", target: actions, action: #selector(PreviewActions.copyToCard(_:)))
    card.bezelStyle = .rounded
    card.frame = NSRect(x: padding, y: 12, width: 190, height: 28)
    content.addSubview(card)
    content.addSubview(copy)
    content.addSubview(cancel)
    panel.defaultButtonCell = copy.cell as? NSButtonCell
    panel.initialFirstResponder = editor
    panel.center()
    while true {
        panel.makeKeyAndOrderFront(nil)
        let result = NSApp.runModal(for: panel)
        if result.rawValue == 1002 {
            card.isEnabled = false
            do {
                try copyToLatestCard(editor.string)
                panel.orderOut(nil)
                return
            } catch {
                showPreviewError(error)
                card.isEnabled = true
                continue
            }
        }
        panel.orderOut(nil)
        if result == .OK {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(editor.string, forType: .string)
        }
        return
    }
}

func main() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] {
        print("Usage: jp-ocr.swift [--image IMAGE | --ocr IMAGE]\nNo arguments: select a screen region, recognize Japanese, then preview and copy.\nEscape or Cancel leaves the clipboard unchanged.")
        return
    }
    if arguments.count == 2 && arguments[0] == "--ocr" {
        print(try japaneseText(in: URL(fileURLWithPath: arguments[1])))
        return
    }
    guard arguments.isEmpty || (arguments.count == 2 && arguments[0] == "--image") else {
        throw OCRFailure("Unknown arguments. Use --help.")
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jp-ocr-\(getuid())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                          attributes: [.posixPermissions: 0o700])
    let lock = open(directory.appendingPathComponent("lock").path, O_CREAT | O_RDWR, 0o600)
    guard lock >= 0 else { throw OCRFailure("Cannot open OCR lock") }
    defer { close(lock) }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        if errno == EWOULDBLOCK { return }
        throw OCRFailure("Cannot acquire OCR lock")
    }
    defer { flock(lock, LOCK_UN) }

    let capture = directory.appendingPathComponent(UUID().uuidString + ".png")
    defer { try? FileManager.default.removeItem(at: capture) }
    let source: URL
    if arguments.isEmpty {
        let picker = Process()
        picker.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        picker.arguments = ["-i", "-s", "-x", capture.path]
        try picker.run()
        picker.waitUntilExit()
        // Escape can return success on some macOS versions, so require an actual image too.
        guard picker.terminationStatus == 0,
              FileManager.default.fileExists(atPath: capture.path) else { return }
        source = capture
    } else {
        source = URL(fileURLWithPath: arguments[1])
    }
    guard let image = NSImage(contentsOf: source), image.size.width > 0, image.size.height > 0 else {
        throw OCRFailure("Could not read the screenshot")
    }
    let text = try japaneseText(in: source)
    preview(image: image, text: text)
}

do {
    try main()
} catch {
    fputs("Japanese OCR: \(error)\n", stderr)
    activate()
    let alert = NSAlert()
    alert.messageText = "Japanese OCR couldn’t finish"
    alert.informativeText = String(describing: error)
    alert.alertStyle = .warning
    alert.addButton(withTitle: "OK")
    alert.runModal()
    exit(1)
}
