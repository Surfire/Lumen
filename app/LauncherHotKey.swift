import AppKit
import Carbon

struct HotKey: Codable, Equatable {
    static let mask = UInt32(cmdKey | optionKey | controlKey | shiftKey)
    static let standard = HotKey(code: UInt32(kVK_Space), modifiers: UInt32(optionKey), key: "␣")
    private static let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                                 kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]

    let code: UInt32
    let modifiers: UInt32
    let key: String

    init(code: UInt32, modifiers: UInt32, key: String) {
        self.code = code
        self.modifiers = modifiers
        self.key = key
    }

    init(event: NSEvent) throws {
        let flags = event.modifierFlags
        if flags.contains(.function) { throw HotKeyIssue.invalid }
        var modifiers = 0
        if flags.contains(.command) { modifiers |= cmdKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        let code = UInt32(event.keyCode)
        let key: String
        if code == kVK_Space { key = "␣" }
        else if let digit = Self.digits.firstIndex(of: Int(code)) { key = String(digit) }
        else { key = (event.charactersIgnoringModifiers ?? "").uppercased() }
        self.init(code: code, modifiers: UInt32(modifiers), key: key)
    }

    var label: String {
        var prefix = ""
        if modifiers & UInt32(controlKey) != 0 { prefix += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { prefix += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { prefix += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { prefix += "⌘" }
        return prefix + key
    }

    var cyclesMacWindows: Bool { modifiers == UInt32(cmdKey) && (code == kVK_ANSI_Grave || key == "`") }

    func checkSystemShortcut() throws {
        if modifiers == UInt32(cmdKey), code == kVK_ANSI_Comma || key == "," { throw HotKeyIssue.app }
        let permittedKeys = CharacterSet.alphanumerics.union(.punctuationCharacters).union(.symbols)
        guard modifiers & ~Self.mask == 0,
              modifiers & UInt32(cmdKey | controlKey | optionKey) != 0,
              key == "␣" || (key.count == 1 && key.unicodeScalars.allSatisfy(permittedKeys.contains))
        else { throw HotKeyIssue.invalid }
        // This is an explicit choice, never a default. Let Carbon return the real registration result.
        if cyclesMacWindows { return }
        let keys = try symbolicHotKeys()
        if keys.contains(where: { entry in
            guard (entry["kHISymbolicHotKeyEnabled"] as? NSNumber)?.boolValue == true else { return false }
            let code = (entry["kHISymbolicHotKeyCode"] as? NSNumber)?.uint32Value
            let modifiers = (entry["kHISymbolicHotKeyModifiers"] as? NSNumber)?.uint32Value
            return code == self.code && modifiers.map { $0 & Self.mask } == self.modifiers
        }) { throw HotKeyIssue.system }
    }

    private func symbolicHotKeys() throws -> [[String: Any]] {
        var keys: Unmanaged<CFArray>?
        let status = CopySymbolicHotKeys(&keys)
        guard status == noErr, let keys else { throw HotKeyIssue.registration(status) }
        guard let entries = keys.takeRetainedValue() as? [[String: Any]] else {
            throw HotKeyIssue.registration(OSStatus(paramErr))
        }
        return entries
    }
}

enum HotKeyIssue: Error {
    case invalid, system, app, occupied, registration(OSStatus)
}

@MainActor
final class GlobalHotKey {
    private let action: () -> Void
    private var handler: EventHandlerRef?
    private var registration: EventHotKeyRef?
    private var serial: UInt32 = 0
    private(set) var shortcut: HotKey?
    private static let signature: OSType = 0x4c756d6e // Lumn
    var identifier: EventHotKeyID? {
        shortcut.map { _ in EventHotKeyID(signature: Self.signature, id: serial) }
    }

    init(action: @escaping () -> Void) { self.action = action }

    func set(_ shortcut: HotKey) throws {
        try shortcut.checkSystemShortcut()
        if self.shortcut?.code == shortcut.code, self.shortcut?.modifiers == shortcut.modifiers {
            self.shortcut = shortcut
            return
        }
        if handler == nil { try installHandler() }

        // Keep the working binding until the OS accepts its replacement.
        let next = serial &+ 1
        var candidate: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: Self.signature, id: next)
        let status = RegisterEventHotKey(shortcut.code, shortcut.modifiers, identifier,
                                         GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &candidate)
        if status == eventHotKeyExistsErr { throw HotKeyIssue.occupied }
        guard status == noErr, let candidate else { throw HotKeyIssue.registration(status) }
        disable()
        registration = candidate
        serial = next
        self.shortcut = shortcut
    }

    func disable() {
        if let registration { UnregisterEventHotKey(registration) }
        registration = nil
        shortcut = nil
    }

    func close() {
        disable()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func installHandler() throws {
        let types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated { owner.receive(event) }
        }, types.count, types, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { throw HotKeyIssue.registration(status) }
    }

    private func receive(_ event: EventRef) -> OSStatus {
        var incoming = EventHotKeyID()
        let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                       EventParamType(typeEventHotKeyID), nil,
                                       MemoryLayout<EventHotKeyID>.size, nil, &incoming)
        guard status == noErr, let identifier, incoming.signature == identifier.signature,
              incoming.id == identifier.id
        else { return OSStatus(eventNotHandledErr) }

        action()
        return noErr
    }
}

@MainActor
final class HotKeyRecorder: NSButton {
    var record: ((NSEvent) -> Void)?
    var stopRecording: (() -> Void)?
    var recording = false
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if !recording { super.keyDown(with: event); return }
        if event.keyCode == kVK_Escape { stopRecording?() }
        else if !event.isARepeat { record?(event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording, window?.firstResponder === self, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        stopRecording?()
        return super.resignFirstResponder()
    }
}
