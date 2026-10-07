import Testing

/// CIで実行の再開が遅れても、状態変化を待つテストの短い期限で失敗させない。
@discardableResult
func waitUntil(_ message: Comment, timeout: Duration = .seconds(30),
               isolation: isolated (any Actor)? = #isolation,
               sourceLocation: SourceLocation = #_sourceLocation,
               condition: () async throws -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while try await !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record(message, sourceLocation: sourceLocation)
            return false
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    return true
}
