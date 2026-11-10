import AppKit
import Foundation

enum FleetSettings {
    static let urlKey = "SparkDash.URL"
    static let sshHostKey = "SparkDash.SSHHost"
    static let defaultURL = "http://127.0.0.1:5555"
}

/// Keeps `ssh -N -L <local>:127.0.0.1:<remote> <host>` running for a sparkDash bound to loopback on the head.
/// Only the process this object started is ever terminated.
@MainActor
final class SparkDashTunnel {
    private var process: Process?
    private(set) var lastError: String?
    /// Free loopback port picked when the tunnel starts, so it never collides with a manual `ssh -L 5555`.
    private(set) var localPort: Int?

    var isRunning: Bool { process?.isRunning == true }

    func ensure(host: String, remotePort: Int) {
        guard !isRunning else { return }
        guard let localPort = Self.freeLoopbackPort() else {
            lastError = "no free local port"
            return
        }
        self.localPort = localPort
        let ssh = Process()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        ssh.arguments = [
            "-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2", "-L", "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)", host,
        ]
        let errors = Pipe()
        ssh.standardError = errors
        ssh.standardOutput = FileHandle.nullDevice
        ssh.terminationHandler = { [weak self] proc in
            let text = String(data: errors.fileHandleForReading.availableData, encoding: .utf8) ?? ""
            Task { @MainActor in
                guard let self, self.process === proc else { return }
                self.lastError = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init)
                self.process = nil
            }
        }
        do {
            try ssh.run()
            process = ssh
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    static func freeLoopbackPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : nil
    }

    func stop() {
        guard let process else { return }
        self.process = nil
        if process.isRunning { process.terminate() }
    }
}

@MainActor
final class FleetViewModel: ObservableObject {
    @Published private(set) var snapshot = FleetSnapshot()
    @Published private(set) var reachable = false
    @Published private(set) var errorText = "Connecting…"
    @Published private(set) var lastUpdate: Date?
    @Published private(set) var history: [String: [Double]] = [:]
    @Published var urlString: String { didSet { settingsChanged(old: oldValue, new: urlString, key: FleetSettings.urlKey) } }
    @Published var sshHost: String { didSet { settingsChanged(old: oldValue, new: sshHost, key: FleetSettings.sshHostKey) } }

    static let historyLimit = 600  // 30 minutes at 3 s
    private let tunnel = SparkDashTunnel()
    private var pollTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?
    private let demo: Bool

    init(defaults: UserDefaults = .standard, demo: Bool = false) {
        self.demo = demo
        urlString = defaults.string(forKey: FleetSettings.urlKey) ?? FleetSettings.defaultURL
        sshHost = defaults.string(forKey: FleetSettings.sshHostKey) ?? ""
        start()
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.tunnel.stop() }
        }
        wakeTask = Task { [weak self] in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) {
                self?.restart()
            }
        }
    }

    deinit {
        pollTask?.cancel()
        wakeTask?.cancel()
    }

    /// The URL the panel links to and the client polls (the tunnel end when SSH is configured).
    var effectiveURL: URL? {
        guard let configured = URL(string: urlString.trimmingCharacters(in: .whitespaces)), configured.scheme != nil else { return nil }
        guard !trimmedHost.isEmpty else { return configured }
        guard let port = tunnel.localPort else { return nil }
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = "127.0.0.1"
        parts.port = port
        return parts.url
    }

    var menuBarTitle: String {
        guard reachable, snapshot.totalCount > 0 else { return "⚡ —" }
        let rate = snapshot.generationTps > 0 ? "\(Int(snapshot.generationTps.rounded())) t/s" : "\(Int(snapshot.busiest.rounded()))%"
        return "\(snapshot.onlineCount)/\(snapshot.totalCount)  \(rate)  \(Int(snapshot.hottest.rounded()))°"
    }

    var alerting: Bool { !reachable || !snapshot.alerts.isEmpty }

    func restart() {
        tunnel.stop()
        start()
    }

    func openDashboard() {
        if let url = effectiveURL { NSWorkspace.shared.open(url) }
    }

    func quit(stopApp: Bool = true) {
        pollTask?.cancel()
        tunnel.stop()
        if stopApp { NSApplication.shared.terminate(nil) }
    }

    func apply(_ next: FleetSnapshot, at date: Date) {
        snapshot = next
        reachable = true
        errorText = ""
        lastUpdate = date
        for spark in next.sparks {
            var points = history[spark.id] ?? []
            points.append(spark.generationTps)
            if points.count > Self.historyLimit { points.removeFirst(points.count - Self.historyLimit) }
            history[spark.id] = points
        }
    }

    private var trimmedHost: String { sshHost.trimmingCharacters(in: .whitespaces) }

    private func settingsChanged(old: String, new: String, key: String) {
        guard old != new else { return }
        UserDefaults.standard.set(new, forKey: key)
        restart()
    }

    private func start() {
        pollTask?.cancel()
        if demo {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.apply(.demo(at: .now), at: .now)
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                }
            }
            return
        }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func pollOnce() async {
        if !trimmedHost.isEmpty, !tunnel.isRunning {
            tunnel.ensure(host: trimmedHost, remotePort: URL(string: urlString)?.port ?? 5555)
            try? await Task.sleep(for: .seconds(2))
        }
        guard let url = effectiveURL else {
            reachable = false
            errorText = tunnel.lastError.map { "SSH tunnel: \($0)" } ?? SparkDashError.invalidURL.message
            return
        }
        do {
            let next = try await SparkDashClient(baseURL: url).fetchFleet()
            apply(next, at: .now)
        } catch {
            reachable = false
            if let tunnelError = tunnel.lastError, !trimmedHost.isEmpty, !tunnel.isRunning {
                errorText = "SSH tunnel: \(tunnelError)"
            } else {
                errorText = (error as? SparkDashError)?.message ?? "sparkDash unavailable"
            }
        }
    }
}

