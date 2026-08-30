import Cocoa
import ApplicationServices
import Carbon

class ClipboardUtil {

    typealias PasteboardContents = ([NSPasteboard.PasteboardType: Any], [NSPasteboard.PasteboardType])

    /// Slow consumers (browsers, Electron apps) can service the synthesized
    /// Cmd+V long after the event is posted. Restoring the original clipboard
    /// earlier makes them paste the old contents instead of the transcription.
    static let clipboardRestoreDelay: TimeInterval = 1.5

    /// Copies text to clipboard without pasting or restoring
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
    }

    /// Replaces the current selection (or pastes at the caret) with `text`, then
    /// restores the original clipboard.
    ///
    /// The voice-edit path's paste. Named separately from `insertText` so that
    /// path is greppable, and so a later change to dictation insertion cannot
    /// silently change what a voice edit does to the document.
    @discardableResult
    static func pasteText(_ text: String, targetProcessIdentifier: pid_t? = nil) async -> Bool {
        guard let targetProcessIdentifier else { return false }
        guard let target = NSRunningApplication(processIdentifier: targetProcessIdentifier),
              target.activate()
        else { return false }

        try? await Task.sleep(nanoseconds: 150_000_000)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier
                == targetProcessIdentifier
        else { return false }
        insertText(text)
        return true
    }

    /// The current string on the general pasteboard, if any.
    static func currentString(from pasteboard: NSPasteboard = .general) -> String? {
        pasteboard.string(forType: .string)
    }

    /// Copies the current selection via a simulated ⌘C and returns the copied
    /// string, restoring the pasteboard afterwards.
    ///
    /// Returns `nil` when the pasteboard did not change, which is how "nothing
    /// was selected" is detected. The original clipboard is restored either
    /// way, so a probe copy cannot clobber what the user had.
    ///
    /// `copy` and `wait` are seams for tests: production posts the key event
    /// and waits up to 200 ms for the focused app to service it. A unit test
    /// must not post ⌘C into whatever happens to be frontmost.
    static func copySelectedText(
        pasteboard: NSPasteboard = .general,
        copy: () -> Void = { simulateCopy() },
        wait: TimeInterval = 0.2
    ) -> String? {
        let saved = saveCurrentPasteboardContents(from: pasteboard)
        let changeCount = pasteboard.changeCount
        copy()
        let deadline = Date().addingTimeInterval(wait)
        while Date() < deadline {
            if pasteboard.changeCount != changeCount { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard pasteboard.changeCount != changeCount else { return nil }
        let copied = pasteboard.string(forType: .string)
        restorePasteboardContents(saved, to: pasteboard)
        return SelectedTextExtractor.usable(copied)
    }

    /// Pastes text and keeps it in clipboard (does not restore original clipboard)
    static func insertTextAndKeepInClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
        simulatePaste()
    }

    /// Pastes text and restores original clipboard (legacy behavior)
    static func insertText(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Save current pasteboard contents
        let savedContents = saveCurrentPasteboardContents(from: pasteboard)

        // Set new text to pasteboard
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
        let changeCountAfterCopy = pasteboard.changeCount

        // Simulate Cmd+V using layout-aware keycode resolution
        simulatePaste()

        // Restore original contents only after the target app had a chance to
        // process the paste, and only if the pasteboard still holds our text:
        // a different changeCount means the user (or another app) took over
        // the clipboard and restoring would clobber their data.
        DispatchQueue.main.asyncAfter(deadline: .now() + clipboardRestoreDelay) {
            restoreIfUnchanged(savedContents, expectedChangeCount: changeCountAfterCopy, pasteboard: pasteboard)
        }
    }

    @discardableResult
    static func restoreIfUnchanged(_ contents: PasteboardContents,
                                   expectedChangeCount: Int,
                                   pasteboard: NSPasteboard = .general) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else { return false }
        restorePasteboardContents(contents, to: pasteboard)
        return true
    }
    
    private static func simulatePaste() {
        sendCmdV()
    }

    static func simulateCopy() {
        sendCmdC()
    }

    private static func sendCmdC() {
        sendCommandKey(character: "c", qwertyKeyCode: 8)
    }
    
    private static func sendCmdV() {
        sendCommandKey(character: "v", qwertyKeyCode: 9)
    }

    private static func sendCommandKey(character: Character, qwertyKeyCode: CGKeyCode) {
        let keyCode: CGKeyCode
        if isQwertyCommandLayout() {
            keyCode = qwertyKeyCode
        } else if let foundKeycode = findKeycodeForCharacter(character) {
            keyCode = foundKeycode
        } else {
            keyCode = qwertyKeyCode
        }

        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
    
    static func isQwertyCommandLayout() -> Bool {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
        else { return false }
        
        let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        
        // "Dvorak - QWERTY ⌘" uses QWERTY positions for Command shortcuts
        // Its ID contains "DVORAK-QWERTY" or similar patterns
        // Also standard QWERTY, ABC, US layouts use keycode 9 for V
        let qwertyCommandLayouts = [
            "DVORAK-QWERTY",  // Dvorak - QWERTY ⌘
            "US",             // US QWERTY
            "ABC",            // ABC
            "Australian",     // Australian
            "British",        // British
            "Canadian",       // Canadian
            "USInternational" // US International
        ]
        
        let upperID = sourceID.uppercased()
        return qwertyCommandLayouts.contains { upperID.contains($0.uppercased()) }
    }
    
    static func findKeycodeForCharacter(_ char: Character) -> CGKeyCode? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutDataPtr = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        
        let layoutData = unsafeBitCast(layoutDataPtr, to: CFData.self)
        let keyboardLayout = unsafeBitCast(
            CFDataGetBytePtr(layoutData),
            to: UnsafePointer<UCKeyboardLayout>.self
        )
        
        let targetLower = char.lowercased()
        
        // Iterate through common keycodes (0-50 covers all letter keys)
        for keycode: UInt16 in 0...50 {
            var deadKeyState: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length: Int = 0
            
            let status = UCKeyTranslate(
                keyboardLayout,
                keycode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                4,
                &length,
                &chars
            )
            
            if status == noErr && length > 0 {
                let resultChar = Character(UnicodeScalar(chars[0])!)
                if resultChar.lowercased() == targetLower {
                    return CGKeyCode(keycode)
                }
            }
        }
        return nil
    }
    
    static func saveCurrentPasteboardContents(from pasteboard: NSPasteboard = .general) -> PasteboardContents {
        let types = pasteboard.types ?? []
        
        var savedContents: [NSPasteboard.PasteboardType: Any] = [:]
        
        for type in types {
            if let data = pasteboard.data(forType: type) {
                savedContents[type] = data
            } else if let string = pasteboard.string(forType: type) {
                savedContents[type] = string
            } else if let urls = pasteboard.propertyList(forType: type) as? [String] {
                savedContents[type] = urls
            }
        }
        
        return (savedContents, types)
    }
    
    static func restorePasteboardContents(_ contents: PasteboardContents, to pasteboard: NSPasteboard = .general) {
        let (savedContents, types) = contents
        
        pasteboard.declareTypes(types, owner: nil)
        
        for (type, content) in savedContents {
            if let data = content as? Data {
                pasteboard.setData(data, forType: type)
            } else if let string = content as? String {
                pasteboard.setString(string, forType: type)
            } else if let urls = content as? [String] {
                pasteboard.setPropertyList(urls, forType: type)
            }
        }
    }
    
    @available(*, deprecated, renamed: "insertText")
    static func insertTextUsingPasteboard(_ text: String) {
        insertText(text)
    }
    
    // MARK: - Testing Helpers
    
    static func getCurrentInputSourceID() -> String? {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
        else { return nil }
        return Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
    }
    
    static func switchToInputSource(withID targetID: String) -> Bool {
        guard let sourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return false
        }
        
        for source in sourceList {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            
            if sourceID.contains(targetID) || targetID.contains(sourceID) || sourceID == targetID {
                let result = TISSelectInputSource(source)
                usleep(100000) // 100ms delay for layout switch
                return result == noErr
            }
        }
        return false
    }
    
    static func getAvailableInputSources() -> [String] {
        guard let sourceList = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        
        var result: [String] = []
        for source in sourceList {
            guard let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
                  let selectablePtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable)
            else { continue }
            
            let isSelectable = unsafeBitCast(selectablePtr, to: CFBoolean.self) == kCFBooleanTrue
            if isSelectable {
                let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
                result.append(sourceID)
            }
        }
        return result
    }
}
