import AppKit
import Carbon

private let application = URL(fileURLWithPath: "__HOME__/Applications/Buscar dossier TSI.app", isDirectory: true)
private let hotkeySignature: OSType = 0x54534944 // TSID
private let hotkeyID = EventHotKeyID(signature: hotkeySignature, id: 8)
NSApplication.shared.setActivationPolicy(.prohibited)

private let handler: EventHandlerUPP = { _, event, _ in
    guard let event else { return noErr }
    var identifier = EventHotKeyID()
    let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
    guard result == noErr, identifier.signature == hotkeySignature, identifier.id == 8 else { return OSStatus(eventNotHandledErr) }
    let marker = URL(fileURLWithPath: "__HOME__/Library/Caches/ch.tsi.dossier-search.hotkey-last")
    try? ISO8601DateFormatter().string(from: Date()).write(to: marker, atomically: true, encoding: .utf8)
    DispatchQueue.main.async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: application, configuration: configuration) { _, error in
            if let error { NSLog("Buscar dossier TSI: %@", String(describing: error)) }
        }
    }
    return noErr
}

var handlerReference: EventHandlerRef?
let eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
let installResult = InstallEventHandler(GetApplicationEventTarget(), handler, 1, [eventType], nil, &handlerReference)
guard installResult == noErr else { fatalError("No se pudo registrar el controlador: \(installResult)") }

var hotkeyReference: EventHotKeyRef?
let registerResult = RegisterEventHotKey(UInt32(kVK_ANSI_8), UInt32(cmdKey | shiftKey), hotkeyID, GetApplicationEventTarget(), 0, &hotkeyReference)
guard registerResult == noErr else { fatalError("No se pudo registrar ⌘⇧8: \(registerResult)") }

NSApplication.shared.run()
