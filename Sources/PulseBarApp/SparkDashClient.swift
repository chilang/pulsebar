import Foundation

/// Polls the sparkDash REST API: `/api/sparks`, `/api/sparks/:id/metrics`, `/api/fleet-energy`.
struct SparkDashClient: Sendable {
    var baseURL: URL
    var token: String?
    var session: URLSession = .shared

    func fetchFleet() async throws -> FleetSnapshot {
        let ids = try SparkDashDecoding.sparkIDs(from: try await get("api/sparks"))
        var sparks: [SparkSummary] = []
        for id in ids {
            let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? id
            sparks.append(try SparkDashDecoding.summary(from: try await get("api/sparks/\(encoded)/metrics")))
        }
        let energy = try? SparkDashDecoding.energy(from: try await get("api/fleet-energy"))
        return FleetSnapshot(sparks: sparks, energy: energy)
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
