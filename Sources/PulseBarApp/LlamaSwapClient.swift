import Foundation

/// Polls a llama-swap server (e.g. a headless Mac Studio serving GGUF models) and maps it into
/// the fleet model as a one-host snapshot, so the same menu bar item and panel work for it.
///
/// Endpoints used (all optional except one must succeed):
/// - `api/performance` — GPU samples (util, VRAM, power, temperature, chip name)
/// - `api/metrics/stats` — lifetime token totals
/// - `api/metrics/activity` — per-request records with tokens/sec (newest first)
/// - `metrics` — Prometheus text with CPU per core and system memory
struct LlamaSwapClient: Sendable {
    var baseURL: URL
    var token: String?
    var session: URLSession = .shared

    func fetchFleet() async throws -> FleetSnapshot {
        async let performance: Data? = try? get("api/performance")
        async let stats: Data? = try? get("api/metrics/stats")
        async let activity: Data? = try? get("api/metrics/activity")
        async let prometheus: Data? = try? get("metrics")
        async let macmon: Data? = try? get("macmon/json")
        var summary = try LlamaSwapDecoding.summary(
            performance: await performance, stats: await stats, activity: await activity,
            prometheus: await prometheus, host: baseURL.host ?? "llama-swap")
        if let data = await macmon { LlamaSwapDecoding.applyMacmon(data, to: &summary) }
        return FleetSnapshot(sparks: [summary], energy: nil)
    }

    private func get(_ path: String) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL.appendingPathComponent("")) else { throw SparkDashError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SparkDashError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw SparkDashError.unauthorized
        default: throw SparkDashError.http(http.statusCode)
        }
    }
}

/// One per-request record from `api/metrics/activity`.
struct LlamaSwapActivity: Sendable, Equatable {
    var model = ""
    var inputTokens = 0.0
    var outputTokens = 0.0
    var tokensPerSecond = 0.0
    var promptPerSecond = 0.0
    var durationMs = 0.0
}

enum LlamaSwapDecoding {
    /// Averages the generation tok/s over the most recent requests. llama-swap reports -1 when a
    /// request carries no upstream timing, so fall back to output tokens over request duration.
    static func generationTps(_ entries: [LlamaSwapActivity], window: Int = 10) -> Double {
        average(entries.prefix(window).compactMap(effectiveTps))
    }

    static func prefillTps(_ entries: [LlamaSwapActivity], window: Int = 10) -> Double {
        average(entries.prefix(window).map(\.promptPerSecond).filter { $0 > 0 })
    }

    static func effectiveTps(_ entry: LlamaSwapActivity) -> Double? {
        if entry.tokensPerSecond > 0 { return entry.tokensPerSecond }
        guard entry.outputTokens > 0, entry.durationMs > 0 else { return nil }
        return entry.outputTokens / (entry.durationMs / 1000)
    }

