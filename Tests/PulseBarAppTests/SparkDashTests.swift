import XCTest

@testable import PulseBarApp

final class SparkDashTests: XCTestCase {
    private let metrics = Data(
        """
        {"id":"spark-a","name":"spark-a (head)","online":true,"role":"head","uptime":3700,"llmMonitoring":true,
         "hardware":{"gpuChip":"GB10"},
         "metrics":{"gpu":{"usage":93,"temperature":76,"power":{"draw":38.7,"limit":120,"systemDraw":55},
           "vram":{"used":63997,"total":124546},"throttle":{"active":false,"reason":"ok","smClockMHz":2190,"smClockMaxMHz":3003},
           "processes":[{"name":"/usr/local/bin/tensorfold-native","vramMB":63997}]},
          "cpu":{"usage":16,"temperature":86.1,"draw":14.8,"tdp":65},
          "unifiedMemory":{"used":120283,"total":124546,"oomRisk":"high","bandwidth":{"current":12,"peak":400}},
          "network":{"primaryInterface":"enP7s7","linkSpeedMbps":2500,"interfaces":[{"name":"wlan0"},{"name":"enP7s7","rxSpeed":6095,"txSpeed":54062}]},
          "storage":[{"label":"/","percentage":38},{"label":"/data","percentage":93}],
          "llm":[{"available":false},{"available":true,"backend":"tensorfold","modelId":"org/model","generationTps":42.4,
            "prefillTps":800,"slotsActive":1,"slotsTotal":8,"kvCacheUsage":0.08,"ttftP95Seconds":1.5,"contextLength":1048576,
            "posture":{"level":"warn","label":"Open · LAN"}}]}}
        """.utf8)

    func testSummaryFlattensMetrics() throws {
        let spark = try SparkDashDecoding.summary(from: metrics)
        XCTAssertEqual(spark.id, "spark-a")
        XCTAssertEqual(spark.roleLabel, "HEAD")
        XCTAssertEqual(spark.generationTps, 42.4)
        XCTAssertEqual(spark.model, "org/model")
        XCTAssertEqual(spark.topProcess, "tensorfold-native")
        XCTAssertEqual(spark.netPrimary, "enP7s7")
        XCTAssertEqual(spark.netTx, 54062)
        XCTAssertEqual(spark.storagePct, 93)
        XCTAssertEqual(spark.storageLabel, "/data")
        XCTAssertEqual(spark.oomRisk, "high")
        XCTAssertEqual(spark.postureLabel, "Open · LAN")
        XCTAssertEqual(spark.contextLength, 1_048_576)
    }

    func testFleetTotalsAndAlerts() throws {
        var head = try SparkSummary(from: metrics)
        head.throttled = true
        head.throttleReason = "thermal"
        var worker = SparkSummary()
        worker.name = "spark-b"
        worker.online = false
        let fleet = FleetSnapshot(sparks: [head, worker])
        XCTAssertEqual(fleet.onlineCount, 1)
        XCTAssertEqual(fleet.generationTps, 42.4)
        XCTAssertEqual(fleet.hottest, 76)
        XCTAssertEqual(
            fleet.alerts.map(\.label), ["GPU throttled · thermal", "Storage 93%", "Host unreachable"])
    }

    func testEnergyAndIDs() throws {
        let json = #"{"trackedNodeIds":["a","b"],"freshNodeCount":2,"currentWatts30s":73.8,"hourlyWatts24h":[70,null,72]}"#
        let energy = try SparkDashDecoding.energy(from: Data(json.utf8))
        XCTAssertEqual(energy.nodeCount, 2)
        XCTAssertEqual(energy.currentWatts, 73.8)
        XCTAssertNil(energy.hourlyWatts[1])
        XCTAssertEqual(try SparkDashDecoding.sparkIDs(from: Data(#"{"sparks":[{"id":"a"},{"id":"b"}]}"#.utf8)), ["a", "b"])
    }

    @MainActor
    func testMenuBarTitleAndHistory() {
        let model = FleetViewModel(defaults: UserDefaults(suiteName: "SparkDashTests")!, demo: false)
        defer { model.quit(stopApp: false) }
        XCTAssertEqual(model.menuBarTitle, "⚡ —")
        var spark = SparkSummary()
        spark.id = "a"
        spark.online = true
        spark.generationTps = 61.6
        spark.temperature = 70.4
        for _ in 0..<(FleetViewModel.historyLimit + 5) { model.apply(FleetSnapshot(sparks: [spark]), at: .now) }
        XCTAssertEqual(model.menuBarTitle, "1/1  62 t/s  70°")
        XCTAssertEqual(model.history["a"]?.count, FleetViewModel.historyLimit)
    }

    func testFormatting() {
        XCTAssertEqual(FleetFormat.secs(0.089), "89ms")
        XCTAssertEqual(FleetFormat.secs(5.768), "5.77s")
        XCTAssertEqual(FleetFormat.uptime(623_051), "7d 5h")
        XCTAssertEqual(FleetFormat.rate(30_205), "29.5 KB/s")
        XCTAssertEqual(FleetFormat.tps(142.6), "143")
    }
}

extension SparkSummary {
    fileprivate init(from data: Data) throws { self = try SparkDashDecoding.summary(from: data) }
}
