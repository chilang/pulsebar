import XCTest

@testable import PulseBarApp

final class FleetSourcesTests: XCTestCase {
    private func freshDefaults(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testLoadFallsBackToLegacySingleSourceKeys() {
        let defaults = freshDefaults("FleetSourcesTests.legacy")
        defaults.set("spark-head", forKey: FleetSettings.sshHostKey)
        let sources = FleetSettings.load(from: defaults)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].kind, "sparkdash")
        XCTAssertEqual(sources[0].url, FleetSettings.defaultURL)
        XCTAssertEqual(sources[0].sshHost, "spark-head")
    }

    func testSourcesRoundTripThroughDefaults() {
        let defaults = freshDefaults("FleetSourcesTests.roundtrip")
        let saved = [
            FleetSource(sshHost: "spark-head"),
            FleetSource(kind: "llamaswap", url: "https://sirius.example.ts.net", token: "k"),
        ]
        FleetSettings.save(saved, to: defaults)
        let loaded = FleetSettings.load(from: defaults)
        XCTAssertEqual(loaded.map(\.plist), saved.map(\.plist))
        XCTAssertEqual(loaded[1].label, "sirius")
        XCTAssertEqual(loaded[0].label, "spark-head")
    }

    @MainActor
    func testMergeKeepsWorkingSourcesAndAddsOfflineCardForFailedOne() {
        var spark = SparkSummary()
        spark.id = "a"
        spark.online = true
        spark.llmAvailable = true
        spark.generationTps = 40
        let energy = FleetEnergy(currentWatts: 100)
        let sparks = FleetSource(sshHost: "spark-head")
        let sirius = FleetSource(kind: "llamaswap", url: "https://sirius.example.ts.net")

        let (merged, errors) = FleetViewModel.merge([
            (sparks, .success(FleetSnapshot(sparks: [spark], energy: energy))),
            (sirius, .failure(.init(message: "llama-swap unavailable"))),
        ])
        XCTAssertEqual(merged.sparks.map(\.name), ["Spark", "sirius"])
        XCTAssertEqual(merged.onlineCount, 1)
        XCTAssertEqual(merged.totalCount, 2)
        XCTAssertEqual(merged.energy, energy)
        XCTAssertEqual(errors, ["sirius: llama-swap unavailable"])
        XCTAssertEqual(merged.alerts.map(\.label), ["Host unreachable"])
    }
}
