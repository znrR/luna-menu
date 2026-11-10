import AppKit
import ApplicationServices
import ServiceManagement
import Darwin
import Network

// MARK: - Constants

let lunaBundleID = "com.astro-hq.LunaSecondaryMac"
let lunaAppURL = URL(fileURLWithPath: "/Applications/Luna Secondary.app")
let lunaStateFile = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Astropad/LunaSecondary/LunaSecondary.Client.state_sync.json")
let lunaPorts: Set<Int> = [44553, 44554, 44555, 44556]
let lunaTCPPort: UInt16 = 44555


// MARK: - Network helpers

/// Own IPv4 address of the default interface (prefers en0, otherwise the first private one).
func ownIPv4() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    var candidates: [(String, String)] = []
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa = p.pointee
        guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
              (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        let ip = String(cString: host)
        if ip.hasPrefix("169.254.") { continue }
        candidates.append((String(cString: ifa.ifa_name), ip))
    }
    return candidates.first(where: { $0.0 == "en0" })?.1 ?? candidates.first?.1
}

/// Is the primary awake? Luna Display always listens on 44554 (discovery), on 44555 only during a session.
/// The primary may use firewall stealth mode (no ping, no RST) → only a successful connect is reliable.
func primaryAwake(_ ip: String) -> Bool {
    for port: UInt16 in [44554, 44555, 44556] where hostAwake(ip, port: port, timeout: 1.5) { return true }
    return pingOK(ip)
}

/// Seconds since the last local input (mouse/keyboard on this Mac).
func localIdleSeconds() -> Double {
    CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: CGEventType(rawValue: ~0)!)
}

/// TCP connect: connection or RST = awake, timeout = asleep/gone.
func hostAwake(_ ip: String, port: UInt16 = lunaTCPPort, timeout: Double = 2.0) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    if r == 0 { return true }
    if errno == ECONNREFUSED { return true }
    guard errno == EINPROGRESS else { return false }
    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else { return false }
    var err: Int32 = 0
    var len = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
    return err == 0 || err == ECONNREFUSED
}

/// Fallback: ICMP ping (in case the primary is awake but Luna Display isn't listening and the firewall drops RSTs).
func pingOK(_ ip: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/sbin/ping")
    p.arguments = ["-c", "1", "-t", "2", "-q", ip]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}


/// Remote IP of the active Luna connection (TCP ESTABLISHED on a Luna port), otherwise nil.
func lunaPeer(pid: pid_t) -> String? {
    let out = run("/usr/sbin/lsof", ["-nP", "-a", "-p", "\(pid)", "-iTCP", "-sTCP:ESTABLISHED", "-Fn"])
    for line in out.split(separator: "\n") where line.hasPrefix("n") {
        // n192.168.1.20:51234->192.168.1.10:44555
        guard let arrow = line.range(of: "->") else { continue }
        let local = line[line.index(after: line.startIndex)..<arrow.lowerBound]
        let remote = line[arrow.upperBound...]
        func split(_ s: Substring) -> (String, Int)? {
            guard let c = s.lastIndex(of: ":"), let port = Int(s[s.index(after: c)...]) else { return nil }
            return (String(s[..<c]).trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port)
        }
        guard let l = split(local), let r = split(remote) else { continue }
        if lunaPorts.contains(r.1) || lunaPorts.contains(l.1) { return r.0 }
    }
    return nil
}

/// Last known host from the Luna Secondary configuration.
func lunaLastKnownHost() -> (ip: String, name: String?)? {
    guard let data = try? Data(contentsOf: lunaStateFile),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let host = json["connectivity.last_known_host"] as? [String: Any],
          let addrs = host["addresses"] as? [String], let a = addrs.first else { return nil }
    let ip = a.split(separator: ":").first.map(String.init) ?? a
    return (ip, host["host_name"] as? String)
}

// MARK: - Remote control of Luna Secondary via Accessibility

enum AXError2: Error, CustomStringConvertible {
    case notTrusted, notRunning, notFound(String)
    var description: String {
        switch self {
        case .notTrusted: return "Luna Menu needs permission under System Settings › Privacy & Security › Accessibility."
        case .notRunning: return "Luna Secondary is not running."
        case .notFound(let s): return "Not found in Luna Secondary: \(s)"
        }
    }
}


