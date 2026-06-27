import Darwin
import Foundation
import SwiftVLC

enum DualMonoFilterPipelineEvent: Sendable {
    case audioStateChanged(AudioStreamState)
    case curlExited(status: Int32, reason: Int, stderr: String?)
    case filterExited(status: Int32, reason: Int)
}

@MainActor
final class DualMonoFilterPipeline {
    private let streamURL: String
    private let label: String
    private let config: DualMonoFilterConfig
    private let onEvent: @Sendable (DualMonoFilterPipelineEvent) -> Void
    private var curlProcess: Process?
    private var filterProcess: Process?
    private var filterInputPipe: Pipe?
    private var filterOutputPipe: Pipe?
    private var filterErrorPipe: Pipe?
    private var filterStatusReader: FilterStatusReader?
    private var duplicatedOutputFD: Int32 = -1

    init(
        streamURL: String,
        label: String,
        config: DualMonoFilterConfig,
        onEvent: @escaping @Sendable (DualMonoFilterPipelineEvent) -> Void
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
                "[\(label)] dual mono filter exited status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue)\n",
                stderr
            )
            onEvent(.filterExited(
                status: process.terminationStatus,
                reason: process.terminationReason.rawValue
            ))
        }

        let curlErrorPipe = Pipe()
        let curlProcess = Process()
        curlProcess.executableURL = URL(fileURLWithPath: absolutePath(config.curlPath ?? "/usr/bin/curl"))
        curlProcess.arguments = [
            "--silent",
            "--show-error",
            "--location",
            "--no-buffer",
            streamURL
        ]
        curlProcess.standardOutput = inputPipe
        curlProcess.standardError = curlErrorPipe
        curlProcess.terminationHandler = { [label, onEvent] process in
            inputPipe.fileHandleForWriting.closeFile()
            let errorData = curlErrorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if process.terminationStatus == 23 {
                fputs(
                    "[\(label)] curl exited after downstream closed status=23 reason=\(process.terminationReason.rawValue)\n",
                    stderr
                )
                onEvent(.curlExited(
                    status: process.terminationStatus,
                    reason: process.terminationReason.rawValue,
                    stderr: errorMessage?.isEmpty == false ? errorMessage : nil
                ))
                return
            }

            fputs(
                "[\(label)] curl exited status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue)\n",
                stderr
            )
            if let errorMessage, !errorMessage.isEmpty {
                fputs("[\(label)] curl stderr: \(errorMessage)\n", stderr)
            }
            onEvent(.curlExited(
                status: process.terminationStatus,
                reason: process.terminationReason.rawValue,
                stderr: errorMessage?.isEmpty == false ? errorMessage : nil
            ))
        }

        self.filterProcess = filterProcess
        self.curlProcess = curlProcess
        self.filterErrorPipe = filterErrorPipe
        self.filterStatusReader = filterStatusReader

        do {
            try filterProcess.run()
            filterStatusReader.start(reading: filterErrorPipe.fileHandleForReading)
            try curlProcess.run()
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
        terminate(curlProcess)
        terminate(filterProcess)
        curlProcess = nil
        filterProcess = nil

        filterStatusReader?.stop()
        filterStatusReader = nil
        filterErrorPipe?.fileHandleForReading.closeFile()
        filterErrorPipe = nil

        filterInputPipe?.fileHandleForWriting.closeFile()
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

        if let envPath = ProcessInfo.processInfo.environment["REPLAYCENTER_TS_FILTER_PATH"],
           !envPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return absolutePath(envPath)
        }

        let fileManager = FileManager.default
        let candidates = defaultFilterExecutableCandidates()
        if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return path
        }

        throw NSError(domain: "ReplayCenter.DualMonoFilter", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "ReplayCenterDualMonoFilter not found. Build it with `swift build --product ReplayCenterDualMonoFilter` or set REPLAYCENTER_TS_FILTER_PATH."
        ])
    }

    private func defaultFilterExecutableCandidates() -> [String] {
        let executableName = "ReplayCenterDualMonoFilter"
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

private final class FilterStatusReader: @unchecked Sendable {
    private let label: String
    private let onEvent: @Sendable (DualMonoFilterPipelineEvent) -> Void
    private let lock = NSLock()
    private var buffer = Data()
    private weak var fileHandle: FileHandle?

    init(label: String, onEvent: @escaping @Sendable (DualMonoFilterPipelineEvent) -> Void) {
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

        guard let rawState = fields["audioState"],
              let state = AudioStreamState(rawValue: rawState) else {
            fputs("[\(label)] ignored filter status line: \(line)\n", stderr)
            return
        }

        onEvent(.audioStateChanged(state))
    }
}

private extension AudioMode {
    var signal: Int32 {
        switch self {
        case .stereo:
            return SIGHUP
        case .left:
            return SIGUSR1
        case .right:
            return SIGUSR2
        }
    }
}
