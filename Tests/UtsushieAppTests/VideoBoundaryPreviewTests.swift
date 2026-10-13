import AppKit
import Testing
@testable import Utsushie

@MainActor private final class BoundaryFrameLoader {
    var times: [Double] = []
    var continuations: [CheckedContinuation<CGImage, any Error>] = []
    var cancellations = 0
    func load(_ time: Double) async throws -> CGImage {
        times.append(time)
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }
}
@MainActor private func waitForBoundary(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try #require(condition())
}
@MainActor private func boundaryTestImage() throws -> CGImage {
    let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return try #require(context.makeImage())
}

@MainActor @Test func boundaryPreviewCoalescesPendingPositionsAndStillDisplaysDuringContinuousDrag() async throws {
    let loader = BoundaryFrameLoader(), image = try boundaryTestImage()
    var shown: [Double] = []
    let preview = VideoBoundaryPreview(load: loader.load, cancelLoad: { loader.cancellations += 1 },
        show: { _, time in shown.append(time) }, failed: { Issue.record("取得に失敗") })
    defer { preview.cancel() }
    preview.request(1)
    try await waitForBoundary { loader.times == [1] }
    for time in 2...100 { preview.request(Double(time)) }
    #expect(loader.times == [1])
    loader.continuations[0].resume(returning: image)
    try await waitForBoundary { loader.times.count == 2 }
    #expect(shown == [1] && loader.times == [1, 100])
    loader.continuations[1].resume(returning: image)
    try await waitForBoundary { shown == [1, 100] }
    preview.request(100)
    try await Task.sleep(for: .milliseconds(80))
    #expect(loader.times == [1, 100])
}

@MainActor @Test func boundaryPreviewRejectsLateResultsAfterCancellationAndNewDrag() async throws {
    let loader = BoundaryFrameLoader(), image = try boundaryTestImage()
    var shown: [Double] = []
    let preview = VideoBoundaryPreview(load: loader.load, cancelLoad: { loader.cancellations += 1 },
        show: { _, time in shown.append(time) }, failed: { Issue.record("取得に失敗") })
    defer { preview.cancel() }
    preview.request(1)
    try await waitForBoundary { loader.times.count == 1 }
    preview.cancel(); preview.request(2)
    try await waitForBoundary { loader.times.count == 2 }
    loader.continuations[0].resume(returning: image)
    loader.continuations[1].resume(returning: image)
    try await waitForBoundary { shown == [2] }
    #expect(loader.cancellations == 1)
}

@MainActor @Test func boundaryPreviewContinuesToLatestPositionAfterReadFailure() async throws {
    let loader = BoundaryFrameLoader(), image = try boundaryTestImage()
    var shown: [Double] = [], failures = 0
    let preview = VideoBoundaryPreview(load: loader.load, cancelLoad: {},
        show: { _, time in shown.append(time) }, failed: { failures += 1 })
    defer { preview.cancel() }
    preview.request(1)
    try await waitForBoundary { loader.times.count == 1 }
    preview.request(2)
    loader.continuations[0].resume(throwing: CocoaError(.fileReadUnknown))
    try await waitForBoundary { loader.times.count == 2 }
    loader.continuations[1].resume(returning: image)
    try await waitForBoundary { shown == [2] }
    #expect(failures == 1)
}
