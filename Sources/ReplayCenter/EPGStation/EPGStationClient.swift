import Foundation

struct EPGStationClient {
    let baseURL: URL
    var session: URLSession = .shared

    init(baseURL: URL) {
        let text = baseURL.absoluteString
        self.baseURL = text.hasSuffix("/") ? baseURL : URL(string: text + "/")!
    }

    func fetchChannels() async throws -> [EPGStationChannel] {
        try await get("api/channels")
    }

    func fetchBroadcastingSchedules() async throws -> [BroadcastingSchedule] {
        try await get("api/schedules/broadcasting", queryItems: [
            URLQueryItem(name: "isHalfWidth", value: "false")
        ])
    }

    func fetchConfig() async throws -> EPGStationConfig {
        try await get("api/config")
    }

    func liveStreamURL(
        channelID: Int,
        container: LiveStreamContainer = .m2ts,
        mode: Int? = 0
    ) -> URL {
        var components = URLComponents(
            url: appendingPath("api/streams/live/\(channelID)/\(container.rawValue)"),
            resolvingAgainstBaseURL: false
        )!
        if let mode {
            components.queryItems = [URLQueryItem(name: "mode", value: String(mode))]
        }
        return components.url!
    }

    private func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        var components = URLComponents(url: appendingPath(path), resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems.isEmpty ? nil : queryItems

        let (data, response) = try await session.data(from: components.url!)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw EPGStationClientError.unexpectedStatusCode(httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(T.self, from: data)
    }

    private func appendingPath(_ path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }
}

enum EPGStationClientError: Error, LocalizedError {
    case unexpectedStatusCode(Int)

    var errorDescription: String? {
        switch self {
        case let .unexpectedStatusCode(statusCode):
            return "EPGStation API returned HTTP \(statusCode)."
        }
    }
}
