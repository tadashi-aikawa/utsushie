import Foundation
import Darwin

struct PrivacyProcessResult: Sendable {
    let output: Data
    let error: Data
    let status: Int32
}

/// ProcessとPipeはワーカーだけが操作する。キャンセル通知のみロックで共有する。
private final class PrivacyProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.withLock { value = true } }
    var isCancelled: Bool { lock.withLock { value } }
}

enum PrivacyProcess {
    static func run(executable: URL, arguments: [String], deadline: ContinuousClock.Instant) async throws -> PrivacyProcessResult {
        let cancellation = PrivacyProcessCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try execute(executable: executable, arguments: arguments,
                        deadline: deadline, cancellation: cancellation)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private static func execute(executable: URL, arguments: [String], deadline: ContinuousClock.Instant,
                                cancellation: PrivacyProcessCancellation) throws -> PrivacyProcessResult {
        if cancellation.isCancelled { throw CancellationError() }
        guard ContinuousClock.now < deadline else { throw PrivacyDetectionError.timedOut }
        let process = Process()
        process.executableURL = executable; process.arguments = arguments
        // 元画像や保存先、リポジトリを作業ディレクトリとして渡さない。
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CLAUDECODE")
        environment["PATH"] = ([executable.deletingLastPathComponent().path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] + [environment["PATH"] ?? ""]).joined(separator: ":")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let outputPipe = Pipe(), errorPipe = Pipe()
        process.standardOutput = outputPipe; process.standardError = errorPipe
        defer {
            try? outputPipe.fileHandleForReading.close(); try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForReading.close(); try? errorPipe.fileHandleForWriting.close()
        }
        let out = outputPipe.fileHandleForReading.fileDescriptor, err = errorPipe.fileHandleForReading.fileDescriptor
        _ = fcntl(out, F_SETFL, fcntl(out, F_GETFL) | O_NONBLOCK)
        _ = fcntl(err, F_SETFL, fcntl(err, F_GETFL) | O_NONBLOCK)
        do { try process.run() } catch { throw PrivacyDetectionError.launchFailed }
        var output = Data(), error = Data()
        func drain(_ descriptor: Int32, into data: inout Data) {
            var bytes = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
                guard count > 0 else { return }
                // 誤った実行ファイルの無制限出力でもメモリを占有しない。余分な出力も読み捨てる。
                let keep = min(count, max(0, 8 * 1024 * 1024 - data.count))
                data.append(contentsOf: bytes.prefix(keep))
                if cancellation.isCancelled || ContinuousClock.now >= deadline { return }
            }
        }
        while process.isRunning {
            drain(out, into: &output); drain(err, into: &error)
            if cancellation.isCancelled || ContinuousClock.now >= deadline {
                // このProcessのPIDだけを止める。SIGTERMを無視する実行ファイルも残さない。
                process.terminate()
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                if cancellation.isCancelled { throw CancellationError() }
                throw PrivacyDetectionError.timedOut
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        drain(out, into: &output); drain(err, into: &error)
        if cancellation.isCancelled { throw CancellationError() }
        if ContinuousClock.now >= deadline { throw PrivacyDetectionError.timedOut }
        return PrivacyProcessResult(output: output, error: error, status: process.terminationStatus)
    }
}
