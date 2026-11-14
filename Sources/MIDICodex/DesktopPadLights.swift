import Foundation

enum ApprovalLightPhase: String { case idle, on, off }

final class DesktopPadLights {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?

    private struct Reply: Decodable {
        let ok: Bool?
        let error: String?
    }

    private struct LightError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func update(phase: ApprovalLightPhase, white: UInt8, microphone: String, lamp: Int, completionGreen: Bool, warning: Bool, quota: Int, foreground: Bool) throws {
        if process == nil {
            guard let helper = Bundle.main.url(forResource: "padlights", withExtension: nil) else {
                throw LightError(message: "找不到灯光组件。")
            }
            let child = Process()
            let requests = Pipe()
            let replies = Pipe()
            child.executableURL = helper
            child.arguments = ["serve"]
            child.standardInput = requests
            child.standardOutput = replies
            child.standardError = FileHandle.nullDevice
            try child.run()
            process = child
            input = requests.fileHandleForWriting
            output = replies.fileHandleForReading
        }
        try request(["desktop-lights", "--phase", phase.rawValue, "--white", String(white), "--mic", microphone, "--lamp", String(lamp), "--green", completionGreen ? "1" : "0", "--warning", warning ? "1" : "0", "--quota", String(quota), "--foreground", foreground ? "1" : "0"])
    }

    private func request(_ arguments: [String]) throws {
        guard let input, let output, process?.isRunning == true else {
            throw LightError(message: "灯光连接已断开。")
        }
        var encoded = try JSONEncoder().encode(arguments)
        encoded.append(10)
        try input.write(contentsOf: encoded)
        var line = Data()
        while let byte = try output.read(upToCount: 1), !byte.isEmpty {
            if byte.first == 10 {
                let reply = try JSONDecoder().decode(Reply.self, from: line)
                guard reply.ok == true else {
                    throw LightError(message: reply.error ?? "灯光更新失败。")
                }
                return
            }
            line.append(byte)
            if line.count > 8192 { break }
        }
        throw LightError(message: "灯光组件未返回完整结果。")
    }

    func stop() -> String? {
        guard let process else { return nil }
        defer {
            try? input?.close()
            process.waitUntilExit()
            self.process = nil
            input = nil
            output = nil
        }
        do {
            try request(["desktop-restore"])
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