@MainActor
final class LunaControl {
    static func app() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: lunaBundleID).first
    }

    static func ensureTrusted() throws {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { throw AXError2.notTrusted }
    }

    /// Launches Luna Secondary (if needed) and brings it to the front. Returns the PID.
    static func launch(activate: Bool = true) async throws -> pid_t {
        if let a = app() {
            if activate { a.activate() }
            return a.processIdentifier
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = activate
        let a = try await NSWorkspace.shared.openApplication(at: lunaAppURL, configuration: cfg)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        return a.processIdentifier
    }

    static func waitFor(_ secs: Double, _ f: () -> AXUIElement?) async -> AXUIElement? {
        let end = Date().addingTimeInterval(secs)
        while Date() < end {
            if let e = f() { return e }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return nil
    }

    static func button(in root: AXUIElement, _ titles: [String]) -> AXUIElement? {
        AX.all(root) { e in
            AX.role(e) == kAXButtonRole as String &&
            titles.contains(where: { AX.title(e).localizedCaseInsensitiveContains($0) })
        }.first
    }

    /// Performs a Manual Connection to the given IP.
    static func manualConnect(ip: String) async throws {
        try ensureTrusted()
        let octets = ip.split(separator: ".").map(String.init)
        guard octets.count == 4, octets.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else {
            throw AXError2.notFound("a valid IP (\(ip))")
        }
        let pid = try await launch()
        let appEl = AXUIElementCreateApplication(pid)
        log("manualConnect \(ip)")

        // Is the dialog already open? Otherwise press "Manual Connection" (pressing "Office" first if needed).
        func fieldsWithConnect() -> (fields: [AXUIElement], connect: AXUIElement)? {
            for w in (AX.attr(appEl, kAXWindowsAttribute) as [AXUIElement]?) ?? [] {
                guard let c = button(in: w, ["Connect"]),
                      AX.title(c).localizedCaseInsensitiveContains("manual") == false else { continue }
                let f = AX.all(w) { AX.role($0) == kAXTextFieldRole as String && (AX.attr($0, kAXEnabledAttribute) as Bool? ?? true) }
                if f.count >= 4 { return (f, c) }
            }
            return nil
        }
        if fieldsWithConnect() == nil {
            let manual = await waitFor(4) {
                for w in (AX.attr(appEl, kAXWindowsAttribute) as [AXUIElement]?) ?? [] {
                    if let b = button(in: w, ["Manual Connect"]) { return b }
                }
                return nil
            }
            if let m = manual {
                AX.press(m)
            } else {
                // The Manual button may only be visible in Office mode
                var pressedOffice = false
                for w in (AX.attr(appEl, kAXWindowsAttribute) as [AXUIElement]?) ?? [] {
                    if let o = button(in: w, ["Office"]) { AX.press(o); pressedOffice = true; break }
                }
                guard pressedOffice, let m2 = await waitFor(3, {
                    for w in (AX.attr(appEl, kAXWindowsAttribute) as [AXUIElement]?) ?? [] {
                        if let b = button(in: w, ["Manual Connect"]) { return b }
                    }
                    return nil
                }) else { throw AXError2.notFound("the “Manual Connection” button (is a connection already active?)") }
                AX.press(m2)
            }
        }
        var found: (fields: [AXUIElement], connect: AXUIElement)?
        let end = Date().addingTimeInterval(4)
        while Date() < end, found == nil {
            found = fieldsWithConnect()
            if found == nil { try? await Task.sleep(nanoseconds: 200_000_000) }
        }
        guard let dlg = found else { throw AXError2.notFound("the IP fields in the Manual Connect dialog") }
        // The four octet fields sit side by side: sort by x and take the last four.
        let fields = dlg.fields.sorted { AX.frame($0).minX < AX.frame($1).minX }.suffix(4)
        for (f, o) in zip(fields, octets) {
            AXUIElementSetAttributeValue(f, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(f, kAXValueAttribute as CFString, o as CFString)
            AXUIElementPerformAction(f, kAXConfirmAction as CFString)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        AX.press(dlg.connect)
        log("manualConnect: pressed Connect")
    }

    /// Same effect as a long Esc press: quit Luna Secondary. The app ignores a short Esc (it wants it held for ~3 s),
    /// and its regular quit lingers for 5 s on the waiting screen → force quit shortly after.
    static func release() async {
        guard let a = app() else { return }
        a.terminate()
        try? await Task.sleep(nanoseconds: 250_000_000)
        if !a.isTerminated { a.forceTerminate() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        log("Luna Secondary quit (\(a.isTerminated ? "ok" : "still running!"))")
    }

    /// Opens Luna Secondary's settings via its app menu.
    static func openSettings() async throws {
        try ensureTrusted()
        let pid = try await launch()
        let appEl = AXUIElementCreateApplication(pid)
        guard let bar: AXUIElement = AX.attr(appEl, kAXMenuBarAttribute) else { throw AXError2.notFound("the menu bar") }
        let items = AX.all(bar) { e in
            AX.role(e) == kAXMenuItemRole as String &&
            ["Preferences", "Settings", "Einstellungen"].contains(where: { AX.title(e).hasPrefix($0) })
        }
        guard let item = items.first else { throw AXError2.notFound("the “Preferences…” menu item") }
        AX.press(item)
    }
}

// MARK: - App

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static func main() {
        let app = NSApplication.shared
        let d = AppDelegate()
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// idle: this Mac is just a Mac (or connected) · probing: connection lost while acting as secondary, reason unknown
    /// primaryAsleep: acting as secondary, primary is asleep · waitingReconnect: primary awake, becoming secondary again
    enum SleepState: String { case idle, probing, primaryAsleep, waitingReconnect }

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let defaults = UserDefaults.standard
    var peer: String?            // currently connected primary
    var lastPeer: String?        // last connected primary (for sleep/wake)
    var sleepState: SleepState = .idle
    var failCount = 0
    var stateSince = Date()
    var busy = false
    var probeInFlight = false
    var listener: NWListener?
    var melderLast: [String: (state: String, at: Date)] = [:]   // last notifier message per primary IP

    var history: [String] {
        get { defaults.stringArray(forKey: "history") ?? [] }
        set { defaults.set(Array(newValue.prefix(6)), forKey: "history") }
    }
    var names: [String: String] {
        get { (defaults.dictionary(forKey: "names") as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: "names") }
    }
    /// "Display" mode (iMac): Luna always stays open. "Mac" mode (Mac mini): woken by hand → Luna quits.
    var monitorOnly: Bool {
        get { defaults.object(forKey: "monitorOnly") as? Bool ?? (macName == "iMac") }
        set { defaults.set(newValue, forKey: "monitorOnly") }
    }
    /// Mac mode: taken over by hand → block Luna's automatic reconnect until the user switches back.
    var heldAsMac = false
    /// Until when a display wake is caused by us (caffeinate) rather than by hand.
    var selfWakeUntil = Date.distantPast
    var sleepCoupling: Bool {
        get { defaults.object(forKey: "sleepCoupling") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "sleepCoupling") }
    }
    /// Primaries that have sent notifier messages before (no port probing needed then).
    var melderKnown: [String: Double] {
        get { (defaults.dictionary(forKey: "melderKnown") as? [String: Double]) ?? [:] }
        set { defaults.set(newValue, forKey: "melderKnown") }
    }
    func hasMelder(_ ip: String) -> Bool {
        guard let t = melderKnown[ip] else { return false }
        return Date().timeIntervalSince1970 - t < 14 * 86400
    }
    /// Notifier is alive (heartbeat every 10 s) → fresh.
    func melderFresh(_ ip: String) -> Bool {
        guard let m = melderLast[ip] else { return false }
        return Date().timeIntervalSince(m.at) < 35
    }

    /// "Mac mini", "iMac", … from hw.model
    let macName: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        let m = String(cString: buf)
        if m.hasPrefix("Macmini") { return "Mac mini" }
        if m.hasPrefix("iMac") { return "iMac" }
        if m.hasPrefix("MacBook") { return "MacBook" }
        return "Mac"
    }()

    func applicationDidFinishLaunching(_ n: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        if let h = lunaLastKnownHost() {
            remember(h.ip, name: h.name, front: false)
            lastPeer = history.first
        }
        startListener()
        // Real time: this Mac's display wakes → check immediately whether that was by hand.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.localScreenWoke() }
        }
        updateIcon()
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        tick()
        log("started")
    }

    func remember(_ ip: String, name: String? = nil, front: Bool = true) {
        var h = history.filter { $0 != ip }
        if front || h.isEmpty { h.insert(ip, at: 0) } else { h.append(ip) }
        history = h
        if let name { var n = names; n[ip] = name; names = n }
    }

    func label(_ ip: String) -> String {
        if let n = names[ip] { return "\(ip)  (\(n))" }
        return ip
    }

    func updateIcon() {
        let name: String
        if peer != nil { name = "display.2" }                 // connected: two displays
        else if sleepState == .primaryAsleep { name = "moon.zzz" }
        else { name = "display" }                             // just the display
        setStatusSymbol(item.button, name, fallback: peer != nil ? "▣▣" : (sleepState == .primaryAsleep ? "☾" : "▣"))
        item.button?.toolTip = statusText()
    }

    func primaryText(_ ip: String) -> String? {
        guard melderFresh(ip) || hasMelder(ip), let m = melderLast[ip] else { return nil }
        if !melderFresh(ip) { return "Primary asleep (notifier silent)" }
        switch m.state {
        case "sleep": return "Primary asleep"
        case "screenoff": return "Primary: display off"
        default: return "Primary awake"
        }
    }

    func statusText() -> String {
        if let p = peer {
            if let t = primaryText(p), t != "Primary awake" { return "Connected to \(label(p)) – \(t)" }
            return "Connected to \(label(p))"
        }
        switch sleepState {
        case .primaryAsleep: return "Primary asleep – display off"
        case .probing: return "Connection lost – checking primary …"
        case .waitingReconnect: return "Primary awake – reconnecting as secondary …"
        case .idle:
            let base = LunaControl.app() == nil ? "\(macName) (Luna Secondary not running)" : "\(macName) – ready to be a display"
            if let ip = lastPeer, let t = primaryText(ip) { return "\(base) · \(t)" }
            return base
        }
    }

    func setState(_ s: SleepState) {
        guard s != sleepState else { return }
        log("state \(sleepState.rawValue) → \(s.rawValue)")
        sleepState = s; stateSince = Date(); failCount = 0
    }

    // MARK: Notifier receiver

    func startListener() {
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: melderPort)!)
            l.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .main)
                func receive() {
                    conn.receiveMessage { data, _, _, err in
                        if let data, let text = String(data: data, encoding: .utf8),
                           case .hostPort(let host, _) = conn.endpoint {
                            var ip = "\(host)"
                            if let pct = ip.firstIndex(of: "%") { ip = String(ip[..<pct]) }
                            if ip.hasPrefix("::ffff:") { ip = String(ip.dropFirst(7)) }
                            Task { @MainActor in self?.handleMelder(text, from: ip) }
                        }
                        if err == nil { receive() } else { conn.cancel() }
                    }
                }
                receive()
            }
            l.stateUpdateHandler = { st in if case .failed(let e) = st { log("notifier receiver failed: \(e)") } }
            l.start(queue: .main)
            listener = l
        } catch { log("notifier receiver not started: \(error)") }
    }

    func handleMelder(_ text: String, from ip: String) {
        let f = text.split(separator: " ").map(String.init)
        guard f.count >= 3, f[0] == melderMagic, ip != ownIPv4() else { return }
        let event = f[1], state = f[2]
        let host = f.count >= 4 ? f[3...].joined(separator: " ") : nil
        let prev = melderLast[ip]?.state
        melderLast[ip] = (state, Date())
        var k = melderKnown; k[ip] = Date().timeIntervalSince1970; melderKnown = k
        if let host, names[ip] == nil { var n = names; n[ip] = host; names = n }
        if event != "alive" || prev != state { log("notifier \(ip): \(event) / \(state)") }

        let asleep = state != "awake"
        let wasSecondary = peer == ip || (lastPeer == ip && sleepState != .idle)
        guard sleepCoupling else { updateIcon(); return }

        if asleep {
            if wasSecondary, sleepState != .primaryAsleep {
                lastPeer = ip
                setState(.primaryAsleep)
                sleepDisplay()
            }
        } else if lastPeer == ip {
            switch sleepState {
            case .primaryAsleep:
                if peer != nil { setState(.idle) } else { setState(.waitingReconnect) }
                wakeDisplay()
            case .probing:
                // Primary reports awake but the connection is gone → disconnected on purpose (short grace period for the sleep message).
                if Date().timeIntervalSince(stateSince) > 15 { setState(.idle) }
            default: break
            }
        }
        updateIcon()
    }

    // MARK: Monitoring / sleep coupling

    func tick() {
        let newPeer = LunaControl.app().flatMap { lunaPeer(pid: $0.processIdentifier) }
        if newPeer != peer {
            log("connection: \(peer ?? "–") → \(newPeer ?? "–")")
            if let p = newPeer {
                if heldAsMac {
                    log("Luna reconnected on its own, but the Mac was taken over by hand → quitting Luna Secondary")
                    heldAsMac = false
                    LunaControl.app()?.terminate()
                    peer = nil
                    updateIcon()
                    return
                }
                lastPeer = p
                let name = lunaLastKnownHost().flatMap { $0.ip == p ? $0.name : nil }
                remember(p, name: name)
                if sleepState == .waitingReconnect || sleepState == .probing { setState(.idle) }
            } else if peer != nil, sleepCoupling, sleepState == .idle {
                setState(.probing)
            }
            peer = newPeer
        }
        // Luna Secondary not running → this Mac is just a Mac, nothing to couple.
        if LunaControl.app() == nil, sleepState != .idle, sleepState != .waitingReconnect { setState(.idle) }

        // Woken and used by hand while the primary sleeps → stays a Mac.
        if sleepState == .primaryAsleep {
            let since = Date().timeIntervalSince(stateSince)
            if !monitorOnly, since > 10, CGDisplayIsAsleep(CGMainDisplayID()) == 0, localIdleSeconds() < since - 5 {
                log("used by hand while the primary sleeps → stays \(macName), quitting Luna Secondary")
                setState(.idle)
                heldAsMac = true
                Task { await LunaControl.release() }
            }
        }

        guard sleepCoupling, let target = lastPeer else { updateIcon(); return }
        let melder = hasMelder(target)

        switch sleepState {
        case .idle:
            break
        case .probing:
            let since = Date().timeIntervalSince(stateSince)
            if melder {
                // Notifier went silent (sleep message lost) → primary is asleep.
                if !melderFresh(target), since > 5 { setState(.primaryAsleep); sleepDisplay() }
                else if since > 120 { setState(.idle) }
            } else { probe(target) }
        case .primaryAsleep:
            if melder {
                // No port probing (it could wake the primary via a Bonjour sleep proxy) – wait for "wake".
            } else if peer == nil { probe(target) }
        case .waitingReconnect:
            let waited = Date().timeIntervalSince(stateSince)
            if peer == nil, waited > 20, failCount == 0, !busy {
                failCount = 1                // only one attempt
                log("primary awake, no connection → Manual Connect \(target)")
                connect(target, showErrors: false)
            }
            if waited > 120 { setState(.idle) }
        }
        updateIcon()
    }

    /// Fallback without notifier: probe the Luna ports.
    func probe(_ target: String) {
        guard !probeInFlight else { return }
        probeInFlight = true
        Task.detached { [target] in
            let awake = primaryAwake(target)
            await MainActor.run { self.probeInFlight = false; self.probeResult(awake: awake) }
        }
    }

    func probeResult(awake: Bool) {
        guard peer == nil else { return }
        switch sleepState {
        case .probing:
            if awake {
                if Date().timeIntervalSince(stateSince) > 60 { setState(.idle) }
                failCount = 0
            } else {
                failCount += 1
                if failCount >= 4 { setState(.primaryAsleep); sleepDisplay() }
            }
        case .primaryAsleep:
            if awake {
                failCount += 1
                if failCount >= 2 { setState(.waitingReconnect); wakeDisplay() }
            } else { failCount = 0 }
        default: break
        }
        updateIcon()
    }

    func localScreenWoke() {
        guard sleepState == .primaryAsleep, Date() > selfWakeUntil else { return }
        if monitorOnly { log("display woken by hand (display mode → Luna stays)"); return }
        log("display woken by hand → stays \(macName), quitting Luna Secondary")
        setState(.idle)
        heldAsMac = true
        Task { await LunaControl.release() }
    }

    func sleepDisplay() {
        log("display off (pmset displaysleepnow)")
        run("/usr/bin/pmset", ["displaysleepnow"])
    }

    func wakeDisplay() {
        log("display on (caffeinate -u)")
        selfWakeUntil = Date().addingTimeInterval(5)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-u", "-t", "3"]
        try? p.run()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let st = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        st.isEnabled = false
        menu.addItem(st)
        menu.addItem(.separator())

        let mon = NSMenuItem(title: "Turn to Monitor", action: #selector(turnToMonitor), keyEquivalent: "")
        mon.state = peer != nil ? .on : .off
        menu.addItem(mon)

        let allow = NSMenuItem(title: "Allow from", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if let last = history.first {
            let i = NSMenuItem(title: "Last used: \(label(last))", action: #selector(connectHistory(_:)), keyEquivalent: "")
            i.representedObject = last
            sub.addItem(i)
            for ip in history.dropFirst() {
                let j = NSMenuItem(title: label(ip), action: #selector(connectHistory(_:)), keyEquivalent: "")
                j.representedObject = ip
                j.indentationLevel = 1
                sub.addItem(j)
            }
            sub.addItem(.separator())
        }
        sub.addItem(NSMenuItem(title: "New IP …", action: #selector(newIP), keyEquivalent: "n"))
        allow.submenu = sub
        menu.addItem(allow)

        menu.addItem(NSMenuItem(title: "Settings …", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())

        let sl = NSMenuItem(title: "Sleep & Wake with Primary", action: #selector(toggleSleep), keyEquivalent: "")
        sl.state = sleepCoupling ? .on : .off
        menu.addItem(sl)
        let mo = NSMenuItem(title: "Always a Display (keep Luna open)", action: #selector(toggleMonitorOnly), keyEquivalent: "")
        mo.state = monitorOnly ? .on : .off
        mo.indentationLevel = 1
        menu.addItem(mo)
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Luna Menu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for i in menu.items + sub.items where i.action != nil && i.action != #selector(NSApplication.terminate(_:)) {
            i.target = self
        }
    }

    func showError(_ e: Error) {
        let a = NSAlert()
        a.messageText = "Luna Menu"
        a.informativeText = (e as? AXError2)?.description ?? e.localizedDescription
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    @objc func turnToMonitor() {
        heldAsMac = false
        Task { do { _ = try await LunaControl.launch() } catch { showError(error) } }
    }

    @objc func connectHistory(_ sender: NSMenuItem) {
        guard let ip = sender.representedObject as? String else { return }
        connect(ip)
    }

    func connect(_ ip: String, showErrors: Bool = true) {
        heldAsMac = false
        busy = true
        lastPeer = ip
        remember(ip)
        Task {
            defer { busy = false }
            do { try await LunaControl.manualConnect(ip: ip) }
            catch { log("error: \(error)"); if showErrors { showError(error) } }
        }
    }

    @objc func newIP() {
        let own = ownIPv4() ?? "192.168.1.1"
        let prefix = own.split(separator: ".").prefix(3).joined(separator: ".") + "."
        let a = NSAlert()
        a.messageText = "Allow from new IP"
        a.informativeText = "Last octet of the primary's IP address (this subnet: \(prefix)x).\nLuna Display on the primary shows the full IP under “Manual Connect”."
        let v = NSStackView(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        v.orientation = .horizontal
        let lbl = NSTextField(labelWithString: prefix)
        lbl.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        let tf = NSTextField(string: "")
        tf.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tf.placeholderString = "145"
        tf.widthAnchor.constraint(equalToConstant: 60).isActive = true
        v.addArrangedSubview(lbl); v.addArrangedSubview(tf)
        a.accessoryView = v
        a.addButton(withTitle: "Connect")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = tf
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let t = tf.stringValue.trimmingCharacters(in: .whitespaces)
        // Entering a full IP address works too.
        let ip = t.contains(".") ? t : prefix + t
        guard let last = Int(ip.split(separator: ".").last ?? ""), (1...254).contains(last),
              ip.split(separator: ".").count == 4 else {
            showError(AXError2.notFound("a valid IP (“\(t)”)")); return
        }
        connect(ip)
    }

    @objc func openSettings() {
        Task { do { try await LunaControl.openSettings() } catch { showError(error) } }
    }

    @objc func toggleMonitorOnly() { monitorOnly.toggle() }

    @objc func toggleSleep() {
        sleepCoupling.toggle()
        if !sleepCoupling { setState(.idle) }
    }

    @objc func toggleLogin() {
        do {
            try LoginItem.toggle()
        } catch { showError(error) }
    }
}
