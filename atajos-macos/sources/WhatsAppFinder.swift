import AppKit
import ApplicationServices
import Darwin

func trace(_ message: String) {
    guard let file = fopen("/tmp/whatsapp-finder-helper.log", "a") else { return }
    fputs("\(Date()) \(message)\n", file)
    fclose(file)
}

let paths = Array(CommandLine.arguments.dropFirst()).filter { FileManager.default.fileExists(atPath: $0) }
guard !paths.isEmpty else { exit(1) }

let lockFD = Darwin.open("/tmp/whatsapp-finder-helper.lock", O_CREAT | O_RDWR, 0o600)
guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
    trace("another share action is already active")
    exit(9)
}

let trust = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
trace("start paths=\(paths.count) trusted=\(trust)")
guard trust else { exit(2) }

func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value as AnyObject?
}

func string(_ element: AXUIElement, _ name: String) -> String {
    attribute(element, name) as? String ?? ""
}

func find(_ element: AXUIElement, where predicate: (AXUIElement) -> Bool, depth: Int = 0) -> AXUIElement? {
    if predicate(element) { return element }
    if depth > 16 { return nil }
    for key in [kAXChildrenAttribute, kAXVisibleChildrenAttribute] {
        if let children = attribute(element, key) as? [AXUIElement] {
            for child in children {
                if let match = find(child, where: predicate, depth: depth + 1) { return match }
            }
        }
    }
    return nil
}

func key(_ code: CGKeyCode, flags: CGEventFlags = [], pid: pid_t? = nil) {
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        if let event = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down) {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: 0x574146)
            if let pid { event.postToPid(pid) }
            else { event.post(tap: .cghidEventTap) }
        }
    }
}

func waitFor(_ pid: pid_t, _ seconds: Double = 5, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
    let end = Date().addingTimeInterval(seconds)
    repeat {
        if let item = find(AXUIElementCreateApplication(pid), where: predicate) { return item }
        Thread.sleep(forTimeInterval: 0.1)
    } while Date() < end
    return nil
}

func press(_ element: AXUIElement) -> Bool {
    AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
}

let board = NSPasteboard.general
func prepareClipboard() -> Bool {
    board.clearContents()
    return board.writeObjects(paths.map { URL(fileURLWithPath: $0) as NSURL })
}
if paths.count > 1 {
    guard prepareClipboard() else { exit(3) }
    trace("clipboard ready for multiple files")
}

if NSRunningApplication.runningApplications(withBundleIdentifier: "net.whatsapp.WhatsApp").isEmpty {
    NSWorkspace.shared.launchApplication("WhatsApp")
}
var whatsappCandidate: NSRunningApplication?
for _ in 0..<50 {
    whatsappCandidate = NSRunningApplication.runningApplications(withBundleIdentifier: "net.whatsapp.WhatsApp").first
    if whatsappCandidate != nil { break }
    Thread.sleep(forTimeInterval: 0.1)
}
guard let whatsapp = whatsappCandidate else { exit(4) }
trace("whatsapp pid=\(whatsapp.processIdentifier)")
whatsapp.activate(options: [.activateIgnoringOtherApps])
let root = AXUIElementCreateApplication(whatsapp.processIdentifier)

// The chat picker opens through WhatsApp's own New Chat control.
if let search = find(root, where: { string($0, kAXIdentifierAttribute) == "PickerView_SearchBar" }) {
    AXUIElementSetAttributeValue(search, kAXFocusedAttribute as CFString, kCFBooleanTrue)
} else if let newChat = find(root, where: { string($0, kAXIdentifierAttribute) == "NavigationBar_NewChatButton" }) {
    AXUIElementPerformAction(newChat, kAXPressAction as CFString)
} else {
    key(45, flags: .maskCommand) // Command-N
}

for _ in 0..<30 {
    if let search = find(root, where: { string($0, kAXIdentifierAttribute) == "PickerView_SearchBar" }) {
        AXUIElementSetAttributeValue(search, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        break
    }
    Thread.sleep(forTimeInterval: 0.1)
}

func normalized(_ value: String) -> String {
    String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }).lowercased()
}

