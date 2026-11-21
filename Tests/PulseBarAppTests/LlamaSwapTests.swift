import XCTest

@testable import PulseBarApp

final class LlamaSwapTests: XCTestCase {
    private let performance = Data(
        """
        {"enabled":true,"gpu_stats":[
          {"timestamp":"2026-11-17T12:54:06.687159Z","id":0,"name":"Apple M5 Ultra (80-core GPU)","temp_c":0,
           "gpu_util_pct":12.5,"mem_util_pct":0.5,"mem_used_mb":19,"mem_total_mb":262144,"fan_speed_pct":0,"power_draw_w":0},
          {"timestamp":"2026-11-17T12:54:11.687366Z","id":0,"name":"Apple M5 Ultra (80-core GPU)","temp_c":0,
           "gpu_util_pct":87.25,"mem_util_pct":0.9,"mem_used_mb":232000,"mem_total_mb":262144,"fan_speed_pct":0,"power_draw_w":0}]}
        """.utf8)

    private let stats = Data(
        #"{"total_requests":103,"total_input_tokens":915438,"total_output_tokens":23809,"total_cache_tokens":828095,"prompt_histogram":null,"gen_histogram":null}"#
            .utf8)

    private let activity = Data(
        """
        {"data":[
          {"id":103,"timestamp":"2026-11-17T13:54:02Z","model":"glm-5.3-flash","task":"chat","route":"local",
           "req_path":"/v1/chat/completions","resp_status_code":200,
           "tokens":{"cache_tokens":43023,"input_tokens":43330,"output_tokens":111,"prompt_per_second":-1,"tokens_per_second":-1},
           "duration_ms":1385},
          {"id":102,"timestamp":"2026-11-17T13:54:00Z","model":"glm-5.3-flash","task":"chat","route":"local",
           "tokens":{"input_tokens":1200,"output_tokens":300,"prompt_per_second":950.5,"tokens_per_second":62.5},
           "duration_ms":5000}]}
        """.utf8)

    private let prometheus = """
        # HELP llamaswap_cpu_util_percent CPU utilization per core (0-100)
        # TYPE llamaswap_cpu_util_percent gauge
        llamaswap_cpu_util_percent{core="0"} 10.0
        llamaswap_cpu_util_percent{core="1"} 30.0
        llamaswap_memory_total_bytes 2.74877906944e+11
        llamaswap_memory_used_bytes 1.37438953472e+11
        llamaswap_gpu_util_percent 5.0
        llamaswap_gpu_memory_used_bytes 1.992618e+07
        llamaswap_gpu_memory_total_bytes 2.74877906944e+11
        llamaswap_load_average 4.2
        """

    func testPrometheusParsing() {
        let parsed = LlamaSwapDecoding.prometheus(from: prometheus)
        XCTAssertEqual(parsed.gauges["llamaswap_gpu_util_percent"], 5.0)
        XCTAssertEqual(parsed.gauges["llamaswap_load_average"], 4.2)
        XCTAssertEqual(parsed.gauges["llamaswap_memory_total_bytes"], 274_877_906_944)
        XCTAssertEqual(parsed.cpuCores, [10.0, 30.0])
    }

    func testSummaryMapsLlamaSwapFields() throws {
        let summary = try LlamaSwapDecoding.summary(
            performance: performance, stats: stats, activity: activity,
            prometheus: Data(prometheus.utf8), host: "sirius.example.ts.net")
        XCTAssertEqual(summary.id, "sirius.example.ts.net")
        XCTAssertEqual(summary.name, "sirius")
        XCTAssertEqual(summary.roleLabel, "HOST")
        XCTAssertTrue(summary.online)
        XCTAssertEqual(summary.gpuChip, "Apple M5 Ultra (80-core GPU)")
        XCTAssertEqual(summary.usage, 87.25)  // newest sample wins
        XCTAssertEqual(summary.temperature, 0)  // Apple Silicon reports none
        XCTAssertEqual(summary.vramUsedMB, 232_000)
        XCTAssertEqual(summary.vramTotalMB, 262_144)
        XCTAssertEqual(summary.cpuUsage, 20)
        XCTAssertEqual(summary.memUsedMB, 131_072)
        XCTAssertEqual(summary.memTotalMB, 262_144)
        XCTAssertEqual(summary.oomRisk, "low")  // 131072 / 262144 = 0.5
        XCTAssertEqual(summary.backend, "llama-swap")
        XCTAssertEqual(summary.model, "glm-5.3-flash")
        XCTAssertEqual(summary.totalOutputTokens, 23_809)
        // Entry 103 has no reported tps: 111 tokens / 1.385 s ≈ 80.1; entry 102 reports 62.5.
        XCTAssertEqual(summary.generationTps, (111.0 / 1.385 + 62.5) / 2, accuracy: 0.01)
        XCTAssertEqual(summary.prefillTps, 950.5)
    }

    func testSummaryFallsBackToPrometheusGPU() throws {
        let summary = try LlamaSwapDecoding.summary(
            performance: nil, stats: nil, activity: nil, prometheus: Data(prometheus.utf8),
            host: "100.64.0.1")
        XCTAssertEqual(summary.name, "100.64.0.1")  // IP addresses are not shortened
        XCTAssertEqual(summary.usage, 5.0)
        XCTAssertEqual(summary.vramUsedMB, 19.0, accuracy: 0.5)
        XCTAssertEqual(summary.vramTotalMB, 262_144, accuracy: 1)
        XCTAssertEqual(summary.generationTps, 0)
    }

    func testSummaryRequiresAtLeastOneSource() {
        XCTAssertThrowsError(
            try LlamaSwapDecoding.summary(
                performance: nil, stats: nil, activity: nil, prometheus: nil, host: "sirius")
        ) { error in
            XCTAssertEqual(error as? SparkDashError, .invalidResponse)
        }
    }

    func testEffectiveTpsFallsBackToDuration() {
        let entry = LlamaSwapActivity(outputTokens: 200, tokensPerSecond: -1, durationMs: 4_000)
        XCTAssertEqual(LlamaSwapDecoding.effectiveTps(entry), 50)
        XCTAssertNil(LlamaSwapDecoding.effectiveTps(LlamaSwapActivity(outputTokens: 0, durationMs: 4_000)))
    }

    @MainActor
    func testMenuBarOmitsZeroTemperature() {
        let model = FleetViewModel(defaults: UserDefaults(suiteName: "LlamaSwapTests")!, demo: false)
        defer { model.quit(stopApp: false) }
        var spark = SparkSummary()
        spark.id = "sirius"
        spark.online = true
        spark.generationTps = 61.6
        spark.temperature = 0
        model.apply(FleetSnapshot(sparks: [spark]), at: .now)
        XCTAssertEqual(model.menuBarTitle, "1/1  62 t/s")
    }
}
