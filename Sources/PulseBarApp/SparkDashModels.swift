import Foundation

/// One host as reported by sparkDash `/api/sparks/:id/metrics`, flattened to what the panel shows.
/// Field selection mirrors patcastle/omarchy-sparkdash so both widgets read the API the same way.
struct SparkSummary: Sendable, Equatable, Identifiable {
    var id = "unknown"
    var name = "Spark"
    var kind = "spark"
    var role = "standalone"
    var workerLabel = ""
    var online = false
    var uptime: Double?
    var llmMonitoring = true
    var gpuChip = ""

    var usage = 0.0
    var temperature = 0.0
    var power = 0.0
    var powerLimit = 0.0
    var systemPower: Double?
    var vramUsedMB = 0.0
    var vramTotalMB = 0.0
    var topProcess = ""
    var topProcessVramMB = 0.0

    var throttled = false
    var throttleReason = "ok"
    var smClockMHz: Double?
    var smClockMaxMHz: Double?

    var cpuUsage = 0.0
    var cpuTemp = 0.0
    var cpuPower = 0.0
    var cpuTdp = 0.0

    var memUsedMB = 0.0
    var memTotalMB = 0.0
    var memBandwidth = 0.0
    var memBandwidthPeak = 0.0
    var oomRisk = "low"

    var storagePct = 0.0
    var storageLabel = ""

    var netPrimary = ""
    var netLinkMbps: Double?
    var netRx = 0.0
    var netTx = 0.0

    var llmAvailable = false
    var backend = ""
    var model = ""
    var contextLength: Double?
    var slotsActive = 0
    var slotsTotal = 0
    var generationTps = 0.0
    var prefillTps = 0.0
    var totalOutputTokens = 0.0
    var kvCacheUsage: Double?
    var requestsRunning: Double?
    var requestsWaiting: Double?
    var ttftP95: Double?
    var itlP95: Double?
    var prefixCacheHitRate: Double?
    var mtpAcceptanceRate: Double?
    var postureLevel = ""
    var postureLabel = ""

    var roleLabel: String {
        switch role {
        case "worker": return workerLabel.isEmpty ? "WORKER" : "WORKER · \(workerLabel)"
        case "head": return "HEAD"
        default: return kind == "host" ? "HOST" : "SPARK"
        }
    }
}

struct FleetEnergy: Sendable, Equatable {
    var currentWatts: Double?
    var energy24hKwh: Double?
    var whPerOutputToken24h: Double?
    var freshNodeCount = 0
    var nodeCount = 0
    var hourlyWatts: [Double?] = []
}

struct FleetAlert: Sendable, Equatable, Hashable {
    enum Severity: Sendable { case critical, warning }
    var host: String
    var label: String
    var severity: Severity
}

struct FleetSnapshot: Sendable, Equatable {
    var sparks: [SparkSummary] = []
    var energy: FleetEnergy?

    var onlineCount: Int { sparks.filter(\.online).count }
    var totalCount: Int { sparks.count }
    var generationTps: Double { sparks.reduce(0) { $0 + $1.generationTps } }
    var prefillTps: Double { sparks.reduce(0) { $0 + $1.prefillTps } }
    var hottest: Double { sparks.map(\.temperature).max() ?? 0 }
    var busiest: Double { sparks.map(\.usage).max() ?? 0 }
    var vramUsedMB: Double { sparks.reduce(0) { $0 + $1.vramUsedMB } }
    var vramTotalMB: Double { sparks.reduce(0) { $0 + $1.vramTotalMB } }
    var memUsedMB: Double { sparks.reduce(0) { $0 + $1.memUsedMB } }
    var memTotalMB: Double { sparks.reduce(0) { $0 + $1.memTotalMB } }
    var watts: Double { energy?.currentWatts ?? sparks.reduce(0) { $0 + ($1.systemPower ?? $1.power) } }

    var alerts: [FleetAlert] {
        var out: [FleetAlert] = []
        for spark in sparks {
            guard spark.online else {
                out.append(.init(host: spark.name, label: "Host unreachable", severity: .critical))
                continue
            }
            if spark.throttled {
                out.append(.init(host: spark.name, label: "GPU throttled · \(spark.throttleReason)", severity: .critical))
            }
            if spark.storagePct >= 90 {
                out.append(.init(host: spark.name, label: "Storage \(Int(spark.storagePct.rounded()))%", severity: .warning))
            }
            if spark.llmMonitoring && !spark.llmAvailable {
                out.append(.init(host: spark.name, label: "LLM unavailable", severity: .warning))
            }
        }
        return out
    }
}

enum SparkDashDecoding {
    static func sparkIDs(from data: Data) throws -> [String] {
        let root = try object(data)
        return array(root["sparks"]).compactMap { string(($0 as? [String: Any])?["id"]) }
    }

    static func summary(from data: Data) throws -> SparkSummary {
        summary(from: try object(data))
    }

    static func energy(from data: Data) throws -> FleetEnergy {
        let p = try object(data)
        return FleetEnergy(
            currentWatts: optional(p["currentWatts30s"]),
            energy24hKwh: optional(p["energy24hKwh"]),
            whPerOutputToken24h: optional(p["whPerOutputToken24h"]),
            freshNodeCount: Int(num(p["freshNodeCount"])),
            nodeCount: array(p["trackedNodeIds"]).count,
            hourlyWatts: array(p["hourlyWatts24h"]).map { optional($0) }
        )
    }

