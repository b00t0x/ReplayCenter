import Darwin
import Foundation
import SwiftVLC

enum StreamFilterPipelineEvent: Sendable {
    case audioStateChanged(AudioStreamState)
    case broadcastClockChanged(BroadcastClockState)
    case eventRelayChanged(EventRelayCandidate?)
    case streamInputEnded(error: String?)
    case filterExited(status: Int32, reason: Int)
}

struct BroadcastClockState: Equatable, Sendable {
    let date: Date
    let receivedAt: Date
    let table: String?

    var delaySeconds: TimeInterval {
        receivedAt.timeIntervalSince(date)
    }
}

struct EventRelayCandidate: Equatable, Sendable {
    let groupType: Int
    let sourceNetworkId: Int
    let sourceTransportStreamId: Int
    let sourceServiceId: Int
    let sourceEventId: Int
    let targetNetworkId: Int
    let targetTransportStreamId: Int
    let targetServiceId: Int
    let targetEventId: Int

    var debugText: String {
        "relay group=\(hex(groupType)) \(hex(sourceNetworkId))/\(hex(sourceTransportStreamId))/\(hex(sourceServiceId))/\(hex(sourceEventId)) -> \(hex(targetNetworkId))/\(hex(targetTransportStreamId))/\(hex(targetServiceId))/\(hex(targetEventId))"
    }

    private func hex(_ value: Int) -> String {
        "0x" + String(value, radix: 16)
    }
}

@MainActor
final class StreamFilterPipeline {
    private let streamURL: String
    private let label: String
    private let config: StreamFilterConfig
    private let onEvent: @Sendable (StreamFilterPipelineEvent) -> Void
    private var streamPump: HTTPStreamPump?
    private var filterProcess: Process?
    private var filterInputPipe: Pipe?
    private var filterOutputPipe: Pipe?
    private var filterErrorPipe: Pipe?
    private var filterStatusReader: FilterStatusReader?
    private var duplicatedOutputFD: Int32 = -1

    init(
        streamURL: String,
        label: String,
        config: StreamFilterConfig,
        onEvent: @escaping @Sendable (StreamFilterPipelineEvent) -> Void
    ) {
        self.streamURL = streamURL
        self.label = label
        self.config = config
        self.onEvent = onEvent
    }

    func start(initialMode: AudioMode) throws -> Media {
        stop()

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        filterInputPipe = inputPipe
        filterOutputPipe = outputPipe

        let filterProcess = Process()
        filterProcess.executableURL = URL(fileURLWithPath: try filterExecutablePath())
        filterProcess.arguments = [
            "--mode",
            initialMode.rawValue,
            "--mux-selected-to-stereo",
            config.effectiveMuxSelectedToStereo ? "true" : "false"
        ]
        filterProcess.standardInput = inputPipe
        filterProcess.standardOutput = outputPipe
        let filterErrorPipe = Pipe()
        let filterStatusReader = FilterStatusReader(label: label, onEvent: onEvent)
        filterProcess.standardError = filterErrorPipe
        let onEvent = onEvent
        filterProcess.terminationHandler = { [label, onEvent] process in
            fputs(
                "[\(label)] stream filter exited status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue)\n",
                stderr
            )
            onEvent(.filterExited(
                status: process.terminationStatus,
                reason: process.terminationReason.rawValue
            ))
        }

        guard let url = URL(string: streamURL) else {
            throw NSError(domain: "ReplayCenter.StreamInput", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "invalid stream url: \(streamURL)"
            ])
        }
        let streamPump = HTTPStreamPump(
            url: url,
            label: label,
            outputFileHandle: inputPipe.fileHandleForWriting,
            onEvent: onEvent
        )

        self.filterProcess = filterProcess
        self.streamPump = streamPump
        self.filterErrorPipe = filterErrorPipe
        self.filterStatusReader = filterStatusReader

        do {
            try filterProcess.run()
            filterStatusReader.start(reading: filterErrorPipe.fileHandleForReading)
            streamPump.start()
        } catch {
            stop()
            throw error
        }