    /// Parses the Prometheus exposition format into plain gauges plus the per-core CPU list.
    static func prometheus(from text: String) -> (gauges: [String: Double], cpuCores: [Double]) {
        var gauges: [String: Double] = [:]
        var cpuCores: [Double] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let value = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let name = String(parts[0])
            let base = name.contains("{") ? String(name[..<name.firstIndex(of: "{")!]) : name
            if base == "llamaswap_cpu_util_percent" {
                cpuCores.append(value)
            } else {
                gauges[base] = value
            }
        }
        return (gauges, cpuCores)
    }

    /// Newest GPU sample from `api/performance` (`gpu_stats` is ordered oldest → newest).
    static func gpuSample(from data: Data) -> (
        name: String, util: Double, temp: Double, usedMB: Double, totalMB: Double, power: Double
    )? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let samples = root["gpu_stats"] as? [[String: Any]],
            let sample = samples.last
        else { return nil }
        return (
            name: string(sample["name"]) ?? "",
            util: num(sample["gpu_util_pct"]),
            temp: num(sample["temp_c"]),
            usedMB: num(sample["mem_used_mb"]),
            totalMB: num(sample["mem_total_mb"]),
            power: num(sample["power_draw_w"])
        )
    }

    static func tokenStats(from data: Data) -> (requests: Double, outputTokens: Double)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (requests: num(root["total_requests"]), outputTokens: num(root["total_output_tokens"]))
    }

    static func activity(from data: Data) -> [LlamaSwapActivity] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = root["data"] as? [[String: Any]]
        else { return [] }
        return entries.map { entry in
            let tokens = entry["tokens"] as? [String: Any] ?? [:]
            return LlamaSwapActivity(
                model: string(entry["model"]) ?? "",
                inputTokens: num(tokens["input_tokens"]),
                outputTokens: num(tokens["output_tokens"]),
                tokensPerSecond: num(tokens["tokens_per_second"]),
                promptPerSecond: num(tokens["prompt_per_second"]),
                durationMs: num(entry["duration_ms"]))
        }
    }

    static func summary(
        performance: Data?, stats: Data?, activity: Data?, prometheus: Data?, host: String
    ) throws -> SparkSummary {
        let gpu = performance.flatMap { gpuSample(from: $0) }
        let prom = prometheus.flatMap { data -> (gauges: [String: Double], cpuCores: [Double])? in
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return Self.prometheus(from: text)
        }
        let entries = activity.map { self.activity(from: $0) } ?? []
        let totals = stats.flatMap { tokenStats(from: $0) }
        guard gpu != nil || prom != nil || !entries.isEmpty || totals != nil else {
            throw SparkDashError.invalidResponse
        }

        var r = SparkSummary()
        r.id = host
        r.name = shortHost(host)
        r.kind = "host"
        r.role = "standalone"
        r.online = true
        r.gpuChip = gpu?.name ?? ""
        r.usage = gpu?.util ?? prom?.gauges["llamaswap_gpu_util_percent"] ?? 0
        r.temperature = gpu?.temp ?? prom?.gauges["llamaswap_gpu_temperature_celsius"] ?? 0
        r.power = gpu?.power ?? prom?.gauges["llamaswap_gpu_power_draw_watts"] ?? 0
        r.vramUsedMB = gpu?.usedMB ?? (prom?.gauges["llamaswap_gpu_memory_used_bytes"] ?? 0) / 1_048_576
        r.vramTotalMB = gpu?.totalMB ?? (prom?.gauges["llamaswap_gpu_memory_total_bytes"] ?? 0) / 1_048_576
        if let cores = prom?.cpuCores, !cores.isEmpty {
            r.cpuUsage = cores.reduce(0, +) / Double(cores.count)
        }
        r.memUsedMB = (prom?.gauges["llamaswap_memory_used_bytes"] ?? 0) / 1_048_576
        r.memTotalMB = (prom?.gauges["llamaswap_memory_total_bytes"] ?? 0) / 1_048_576
        let fraction = r.memTotalMB > 0 ? r.memUsedMB / r.memTotalMB : 0
        r.oomRisk = fraction >= 0.9 ? "high" : fraction >= 0.75 ? "medium" : "low"
        r.llmMonitoring = true
        r.llmAvailable = true
        r.backend = "llama-swap"
        r.model = entries.first?.model ?? ""
        r.generationTps = generationTps(entries)
        r.prefillTps = prefillTps(entries)
        r.totalOutputTokens = totals?.outputTokens ?? 0
        return r
    }

    /// Overlays Apple Silicon sensors from `macmon serve` (`GET /json`), published next to llama-swap
    /// at `<base>/macmon/json`. llama-swap reports 0 for GPU temperature and power on macOS, and its
    /// VRAM figure misses Metal allocations, so macmon wins wherever it has a value.
    static func applyMacmon(_ data: Data, to r: inout SparkSummary) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let temp = root["temp"] as? [String: Any] ?? [:]
        if num(temp["gpu_temp_avg"]) > 0 { r.temperature = num(temp["gpu_temp_avg"]) }
        if num(temp["cpu_temp_avg"]) > 0 { r.cpuTemp = num(temp["cpu_temp_avg"]) }
        if root["gpu_power"] != nil { r.power = num(root["gpu_power"]) }
        if root["cpu_power"] != nil { r.cpuPower = num(root["cpu_power"]) }
        if root["sys_power"] != nil { r.systemPower = num(root["sys_power"]) }
        if let usage = root["gpu_usage"] as? [Any], usage.count == 2 { r.usage = num(usage[1]) * 100 }
        if root["gpu_mem_in_use"] != nil { r.vramUsedMB = num(root["gpu_mem_in_use"]) / 1_048_576 }
        if root["uptime"] != nil { r.uptime = num(root["uptime"]) }
        if let memory = root["memory"] as? [String: Any], num(memory["ram_total"]) > 0 {
            r.memUsedMB = num(memory["ram_usage"]) / 1_048_576
            r.memTotalMB = num(memory["ram_total"]) / 1_048_576
            let fraction = r.memUsedMB / r.memTotalMB
            r.oomRisk = fraction >= 0.9 ? "high" : fraction >= 0.75 ? "medium" : "low"
        }
    }

    /// `sirius.example.ts.net` → `sirius`; IP addresses and single labels stay as they are.
    static func shortHost(_ host: String) -> String {
        let labels = host.split(separator: ".")
        guard labels.count > 1, let first = labels.first, Int(first) == nil else { return host }
        return String(first)
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }

    private static func num(_ value: Any?) -> Double {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let text as String: return Double(text) ?? 0
        default: return 0
        }
    }
}
