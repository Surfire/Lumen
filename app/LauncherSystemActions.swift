import AppKit
import CoreAudio
import CoreServices
import IOKit.pwr_mgt

@MainActor
enum LauncherSystemActions {
    enum Operation: Equatable {
        case lock, sleep, emptyTrash, darkMode, mute, unmute, eject, define(String)
    }

    static func perform(_ operation: Operation, chinese: Bool, completion: @escaping (Bool) -> Void) {
        func t(_ zh: String, _ en: String) -> String { chinese ? zh : en }
        switch operation {
        case .lock:
            // The system's lock-screen shortcut, delivered by macOS (requires Accessibility approval).
            script("tell application \"System Events\" to keystroke \"q\" using {control down, command down}", completion: completion)
        case .sleep:
            let connection = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
            guard connection != 0 else { completion(false); return }
            defer { IOServiceClose(connection) }
            completion(IOPMSleepSystem(connection) == kIOReturnSuccess)
        case .emptyTrash:
            let confirm = NSAlert()
            confirm.alertStyle = .warning
            confirm.messageText = t("永久清倒废纸篓？", "Permanently empty the Trash?")
            confirm.informativeText = t("此操作无法撤销。", "This cannot be undone.")
            confirm.addButton(withTitle: t("取消", "Cancel"))
            confirm.addButton(withTitle: t("清倒废纸篓", "Empty Trash"))
            NSApp.activate()
            guard confirm.runModal() == .alertSecondButtonReturn else { completion(false); return }
            script("tell application id \"com.apple.finder\" to empty trash", completion: completion)
        case .darkMode:
            script("""
                tell application "System Events" to tell appearance preferences
                    set dark mode to not dark mode
                end tell
                """, completion: completion)
        case .mute, .unmute:
            completion(setMuted(operation == .mute))
        case .eject:
            let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsInternalKey, .volumeIsBrowsableKey, .volumeLocalizedNameKey]
            let volumes = (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? [])
                .compactMap { url -> (URL, String)? in
                    guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsInternal == false,
                          values.volumeIsLocal == true, values.volumeIsBrowsable == true else { return nil }
                    return (url, values.volumeLocalizedName ?? url.lastPathComponent)
                }
            guard !volumes.isEmpty else { completion(false); return }
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 28), pullsDown: false)
            picker.addItems(withTitles: volumes.map { "\($0.1) — \($0.0.path)" })
            let alert = NSAlert()
            alert.messageText = t("选择要推出的外置卷", "Choose an external volume to eject")
            alert.accessoryView = picker
            alert.addButton(withTitle: t("推出", "Eject"))
            alert.addButton(withTitle: t("取消", "Cancel"))
            NSApp.activate()
            guard alert.runModal() == .alertFirstButtonReturn, volumes.indices.contains(picker.indexOfSelectedItem) else {
                completion(false); return
            }
            let url = volumes[picker.indexOfSelectedItem].0
            DispatchQueue.global(qos: .userInitiated).async {
                let ejected = (try? NSWorkspace.shared.unmountAndEjectDevice(at: url)) != nil
                DispatchQueue.main.async { completion(ejected) }
            }
        case .define(let word):
            DispatchQueue.global(qos: .userInitiated).async {
                let definition = dictionaryDefinition(word)
                DispatchQueue.main.async {
                    let alert = definitionAlert(word: word, definition: definition, chinese: chinese)
                    NSApp.activate()
                    alert.runModal()
                    completion(true)
                }
            }
        }
    }

    nonisolated static func dictionaryDefinition(_ word: String) -> String? {
        DCSCopyTextDefinition(nil, word as CFString, CFRange(location: 0, length: word.utf16.count))?
            .takeRetainedValue() as String?
    }

    static func definitionAlert(word: String, definition: String?, chinese: Bool) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = word
        if let definition {
            let scroll = NSTextView.scrollableTextView()
            scroll.frame.size = NSSize(width: 400, height: 160)
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            if let text = scroll.documentView as? NSTextView {
                text.string = definition
                text.font = .systemFont(ofSize: NSFont.systemFontSize)
                text.textContainerInset = NSSize(width: 6, height: 6)
                text.isEditable = false
                text.isSelectable = true
            }
            alert.accessoryView = scroll
        } else {
            alert.informativeText = chinese ? "系统词典中没有找到释义。" : "No definition was found in the system dictionaries."
        }
        alert.addButton(withTitle: chinese ? "完成" : "Done")
        return alert
    }

    private static func script(_ source: String, completion: @escaping (Bool) -> Void) {
        // Fixed local Apple events only: no shell, no user input interpolated into scripts.
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            script.executeAndReturnError(&error)
            let succeeded = error == nil
            DispatchQueue.main.async { completion(succeeded) }
        }
    }

    private static func setMuted(_ muted: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        address.mSelector = kAudioDevicePropertyMute
        address.mScope = kAudioDevicePropertyScopeOutput
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }
}
