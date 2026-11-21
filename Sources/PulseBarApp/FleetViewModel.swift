import AppKit
import Foundation

enum FleetSettings {
    /// Array of `{kind, url, sshHost, token}` dictionaries; supersedes the single-source keys below.
    static let sourcesKey = "Fleet.Sources"
    static let urlKey = "SparkDash.URL"
    static let sshHostKey = "SparkDash.SSHHost"
    static let sourceKey = "SparkDash.Source"
    static let tokenKey = "SparkDash.Token"
    static let defaultURL = "http://127.0.0.1:5555"
    static let defaultSource = "sparkdash"

    /// Reads `Fleet.Sources`, falling back to the legacy single-source keys so existing installs keep working.
    static func load(from defaults: UserDefaults) -> [FleetSource] {
        if let list = defaults.array(forKey: sourcesKey) as? [[String: String]], !list.isEmpty {
            return list.map(FleetSource.init(plist:))
        }
        return [
            FleetSource(
                kind: defaults.string(forKey: sourceKey) ?? defaultSource,
                url: defaults.string(forKey: urlKey) ?? defaultURL,
                sshHost: defaults.string(forKey: sshHostKey) ?? "",
                token: defaults.string(forKey: tokenKey) ?? "")
        ]
    }

    static func save(_ sources: [FleetSource], to defaults: UserDefaults) {
        defaults.set(sources.map(\.plist), forKey: sourcesKey)
    }
}

/// One endpoint the fleet panel polls: a sparkDash server (any number of Sparks) or a llama-swap host.
struct FleetSource: Equatable, Identifiable, Sendable {
    var id = UUID()
    var kind = FleetSettings.defaultSource
    var url = FleetSettings.defaultURL
    var sshHost = ""
    var token = ""