    static func summary(from s: [String: Any]) -> SparkSummary {
        let metrics = dict(s["metrics"])
        let gpu = dict(metrics["gpu"])
        let power = dict(gpu["power"])
        let vram = dict(gpu["vram"])
        let throttle = dict(gpu["throttle"])
        let cpu = dict(metrics["cpu"])
        let memory = dict(metrics["unifiedMemory"])
        let bandwidth = dict(memory["bandwidth"])
        let net = dict(metrics["network"])
        let interfaces = array(net["interfaces"]).map { dict($0) }
        let primaryName = string(net["primaryInterface"])
        let primary = interfaces.first { string($0["name"]) == primaryName } ?? interfaces.first ?? [:]
        let storage = array(metrics["storage"]).map { dict($0) }
        let worstStorage = storage.max { num($0["percentage"]) < num($1["percentage"]) } ?? [:]
        let llms = array(metrics["llm"]).map { dict($0) }
        let llm = llms.first { ($0["available"] as? Bool) == true } ?? llms.first ?? [:]
        let posture = dict(llm["posture"])
        let processes = array(gpu["processes"]).map { dict($0) }
        let top = processes.max { num($0["vramMB"]) < num($1["vramMB"]) } ?? [:]
        let hardware = dict(s["hardware"])

        var r = SparkSummary()
        r.id = string(s["id"]) ?? "unknown"
        r.name = string(s["name"]) ?? r.id
        r.kind = string(s["kind"]) ?? "spark"
        r.role = string(s["role"]) ?? "standalone"
        r.workerLabel = string(s["workerLabel"]) ?? string(s["workerDerivedLabel"]) ?? ""
        r.online = (s["online"] as? Bool) ?? false
        r.uptime = optional(s["uptime"])
        r.llmMonitoring = (s["llmMonitoring"] as? Bool) ?? true
        r.gpuChip = string(hardware["gpuChip"]) ?? ""

        r.usage = num(gpu["usage"])
        r.temperature = num(gpu["temperature"])
        r.power = num(power["draw"])
        r.powerLimit = num(power["limit"])
        r.systemPower = optional(power["systemDraw"])
        r.vramUsedMB = num(vram["used"])
        r.vramTotalMB = num(vram["total"])
        r.topProcess = (string(top["name"]) ?? "").split(separator: "/").last.map(String.init) ?? ""
        r.topProcessVramMB = num(top["vramMB"])

        r.throttled = (throttle["active"] as? Bool) ?? false
        r.throttleReason = string(throttle["reason"]) ?? "ok"
        r.smClockMHz = optional(throttle["smClockMHz"])
        r.smClockMaxMHz = optional(throttle["smClockMaxMHz"])

        r.cpuUsage = num(cpu["usage"])
        r.cpuTemp = num(cpu["temperature"])
        r.cpuPower = num(cpu["draw"])
        r.cpuTdp = num(cpu["tdp"])

        r.memUsedMB = num(memory["used"])
        r.memTotalMB = num(memory["total"])
        r.memBandwidth = num(bandwidth["current"])
        r.memBandwidthPeak = num(bandwidth["peak"])
        r.oomRisk = string(memory["oomRisk"]) ?? "low"

        r.storagePct = num(worstStorage["percentage"])
        r.storageLabel = string(worstStorage["label"]) ?? ""

        r.netPrimary = string(primary["name"]) ?? ""
        r.netLinkMbps = optional(net["linkSpeedMbps"])
        r.netRx = num(primary["rxSpeed"])
        r.netTx = num(primary["txSpeed"])

        r.llmAvailable = (llm["available"] as? Bool) ?? false
        r.backend = string(llm["backend"]) ?? ""
        r.model = string(llm["modelId"]) ?? ""
        r.contextLength = optional(llm["contextLength"])
        r.slotsActive = Int(num(llm["slotsActive"]))
        r.slotsTotal = Int(num(llm["slotsTotal"]))
        r.generationTps = num(llm["generationTps"])
        r.prefillTps = num(llm["prefillTps"])
        r.totalOutputTokens = num(llm["totalOutputTokens"])
        r.kvCacheUsage = optional(llm["kvCacheUsage"])
        r.requestsRunning = optional(llm["requestsRunning"])
        r.requestsWaiting = optional(llm["requestsWaiting"])
        r.ttftP95 = optional(llm["ttftP95Seconds"])
        r.itlP95 = optional(llm["itlP95Seconds"])
        r.prefixCacheHitRate = optional(llm["prefixCacheHitRate"])
        r.mtpAcceptanceRate = optional(llm["mtpAcceptanceRate"])
        r.postureLevel = string(posture["level"]) ?? ""
        r.postureLabel = string(posture["label"]) ?? ""
        return r
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SparkDashError.invalidResponse
        }
        return root
    }

    private static func dict(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    private static func array(_ value: Any?) -> [Any] { value as? [Any] ?? [] }
    private static func string(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
    private static func num(_ value: Any?) -> Double { optional(value) ?? 0 }
    private static func optional(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where !(number === kCFBooleanTrue || number === kCFBooleanFalse): return number.doubleValue
        case let text as String: return Double(text)
        default: return nil
        }
    }
}

enum SparkDashError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case unauthorized
    case http(Int)

    var message: String {
        switch self {
        case .invalidURL: return "Invalid sparkDash URL"
        case .invalidResponse: return "Invalid sparkDash response"
        case .unauthorized: return "sparkDash rejected the token"
        case .http(let code): return "sparkDash returned HTTP \(code)"
        }
    }
}