func attachSingleFile(_ path: String, to pid: pid_t) -> Bool {
    guard let attach = waitFor(pid, where: { string($0, kAXIdentifierAttribute) == "ChatBar_AttachMediaButton" }), press(attach) else {
        trace("attach button unavailable")
        return false
    }
    guard let document = waitFor(pid, where: { string($0, kAXIdentifierAttribute) == "WAActionSheetController_Document" }), press(document) else {
        trace("file menu unavailable")
        return false
    }
    guard waitFor(pid, where: { string($0, kAXIdentifierAttribute) == "open-panel" }) != nil else {
        trace("file dialog unavailable")
        return false
    }
    key(5, flags: [.maskCommand, .maskShift]) // Go to folder in the frontmost file dialog
    guard let field = waitFor(pid, where: { string($0, kAXIdentifierAttribute) == "PathTextField" }) else {
        trace("go-to-file field unavailable")
        return false
    }
    guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, path as CFString) == .success else {
        trace("could not enter file path")
        return false
    }
    key(36) // Choose the exact file in the frontmost file dialog.
    let filename = URL(fileURLWithPath: path).lastPathComponent
    guard waitFor(pid, where: {
        string($0, kAXRoleAttribute) == (kAXTextFieldRole as String) &&
        string($0, kAXValueAttribute) == filename &&
        attribute($0, kAXURLAttribute) != nil
    }) != nil else {
        trace("target file not selected in dialog")
        return false
    }
    guard let openButton = waitFor(pid, where: { string($0, kAXIdentifierAttribute) == "OKButton" }), press(openButton) else {
        trace("could not open selected file")
        return false
    }
    let ready = waitFor(pid, 8, where: { string($0, kAXIdentifierAttribute) == "WAMultiSendBottomBarView_SendButton" }) != nil
    trace(ready ? "attachment preview ready" : "attachment preview missing")
    return ready
}

var expectedContact = ""
var sawSearch = false
func watchChat(_ attempts: Int) {
    guard attempts > 0 else { trace("no matching chat opened"); exit(7) }
    let app = AXUIElementCreateApplication(whatsapp.processIdentifier)
    if let search = find(app, where: { string($0, kAXIdentifierAttribute) == "PickerView_SearchBar" }) {
        sawSearch = true
        if !string(search, kAXValueAttribute).isEmpty,
           let results = find(app, where: { string($0, kAXDescriptionAttribute) == "Résultats de la recherche" }),
           let first = find(results, where: { string($0, kAXIdentifierAttribute) == "PickerView_ContactCell" }) {
            expectedContact = string(first, kAXDescriptionAttribute).components(separatedBy: ",").first ?? ""
        }
    } else if sawSearch, !expectedContact.isEmpty,
              let composer = find(app, where: { string($0, kAXIdentifierAttribute) == "ChatBar_ComposerTextView" }),
              let header = find(app, where: { string($0, kAXIdentifierAttribute) == "NavigationBar_HeaderViewButton" }),
              normalized(string(header, kAXDescriptionAttribute)).contains(normalized(expectedContact)) {
        if paths.count == 1 {
            trace("opening selected file in matching chat")
            exit(attachSingleFile(paths[0], to: whatsapp.processIdentifier) ? 0 : 8)
        }
        AXUIElementSetAttributeValue(composer, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard prepareClipboard() else { trace("clipboard failed"); exit(3) }
        key(9, flags: .maskCommand, pid: whatsapp.processIdentifier)
        trace("pasted multiple files into matching chat")
        let ready = waitFor(whatsapp.processIdentifier, 8, where: {
            string($0, kAXIdentifierAttribute) == "WAMultiSendBottomBarView_SendButton"
        }) != nil
        trace(ready ? "attachment preview ready" : "attachment preview missing")
        exit(ready ? 0 : 8)
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { watchChat(attempts - 1) }
}
DispatchQueue.main.async { watchChat(1200) }
RunLoop.main.run()