extension FleetSnapshot {
    static func demo(at date: Date) -> FleetSnapshot {
        let t = date.timeIntervalSince1970
        var head = SparkSummary()
        head.id = "spark-a"
        head.name = "spark-a (head)"
        head.role = "head"
        head.online = true
        head.uptime = 180_000
        head.gpuChip = "GB10"
        head.usage = 90 + 8 * sin(t / 7)
        head.temperature = 70 + 3 * sin(t / 11)
        head.power = 38
        head.powerLimit = 120
        head.systemPower = 62
        head.vramUsedMB = 106_920
        head.vramTotalMB = 124_608
        head.memUsedMB = 114_000
        head.memTotalMB = 124_608
        head.memBandwidth = 210
        head.memBandwidthPeak = 400
        head.oomRisk = "high"
        head.storagePct = 36
        head.storageLabel = "/"
        head.smClockMHz = 2190
        head.smClockMaxMHz = 3003
        head.cpuUsage = 12
        head.cpuTemp = 55
        head.cpuPower = 9
        head.cpuTdp = 65
        head.netPrimary = "enP7s7"
        head.netLinkMbps = 1000
        head.netRx = 1_800
        head.netTx = 30_000
        head.topProcess = "tensorfold-native"
        head.topProcessVramMB = 106_920
        head.llmAvailable = true
        head.backend = "tensorfold"
        head.model = "Example-Model"
        head.contextLength = 1_048_576
        head.slotsActive = 2
        head.slotsTotal = 8
        head.generationTps = 60 + 20 * sin(t / 5)
        head.prefillTps = 900
        head.totalOutputTokens = 107_072
        head.kvCacheUsage = 0.12
        head.requestsRunning = 2
        head.requestsWaiting = 0
        head.ttftP95 = 1.9
        head.itlP95 = 0.04
        head.prefixCacheHitRate = 0.92
        head.mtpAcceptanceRate = 0.68
        head.postureLevel = "warn"
        head.postureLabel = "Open · LAN"
        var worker = head
        worker.id = "spark-b"
        worker.name = "spark-b (worker)"
        worker.role = "worker"
        worker.workerLabel = "Example-Model"
        worker.llmMonitoring = false
        worker.llmAvailable = false
        worker.generationTps = 0
        worker.prefillTps = 0
        worker.temperature = 66 + 2 * cos(t / 9)
        return FleetSnapshot(
            sparks: [head, worker],
            energy: FleetEnergy(
                currentWatts: 124, energy24hKwh: 1.81, whPerOutputToken24h: 0.034, freshNodeCount: 2, nodeCount: 2,
                hourlyWatts: (0..<24).map { 70 + 30 * sin(Double($0) / 3) }))
    }
}