        duplicatedOutputFD = dup(outputPipe.fileHandleForReading.fileDescriptor)
        guard duplicatedOutputFD >= 0 else {
            stop()
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "dup(filter stdout fd) failed"
            ])
        }

        return try Media(fileDescriptor: Int(duplicatedOutputFD))
    }

    func setAudioMode(_ mode: AudioMode) {
        guard let filterProcess, filterProcess.isRunning else { return }
        kill(filterProcess.processIdentifier, mode.signal)
    }

    func stop() {
        let streamPump = streamPump
        streamPump?.stop()
        terminate(filterProcess)
        self.streamPump = nil
        filterProcess = nil

        filterStatusReader?.stop()
        filterStatusReader = nil
        filterErrorPipe?.fileHandleForReading.closeFile()
        filterErrorPipe = nil

        if streamPump == nil {
            filterInputPipe?.fileHandleForWriting.closeFile()
        }
        filterInputPipe?.fileHandleForReading.closeFile()
        filterInputPipe = nil
        filterOutputPipe = nil

        if duplicatedOutputFD >= 0 {
            close(duplicatedOutputFD)
            duplicatedOutputFD = -1
        }
    }

    private func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    private func filterExecutablePath() throws -> String {
        if let configuredPath = config.filterPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredPath.isEmpty {
            return absolutePath(configuredPath)
        }

        if let envPath = ProcessInfo.processInfo.environment["REPLAYCENTER_STREAM_FILTER_PATH"],
           !envPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return absolutePath(envPath)
        }

        let fileManager = FileManager.default
        let candidates = defaultFilterExecutableCandidates()
        if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return path
        }

        throw NSError(domain: "ReplayCenter.StreamFilter", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "ReplayCenterStreamFilter not found. Build it with `swift build --product ReplayCenterStreamFilter` or set REPLAYCENTER_STREAM_FILTER_PATH."
        ])
    }

    private func defaultFilterExecutableCandidates() -> [String] {
        let executableName = "ReplayCenterStreamFilter"
        var candidates: [String] = []

        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executableDirectory.appendingPathComponent(executableName).path)
        }

        let cwd = FileManager.default.currentDirectoryPath
        candidates.append(URL(fileURLWithPath: cwd).appendingPathComponent(".build/debug/\(executableName)").path)
        candidates.append(URL(fileURLWithPath: cwd).appendingPathComponent(".build/release/\(executableName)").path)

        return candidates
    }
}

private func absolutePath(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    guard !expanded.hasPrefix("/") else { return expanded }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(expanded)
        .standardized
        .path
}

private final class HTTPStreamPump: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let label: String
    private let outputFileHandle: FileHandle
    private let onEvent: @Sendable (StreamFilterPipelineEvent) -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var isStopped = false
    private var hasClosedOutput = false
    private var responseError: String?

    init(
        url: URL,
        label: String,
        outputFileHandle: FileHandle,
        onEvent: @escaping @Sendable (StreamFilterPipelineEvent) -> Void
    ) {
        self.url = url
        self.label = label
        self.outputFileHandle = outputFileHandle
        self.onEvent = onEvent
    }

    func start() {
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 0
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        lock.lock()
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    func stop() {
        lock.lock()
        isStopped = true
        let task = task
        let session = session
        lock.unlock()

        task?.cancel()
        session?.invalidateAndCancel()
        closeOutput()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let httpResponse = response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            responseError = "HTTP \(httpResponse.statusCode)"
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard write(data) else {
            stop()
            return
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let stopped = isStoppedState
        closeOutput()
        session.finishTasksAndInvalidate()

        guard !stopped else { return }
        let message = responseError ?? normalizedErrorMessage(error)
        if let message {
            fputs("[\(label)] stream input ended error=\(message)\n", stderr)
        } else {
            fputs("[\(label)] stream input ended\n", stderr)
        }
        onEvent(.streamInputEnded(error: message))
    }

    private var isStoppedState: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isStopped
    }

    private func write(_ data: Data) -> Bool {
        let fileDescriptor = outputFileHandle.fileDescriptor
        return data.withUnsafeBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress else { return true }
            var offset = 0
            while offset < data.count {
                let bytesWritten = Darwin.write(
                    fileDescriptor,
                    baseAddress.advanced(by: offset),
                    data.count - offset
                )
                if bytesWritten > 0 {
                    offset += bytesWritten
                    continue
                }
                if bytesWritten < 0 && errno == EINTR {
                    continue
                }
                return false
            }
            return true
        }
    }

    private func closeOutput() {
        lock.lock()
        guard !hasClosedOutput else {
            lock.unlock()
            return
        }
        hasClosedOutput = true
        lock.unlock()
        outputFileHandle.closeFile()
    }

    private func normalizedErrorMessage(_ error: Error?) -> String? {
        guard let error else { return nil }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return responseError
        }
        return error.localizedDescription
    }
}

private final class FilterStatusReader: @unchecked Sendable {
    private let label: String
    private let onEvent: @Sendable (StreamFilterPipelineEvent) -> Void
    private let lock = NSLock()
    private var buffer = Data()
    private weak var fileHandle: FileHandle?

