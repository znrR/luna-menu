import AppKit
import ApplicationServices
import ServiceManagement
import Darwin

// Luna Primary: menu bar wrapper for Luna Display on the primary Mac + sleep notifier for the secondary.

let displayBundleID = "com.astro-hq.LunaDisplayMac"
let displayAppURL = URL(fileURLWithPath: "/Applications/Luna Display.app")

/// Sends a notifier line via UDP broadcast (all IPv4 interfaces) and optionally directly to one IP.
func sendMelder(_ text: String, extraTarget: String?) {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return }
    defer { close(fd) }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
    var targets: Set<String> = ["255.255.255.255"]
    if let t = extraTarget, !t.isEmpty { targets.insert(t) }
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    if getifaddrs(&ifaddr) == 0, let first = ifaddr {
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = p.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  (ifa.ifa_flags & UInt32(IFF_BROADCAST)) != 0, let b = ifa.ifa_dstaddr else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(b, socklen_t(b.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            targets.insert(String(cString: host))
        }
        freeifaddrs(ifaddr)
    }
    let bytes = Array(text.utf8)
    for t in targets {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = melderPort.bigEndian
        guard inet_pton(AF_INET, t, &addr.sin_addr) == 1 else { continue }
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

@main
@MainActor
final class PrimaryDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let d = PrimaryDelegate()
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let defaults = UserDefaults.standard
    var state = "awake"           // awake | screenoff | sleep
    var lastSent = Date.distantPast
    let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

    var melderOn: Bool {
        get { defaults.object(forKey: "melderOn") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "melderOn") }
    }
    var secondaryIP: String {
        get { defaults.string(forKey: "secondaryIP") ?? "" }
        set { defaults.set(newValue, forKey: "secondaryIP") }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateIcon()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.event("sleep", state: "sleep", burst: 1) }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.event("wake", state: "awake", burst: 8) }
        }
        nc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.event("screensleep", state: "screenoff", burst: 3) }
        }
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // After system sleep, screensDidWake may arrive before didWake → also "awake".
                self.event("screenwake", state: "awake", burst: 5)
            }
        }
        // Heartbeat
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.send("alive") }
        }
        send("alive")
        log("started (\(hostName))")
    }

    func event(_ ev: String, state s: String, burst: Int) {
        state = s
        log("event \(ev) → \(s)")
        send(ev)
        // Right after wake the network is often not up yet → send several times.
        if burst > 1 {
            for i in 1..<burst {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 2) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.state == s else { return }
                        self.send(ev)
                    }
                }
            }
        }
        updateIcon()
    }

    func send(_ ev: String) {
        guard melderOn else { return }
        // No heartbeats while asleep (in case the timer fires during a dark wake).
        if ev == "alive", state == "sleep" { return }
        sendMelder("\(melderMagic) \(ev) \(state) \(hostName)", extraTarget: secondaryIP)
        lastSent = Date()
    }

    func updateIcon() {
        let name = melderOn ? "display.2" : "display"
        setStatusSymbol(item.button, name, fallback: "▣")
    }

    // MARK: Menu

    func displayApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: displayBundleID).first
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let running = displayApp() != nil
        let st = NSMenuItem(title: running ? "Luna Display is running" : "Luna Display is not running", action: nil, keyEquivalent: "")
        st.isEnabled = false
        menu.addItem(st)
        let ms = NSMenuItem(title: melderOn ? "Notifying \(secondaryIP.isEmpty ? "" : secondaryIP + " + ")broadcast, last \(Int(Date().timeIntervalSince(lastSent))) s ago" : "Notifier off",
                            action: nil, keyEquivalent: "")
        ms.isEnabled = false
        menu.addItem(ms)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Luna Display", action: #selector(openDisplay), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Manual Connect (show IP)", action: #selector(manualConnect), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings …", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        let mo = NSMenuItem(title: "Report Sleep & Wake to Secondary", action: #selector(toggleMelder), keyEquivalent: "")
        mo.state = melderOn ? .on : .off
        menu.addItem(mo)
        menu.addItem(NSMenuItem(title: "Secondary IP: \(secondaryIP.isEmpty ? "broadcast only" : secondaryIP) …", action: #selector(setIP), keyEquivalent: ""))
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Luna Primary", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for i in menu.items where i.action != nil && i.action != #selector(NSApplication.terminate(_:)) { i.target = self }
    }

    func alert(_ text: String) {
        let a = NSAlert()
        a.messageText = "Luna Primary"
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    func launchDisplay() async -> pid_t? {
        if let a = displayApp() { a.activate(); return a.processIdentifier }
        let cfg = NSWorkspace.OpenConfiguration()
        guard let a = try? await NSWorkspace.shared.openApplication(at: displayAppURL, configuration: cfg) else {
            alert("Luna Display could not be launched."); return nil
        }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        return a.processIdentifier
    }

    func pressInDisplay(_ prefixes: [String], what: String) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            alert("Luna Primary needs permission under System Settings › Privacy & Security › Accessibility.")
            return
        }
        Task {
            guard let pid = await launchDisplay() else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !axPressMenuItem(pid: pid, prefixes: prefixes) { alert("Menu item “\(what)” not found in Luna Display.") }
        }
    }

    @objc func openDisplay() { Task { _ = await launchDisplay() } }
    @objc func manualConnect() { pressInDisplay(["Manual Connect"], what: "Manual Connect") }
    @objc func openSettings() { pressInDisplay(["Preferences", "Settings", "Einstellungen"], what: "Preferences") }

    @objc func toggleMelder() { melderOn.toggle(); updateIcon(); if melderOn { send("alive") } }

    @objc func setIP() {
        let a = NSAlert()
        a.messageText = "IP address of the secondary Mac"
        a.informativeText = "In addition to the broadcast, notifications are sent directly to this IP. Leave empty for broadcast only."
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        tf.stringValue = secondaryIP
        a.accessoryView = tf
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = tf
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { secondaryIP = tf.stringValue.trimmingCharacters(in: .whitespaces) }
    }

    @objc func toggleLogin() {
        do {
            try LoginItem.toggle()
        } catch { alert(error.localizedDescription) }
    }
}
