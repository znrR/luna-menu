import AppKit
import ApplicationServices
import Darwin

// MARK: - Log

func log(_ s: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "LunaMenu").log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

@discardableResult
func run(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

struct AX {
    static func attr<T>(_ e: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
        return v as? T
    }
    static func children(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) ?? [] }
    static func role(_ e: AXUIElement) -> String { attr(e, kAXRoleAttribute) ?? "" }
    static func title(_ e: AXUIElement) -> String {
        (attr(e, kAXTitleAttribute) as String?) ?? (attr(e, kAXDescriptionAttribute) as String?) ?? ""
    }
    static func frame(_ e: AXUIElement) -> CGRect {
        var p = CGPoint.zero, s = CGSize.zero
        if let v: AXValue = attr(e, kAXPositionAttribute) { AXValueGetValue(v, .cgPoint, &p) }
        if let v: AXValue = attr(e, kAXSizeAttribute) { AXValueGetValue(v, .cgSize, &s) }
        return CGRect(origin: p, size: s)
    }
    static func all(_ root: AXUIElement, depth: Int = 0, where pred: (AXUIElement) -> Bool) -> [AXUIElement] {
        guard depth < 25 else { return [] }
        var out: [AXUIElement] = []
        for c in children(root) {
            if pred(c) { out.append(c) }
            out += all(c, depth: depth + 1, where: pred)
        }
        return out
    }
    static func press(_ e: AXUIElement) { AXUIElementPerformAction(e, kAXPressAction as CFString) }
}

// MARK: - Sleep notifier protocol (Primary → Secondary)
// UDP broadcast on port 44600, text: "LUNAMENU1 <event> <state> <hostname>"
// state: awake | screenoff | sleep   event: alive | sleep | wake | screensleep | screenwake

let melderPort: UInt16 = 44600
let melderMagic = "LUNAMENU1"

/// Trigger a menu item in another app's menu bar via Accessibility (matched by title prefix).
func axPressMenuItem(pid: pid_t, prefixes: [String]) -> Bool {
    let appEl = AXUIElementCreateApplication(pid)
    guard let bar: AXUIElement = AX.attr(appEl, kAXMenuBarAttribute) else { return false }
    let items = AX.all(bar) { e in
        AX.role(e) == kAXMenuItemRole as String && prefixes.contains(where: { AX.title(e).hasPrefix($0) })
    }
    guard let item = items.first else { return false }
    AX.press(item)
    return true
}

// MARK: - Backward compatibility (iMac late 2012 / macOS 10.15)

import ServiceManagement

/// Set the status bar icon: SF Symbol on macOS 11+, short text otherwise.
func setStatusSymbol(_ button: NSStatusBarButton?, _ name: String, fallback: String) {
    guard let button else { return }
    if #available(macOS 11.0, *),
       let img = NSImage(systemSymbolName: name, accessibilityDescription: "Luna")
        ?? NSImage(systemSymbolName: "display", accessibilityDescription: "Luna") {
        img.isTemplate = true
        button.image = img
        button.title = ""
    } else {
        button.image = nil
        button.title = fallback
    }
}

/// Open at login: SMAppService on macOS 13+, otherwise a LaunchAgent in ~/Library/LaunchAgents.
enum LoginItem {
    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(Bundle.main.bundleIdentifier ?? "de.r4sp.luna").plist")
    }
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }
    static func toggle() throws {
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            return
        }
        if isEnabled { try FileManager.default.removeItem(at: agentURL); return }
        let plist: [String: Any] = [
            "Label": Bundle.main.bundleIdentifier ?? "de.r4sp.luna",
            "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
            "RunAtLoad": true,
        ]
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: agentURL)
    }
}