    var isLlamaSwap: Bool { kind.trimmingCharacters(in: .whitespaces) == "llamaswap" }
    var trimmedHost: String { sshHost.trimmingCharacters(in: .whitespaces) }
    var trimmedToken: String? {
        let value = token.trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
    var configuredURL: URL? {
        guard let url = URL(string: url.trimmingCharacters(in: .whitespaces)), url.scheme != nil else { return nil }
        return url
    }
    var serviceName: String { isLlamaSwap ? "llama-swap" : "sparkDash" }
    /// Short name for an unreachable-host card: the SSH host if tunnelled, else the URL host.
    var label: String {
        if !trimmedHost.isEmpty { return trimmedHost }
        return LlamaSwapDecoding.shortHost(configuredURL?.host ?? url)
    }

    init(kind: String = FleetSettings.defaultSource, url: String = FleetSettings.defaultURL, sshHost: String = "", token: String = "") {
        self.kind = kind
        self.url = url
        self.sshHost = sshHost
        self.token = token
    }

    init(plist: [String: String]) {
        self.init(
            kind: plist["kind"] ?? FleetSettings.defaultSource, url: plist["url"] ?? FleetSettings.defaultURL,
            sshHost: plist["sshHost"] ?? "", token: plist["token"] ?? "")
    }

    var plist: [String: String] { ["kind": kind, "url": url, "sshHost": sshHost, "token": token] }
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
    @Published var sources: [FleetSource] {
        didSet {
            guard sources != oldValue else { return }
            FleetSettings.save(sources, to: defaults)
            restart()
        }
    }

    static let historyLimit = 600  // 30 minutes at 3 s
    /// One tunnel per source, keyed by source id; only tunnels this object started are ever stopped.
    private var tunnels: [UUID: SparkDashTunnel] = [:]
    private var pollTask: Task<Void, Never>?
    private var wakeTask: Task<Void, Never>?
    private var terminateObserver: NSObjectProtocol?
    private let defaults: UserDefaults
    private let demo: Bool

    init(defaults: UserDefaults = .standard, demo: Bool = false) {
        self.defaults = defaults
        self.demo = demo
        sources = FleetSettings.load(from: defaults)
        start()
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopTunnels() }
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

    /// The URL a source is read through: the tunnel end when it has an SSH host, else its configured URL.
    func effectiveURL(for source: FleetSource) -> URL? {
        guard let configured = source.configuredURL else { return nil }
        guard !source.trimmedHost.isEmpty else { return configured }
        guard let port = tunnels[source.id]?.localPort else { return nil }
        var parts = URLComponents()
        parts.scheme = "http"
        parts.host = "127.0.0.1"
        parts.port = port
        return parts.url
    }

    /// "DGX SPARKS" while every source is sparkDash, "FLEET" once other hosts are mixed in.
    var title: String { sources.allSatisfy { !$0.isLlamaSwap } ? "DGX SPARKS" : "FLEET" }

    var menuBarTitle: String {
        guard reachable, snapshot.totalCount > 0 else { return "⚡ —" }
        let rate = snapshot.generationTps > 0 ? "\(Int(snapshot.generationTps.rounded())) t/s" : "\(Int(snapshot.busiest.rounded()))%"
        // Apple Silicon hosts report no GPU temperature; omit the segment instead of showing 0°.
        let temp = snapshot.hottest > 0 ? "  \(Int(snapshot.hottest.rounded()))°" : ""
        return "\(snapshot.onlineCount)/\(snapshot.totalCount)  \(rate)\(temp)"
    }

    var alerting: Bool { !reachable || !snapshot.alerts.isEmpty }

    func restart() {
        stopTunnels()
        start()
    }

    func addSource() {
        sources.append(FleetSource(kind: "llamaswap", url: ""))
    }

    func removeSource(id: UUID) {
        guard sources.count > 1 else { return }
        sources.removeAll { $0.id == id }
    }

    func openDashboard() {
        if let first = sources.first, let url = effectiveURL(for: first) { NSWorkspace.shared.open(url) }
    }

    func quit(stopApp: Bool = true) {
        pollTask?.cancel()
        stopTunnels()
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

    /// Joins per-source results in source order. A failed source becomes one offline card so the
    /// header count and alerts show it; the panel only goes fully offline when every source fails.
    static func merge(_ results: [(source: FleetSource, outcome: Result<FleetSnapshot, SourceFailure>)]) -> (
        snapshot: FleetSnapshot, errors: [String]
    ) {
        var merged = FleetSnapshot()
        var errors: [String] = []
        for (source, outcome) in results {
            switch outcome {
            case .success(let part):
                merged.sparks += part.sparks
                if merged.energy == nil { merged.energy = part.energy }
            case .failure(let failure):
                errors.append("\(source.label): \(failure.message)")
                var card = SparkSummary()
                card.id = "source-\(source.label)"
                card.name = source.label
                card.kind = source.isLlamaSwap ? "host" : "spark"
                card.online = false
                card.llmMonitoring = false
                merged.sparks.append(card)
            }
        }
        return (merged, errors)
    }

    struct SourceFailure: Error, Sendable { var message: String }

    private func stopTunnels() {
        for tunnel in tunnels.values { tunnel.stop() }
        tunnels.removeAll()
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
        var startedTunnel = false
        for source in sources where !source.trimmedHost.isEmpty {
            let tunnel = tunnels[source.id] ?? SparkDashTunnel()
            tunnels[source.id] = tunnel
            if !tunnel.isRunning {
                tunnel.ensure(host: source.trimmedHost, remotePort: source.configuredURL?.port ?? 5555)
                startedTunnel = true
            }
        }
        if startedTunnel { try? await Task.sleep(for: .seconds(2)) }

        let jobs = sources.enumerated().map { index, source in
            (index: index, source: source, url: effectiveURL(for: source), tunnelError: tunnels[source.id]?.lastError)
        }
        var outcomes = [Result<FleetSnapshot, SourceFailure>?](repeating: nil, count: jobs.count)
        await withTaskGroup(of: (Int, Result<FleetSnapshot, SourceFailure>).self) { group in
            for job in jobs {
                group.addTask { (job.index, await Self.fetch(job.source, url: job.url, tunnelError: job.tunnelError)) }
            }
            for await (index, outcome) in group { outcomes[index] = outcome }
        }
        guard !Task.isCancelled else { return }

        let results = zip(sources, outcomes).map { (source: $0, outcome: $1 ?? .failure(SourceFailure(message: "no result"))) }
        let (merged, errors) = Self.merge(results)
        if errors.count == results.count {
            reachable = false
            errorText = errors.joined(separator: "\n")
        } else {
            apply(merged, at: .now)
        }
    }

    private nonisolated static func fetch(
        _ source: FleetSource, url: URL?, tunnelError: String?
    ) async -> Result<FleetSnapshot, SourceFailure> {
        guard let url else {
            return .failure(SourceFailure(message: tunnelError.map { "SSH tunnel: \($0)" } ?? SparkDashError.invalidURL.message))
        }
        do {
            if source.isLlamaSwap {
                return .success(try await LlamaSwapClient(baseURL: url, token: source.trimmedToken).fetchFleet())
            }
            return .success(try await SparkDashClient(baseURL: url, token: source.trimmedToken).fetchFleet())
        } catch {
            if let tunnelError, !source.trimmedHost.isEmpty { return .failure(SourceFailure(message: "SSH tunnel: \(tunnelError)")) }
            let message =
                (error as? SparkDashError)?.message.replacingOccurrences(of: "sparkDash", with: source.serviceName)
                ?? "\(source.serviceName) unavailable"
            return .failure(SourceFailure(message: message))
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
