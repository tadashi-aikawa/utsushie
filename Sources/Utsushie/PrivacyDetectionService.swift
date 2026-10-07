import Foundation
import CoreGraphics
import Vision
import OSLog
import UtsushieCore

/// 診断の境界は処理名と秒数だけ。認識した文字やCLIの入出力は受け取らない。
struct PrivacyDiagnostics: Sendable {
    enum Stage: String, Sendable { case textRecognition, claudeSearch, claudeExecution }
    private static let log = Logger(subsystem: "com.tadashi-aikawa.utsushie", category: "Privacy")
    var record: @Sendable (Stage, Double) -> Void = { stage, seconds in
        log.debug("\(stage.rawValue, privacy: .public): elapsedSeconds=\(seconds)")
    }
    func elapsed(_ stage: Stage, since start: ContinuousClock.Instant) {
        let duration = start.duration(to: .now).components
        record(stage, Double(duration.seconds) + Double(duration.attoseconds) / 1e18)
    }
    func measure<Result>(_ stage: Stage, operation: () async throws -> Result) async rethrows -> Result {
        let start = ContinuousClock.now
        defer { elapsed(stage, since: start) }
        return try await operation()
    }
}

struct PrivacyRecognition: Sendable {
    var lines: [PrivacyTextLine] = []
    var faces: [CGRect] = []
    var warning: String?
}

struct PrivacyDetectionResult: Sendable {
    let annotations: [Annotation]
    let warning: String?
    var message: String {
        let result = annotations.isEmpty ? "隠す箇所は見つかりませんでした" : "\(annotations.count) か所にモザイクを入れました"
        guard let warning else { return result }
        return annotations.isEmpty ? warning : "\(warning) ・ \(result)"
    }
}

/// Visionへ渡すのは撮影時の元画像。Claudeへ渡す境界は文字の行だけに限定する。
struct PrivacyDetectionService: Sendable {
    var recognize: @Sendable (CGImage) async throws -> PrivacyRecognition = { try await PrivacyVision.recognize($0) }
    var select: @Sendable ([PrivacyTextLine], PrivacyConfig) async throws -> Data = { lines, config in
        try await ClaudePrivacyClient.select(lines: lines, config: config)
    }

    func detect(image: CGImage, config: PrivacyConfig) async throws -> PrivacyDetectionResult {
        let recognized = try await recognize(image)
        try Task.checkCancellation()
        var rectangles = recognized.faces
        var warning = recognized.warning
        if !recognized.lines.isEmpty {
            do {
                let response = try await select(recognized.lines, config)
                try Task.checkCancellation()
                rectangles += try PrivacySelection.rectangles(response: response, lines: recognized.lines)
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                warning = (error as? PrivacyDetectionError)?.localizedDescription ?? "AIの応答を読み取れませんでした"
            }
        }
        try Task.checkCancellation()
        return PrivacyDetectionResult(annotations: PrivacyGeometry.mosaics(rectangles: rectangles,
            imageSize: CGSize(width: image.width, height: image.height)), warning: warning)
    }
}

enum PrivacyVision {
    private static let queue = DispatchQueue(label: "com.tadashi-aikawa.utsushie.privacy-vision", qos: .userInitiated)

    static func recognize(_ image: CGImage, diagnostics: PrivacyDiagnostics = PrivacyDiagnostics()) async throws -> PrivacyRecognition {
        // Visionの内部の同期待ちでSwiftの協調スレッドを塞がない。
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try recognizeSynchronously(image, diagnostics: diagnostics)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func recognizeSynchronously(_ image: CGImage, diagnostics: PrivacyDiagnostics) throws -> PrivacyRecognition {
        let size = CGSize(width: image.width, height: image.height)
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        var result = PrivacyRecognition()
        let faces = VNDetectFaceRectanglesRequest()
        do {
            try handler.perform([faces])
            result.faces = (faces.results ?? []).map { PrivacyGeometry.imageRect(normalized: $0.boundingBox, imageSize: size) }
        } catch { result.warning = "顔を検出できませんでした" }
        let textStart = ContinuousClock.now
        defer { diagnostics.elapsed(.textRecognition, since: textStart) }
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.recognitionLanguages = ["ja-JP", "en-US"]
        text.usesLanguageCorrection = true
        do {
            try handler.perform([text])
            result.lines = (text.results ?? []).compactMap { observation -> (String, CGRect)? in
                guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
                return (candidate.string, PrivacyGeometry.imageRect(normalized: observation.boundingBox, imageSize: size))
            }.enumerated().map { index, line in PrivacyTextLine(id: index + 1, text: line.0, rect: line.1) }
        } catch { result.warning = "文字を認識できませんでした" }
        return result
    }
}

enum PrivacyDetectionError: Error, LocalizedError {
    case notFound, launchFailed, authentication, failed, timedOut
    var errorDescription: String? {
        switch self {
        case .notFound: "Claudeが見つかりません。設定のprivacy.claudeを確認してください"
        case .launchFailed: "Claudeを起動できませんでした"
        case .authentication: "Claudeにログインしてください"
        case .failed: "Claudeの実行に失敗しました"
        case .timedOut: "Claudeの応答が60秒以内に届きませんでした"
        }
    }
}

enum ClaudePrivacyClient {
    typealias Run = @Sendable (URL, [String], ContinuousClock.Instant) async throws -> PrivacyProcessResult
    static func select(lines: [PrivacyTextLine], config: PrivacyConfig,
                       run: Run = PrivacyProcess.run,
                       isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                       home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                       diagnostics: PrivacyDiagnostics = PrivacyDiagnostics()) async throws -> Data {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        let executable = try await diagnostics.measure(.claudeSearch) {
            var executable = ClaudeExecutableSearch.firstExecutable(configured: config.claude, home: home,
                isExecutable: isExecutable)
            if executable == nil, config.claude.isEmpty {
                let result = try await run(URL(fileURLWithPath: shell), ["-lc", "command -v claude"], deadline)
                let path = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if result.status == 0, path.hasPrefix("/"), isExecutable(path) {
                    executable = URL(fileURLWithPath: path)
                }
            }
            guard let executable else { throw PrivacyDetectionError.notFound }
            return executable
        }
        let prompt = try PrivacySelection.prompt(lines: lines)
        let result = try await diagnostics.measure(.claudeExecution) {
            try await run(executable,
                ["-p", prompt, "--model", config.model, "--effort", config.effort, "--output-format", "json", "--json-schema", PrivacySelection.schema,
                 "--no-session-persistence", "--tools", "", "--setting-sources", "local"], deadline)
        }
        let object = try? JSONSerialization.jsonObject(with: result.output) as? [String: Any]
        if result.status != 0 || object?["is_error"] as? Bool == true {
            // CLIの生出力には認識した秘密情報が含まれうるため、UIやログへ転記しない。
            let output = String(decoding: result.output + result.error, as: UTF8.self).lowercased()
            if ["not logged in", "please log in", "please login", "authentication", "unauthorized", "invalid api key", "/login"].contains(where: output.contains) {
                throw PrivacyDetectionError.authentication
            }
            throw PrivacyDetectionError.failed
        }
        return result.output
    }
}
