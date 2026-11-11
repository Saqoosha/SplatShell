import Carbon.HIToolbox
import Foundation

/// What the keys SuperSplat binds by physical position are labelled on the
/// user's current keyboard layout, keyed by DOM `KeyboardEvent.code`. On
/// Dvorak, "KeyW" is the key labelled ",".
enum KeyboardLayout {
    /// DOM code → macOS virtual key code for the keys the fly controls can use
    /// (both the QWERTY and the Dvorak keyboard sets).
    private static let keys: [String: Int] = [
        "KeyW": kVK_ANSI_W, "KeyA": kVK_ANSI_A, "KeyS": kVK_ANSI_S,
        "KeyD": kVK_ANSI_D, "KeyQ": kVK_ANSI_Q, "KeyE": kVK_ANSI_E,
        "KeyO": kVK_ANSI_O, "Comma": kVK_ANSI_Comma, "Period": kVK_ANSI_Period,
        "Quote": kVK_ANSI_Quote,
    ]

    static func currentLabels() -> [String: String] {
        // The ASCII-capable layout under any input method, so a Japanese or
        // Chinese input mode still reports its Roman layout (Dvorak, ABC...).
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data

        var labels: [String: String] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for (code, virtualKey) in keys {
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(virtualKey), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, chars.count, &length, &chars)
                if status == noErr, length > 0 {
                    labels[code] = String(utf16CodeUnits: chars, count: length)
                }
            }
        }
        return labels
    }

    /// Which keys fly the camera: "qwerty" (W A S D, Q E) or "dvorak", for a
    /// keyboard that is Dvorak in hardware and so sends the codes of the
    /// letters printed on it (the keys at the WASD positions send , A O E).
    /// Software cannot tell such a keyboard apart, so the user picks.
    static let flyKeysDefaultsKey = "flyKeyLayout"

    static var flyKeys: String {
        get { UserDefaults.standard.string(forKey: flyKeysDefaultsKey) == "dvorak" ? "dvorak" : "qwerty" }
        set { UserDefaults.standard.set(newValue, forKey: flyKeysDefaultsKey) }
    }

    static func flyKeysScript() -> String {
        "window.flyKeyLayout = '\(flyKeys)'; window.dispatchEvent(new Event('flykeylayoutchange'));"
    }

    /// The script that hands the labels to the page, and tells an already
    /// loaded page that they changed.
    static func script() -> String {
        let json = (try? JSONSerialization.data(withJSONObject: currentLabels(), options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "window.keyboardLayoutLabels = \(json); window.dispatchEvent(new Event('keyboardlayoutchange'));"
    }
}
