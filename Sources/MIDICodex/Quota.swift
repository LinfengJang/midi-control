import Foundation
import Darwin

struct LimitWindow: Codable, Equatable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
    var remaining: Double { max(0, min(100, 100 - usedPercent)) }
    var reset: Date? { resetsAt.map { Date(timeIntervalSince1970: $0) } }
}
struct Limits: Codable, Equatable {
    let primary: LimitWindow?
    let secondary: LimitWindow?
    var fiveHour: LimitWindow? { [primary, secondary].compactMap { $0 }.first { $0.windowDurationMins == 300 } }
    var weekly: LimitWindow? { [primary, secondary].compactMap { $0 }.first { $0.windowDurationMins == 10080 } }
}
struct LimitsResponse: Decodable {
    let rateLimits: Limits
    let rateLimitsByLimitId: [String: Limits]?
    var codex: Limits { rateLimitsByLimitId?["codex"] ?? rateLimits }
}

struct CLIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private struct RPCReply: Decodable {
    let id: Int?
    let hasError: Bool
    let limits: Limits?
    enum CodingKeys: String, CodingKey { case id, error, result }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try? values.decode(Int.self, forKey: .id)
        hasError = values.contains(.error) && ((try? values.decodeNil(forKey: .error)) != true)
        if id == 2 && !hasError && values.contains(.result) {
            limits = try values.decode(LimitsResponse.self, forKey: .result).codex
        } else { limits = nil }
    }
}

enum CLIClient {
    static func locate() -> String? {
        let configured = UserDefaults.standard.string(forKey: "cliPath") ?? ""
        return [ProcessInfo.processInfo.environment["CODEX_QUOTA_CLI"] ?? "", configured, "/opt/homebrew/bin/codex", "/usr/local/bin/codex", NSHomeDirectory() + "/.npm-global/bin/codex", "/Applications/Codex.app/Contents/Resources/codex"].first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }
    // Runs on a worker queue; bounded lifetime; stdio only, no listening network port.
    static func read(executable: String? = nil, timeoutSeconds: TimeInterval = 20, shouldCancel: () -> Bool = { false }) throws -> Limits {
        guard let path = executable ?? locate() else { throw CLIError(message: "Codex CLI not found. Install it or configure its executable path.") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["app-server", "--listen", "stdio://"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice // Never persist server logs or authentication material.
        try process.run()
        let deadline = ProcessInfo.processInfo.systemUptime + timeoutSeconds
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                let end = ProcessInfo.processInfo.systemUptime + 0.2
                while process.isRunning && ProcessInfo.processInfo.systemUptime < end { usleep(10_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "midi_codex_quota", "version": "1.0.0"]]])
        var buffer = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        let decoder = JSONDecoder()
        while true {
            if shouldCancel() { throw CancellationError() }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { throw CLIError(message: "The quota request timed out. Try again later.") }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 250)))
            if ready < 0 && errno == EINTR { continue }
            if ready == 0 { continue }
            if ready < 0 { throw CLIError(message: "Unable to wait for the CLI response.") }
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { throw CLIError(message: "The CLI connection ended or timed out. Confirm Codex is signed in and retry.") }
            buffer.append(contentsOf: bytes.prefix(count))
            if buffer.count > 4_000_000 { throw CLIError(message: "The CLI response exceeded the size limit.") }
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let reply = try? decoder.decode(RPCReply.self, from: line), let id = reply.id else { continue }
                if reply.hasError { throw CLIError(message: "The quota request failed. Check codex login status. API-key accounts may not expose subscription quota.") }
                if id == 1 {
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read", "params": ["excludeResetCreditDetails": true]])
                } else if id == 2, let limits = reply.limits { return limits }
            }
        }
    }
}