    init(label: String, onEvent: @escaping @Sendable (StreamFilterPipelineEvent) -> Void) {
        self.label = label
        self.onEvent = onEvent
    }

    func start(reading fileHandle: FileHandle) {
        self.fileHandle = fileHandle
        fileHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            FileHandle.standardError.write(data)
            self?.consume(data)
        }
    }

    func stop() {
        fileHandle?.readabilityHandler = nil
        fileHandle = nil
    }

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)

        while let newlineIndex = buffer.firstIndex(of: 0x0a) {
            let lineData = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)
            parseLine(String(decoding: lineData, as: UTF8.self))
        }

        lock.unlock()
    }

    private func parseLine(_ line: String) {
        let prefix = "[filter-status] "
        guard line.hasPrefix(prefix) else { return }

        let fields = line
            .dropFirst(prefix.count)
            .split(separator: " ")
            .reduce(into: [String: String]()) { result, field in
                let parts = field.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { return }
                result[String(parts[0])] = String(parts[1])
            }

        if let rawState = fields["audioState"],
           let state = AudioStreamState(rawValue: rawState) {
            onEvent(.audioStateChanged(state))
            return
        }

        if let clock = fields["clock"],
           let date = Self.clockDate(from: clock) {
            onEvent(.broadcastClockChanged(BroadcastClockState(
                date: date,
                receivedAt: Date(),
                table: fields["table"]
            )))
            return
        }

        if let relay = fields["relay"] {
            if relay == "none" {
                onEvent(.eventRelayChanged(nil))
                return
            }
            if relay == "event", let candidate = Self.eventRelayCandidate(from: fields) {
                onEvent(.eventRelayChanged(candidate))
                return
            }
        }

        if fields["audioState"] != nil || fields["clock"] != nil || fields["relay"] != nil {
            fputs("[\(label)] ignored filter status line: \(line)\n", stderr)
        }
    }

    private static func eventRelayCandidate(from fields: [String: String]) -> EventRelayCandidate? {
        guard let groupType = intValue(fields["group"]),
              let sourceNetworkId = intValue(fields["sourceNid"]),
              let sourceTransportStreamId = intValue(fields["sourceTsid"]),
              let sourceServiceId = intValue(fields["sourceSid"]),
              let sourceEventId = intValue(fields["sourceEid"]),
              let targetNetworkId = intValue(fields["targetNid"]),
              let targetTransportStreamId = intValue(fields["targetTsid"]),
              let targetServiceId = intValue(fields["targetSid"]),
              let targetEventId = intValue(fields["targetEid"])
        else {
            return nil
        }

        return EventRelayCandidate(
            groupType: groupType,
            sourceNetworkId: sourceNetworkId,
            sourceTransportStreamId: sourceTransportStreamId,
            sourceServiceId: sourceServiceId,
            sourceEventId: sourceEventId,
            targetNetworkId: targetNetworkId,
            targetTransportStreamId: targetTransportStreamId,
            targetServiceId: targetServiceId,
            targetEventId: targetEventId
        )
    }

    private static func intValue(_ value: String?) -> Int? {
        guard let value else { return nil }
        if value.hasPrefix("0x") || value.hasPrefix("0X") {
            return Int(value.dropFirst(2), radix: 16)
        }
        return Int(value)
    }

    private static func clockDate(from value: String) -> Date? {
        guard value.count == 19 else { return nil }
        let yearText = value.prefix(4)
        let monthText = value.dropFirst(5).prefix(2)
        let dayText = value.dropFirst(8).prefix(2)
        let hourText = value.dropFirst(11).prefix(2)
        let minuteText = value.dropFirst(14).prefix(2)
        let secondText = value.dropFirst(17).prefix(2)
        guard value[value.index(value.startIndex, offsetBy: 4)] == "-",
              value[value.index(value.startIndex, offsetBy: 7)] == "-",
              value[value.index(value.startIndex, offsetBy: 10)] == "T",
              value[value.index(value.startIndex, offsetBy: 13)] == ":",
              value[value.index(value.startIndex, offsetBy: 16)] == ":",
              let year = Int(yearText),
              let month = Int(monthText),
              let day = Int(dayText),
              let hour = Int(hourText),
              let minute = Int(minuteText),
              let second = Int(secondText)
        else {
            return nil
        }

        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.date
    }
}

private extension AudioMode {
    var signal: Int32 {
        switch self {
        case .left:
            return SIGUSR1
        case .right:
            return SIGUSR2
        }
    }
}
