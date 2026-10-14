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
    /// 録画と編集の音。入力の標本化周波数とチャンネル数はwriterが変換する。
    static var audioSettings: [String: Any] { [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                               AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000] }
    /// 読み取りと混ぜ合わせに使う中間の形式。
    static var pcmSettings: [String: Any] { [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                                             AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                             AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false] }
}
