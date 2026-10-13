@preconcurrency import AVFoundation

/// ドラッグ中の取得を直列化し、待機中のマウス位置は最新の1件だけ残す。
@MainActor
final class VideoBoundaryPreview {
    private let load: (Double) async throws -> CGImage
    private let cancelLoad: () -> Void
    private let show: (CGImage, Double) -> Void
    private let failed: () -> Void
    private var requestedTime: Double?
    private var attemptedTime: Double?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    convenience init(source: URL, show: @escaping (CGImage, Double) -> Void, failed: @escaping () -> Void) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        self.init(load: { try await VideoStillExporter.frame(generator: generator, time: $0) },
            cancelLoad: { generator.cancelAllCGImageGeneration() }, show: show, failed: failed)
    }
    init(load: @escaping (Double) async throws -> CGImage, cancelLoad: @escaping () -> Void,
         show: @escaping (CGImage, Double) -> Void, failed: @escaping () -> Void) {
        self.load = load; self.cancelLoad = cancelLoad; self.show = show; self.failed = failed
    }
    func request(_ time: Double) {
        guard time.isFinite else { return }
        requestedTime = time
        guard task == nil, attemptedTime != time else { return }
        let id = generation
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == id { task = nil } }
            while let time = requestedTime, attemptedTime != time {
                let began = ContinuousClock.now
                do {
                    let image = try await load(time)
                    guard generation == id, !Task.isCancelled else { return }
                    // 取得途中の位置も表示する。毎回破棄すると、連続ドラッグ中は画像が止まる。
                    attemptedTime = time; show(image, time)
                } catch {
                    guard generation == id, !Task.isCancelled else { return }
                    attemptedTime = time; failed()
                }
                // 高頻度の入力でデコードを増やさない。停止した位置も次の巡回で必ず取得する。
                let remaining = Duration.milliseconds(50) - began.duration(to: .now)
                if remaining > .zero {
                    do { try await Task.sleep(for: remaining) } catch { return }
                }
                guard generation == id, !Task.isCancelled else { return }
            }
        }
    }
    func cancel() {
        generation = UUID(); requestedTime = nil; attemptedTime = nil
        task?.cancel(); task = nil; cancelLoad()
    }
}
