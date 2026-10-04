@preconcurrency import AVFoundation

enum VideoEncoding {
    static func settings(width: Int, height: Int, fps: Int) -> [String: Any] {
        [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
         AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: min(40_000_000, max(500_000, Int(Double(width * height * fps) * 0.12))),
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
         ]]
    }
}
