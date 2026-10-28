@preconcurrency import AVFoundation
import VideoToolbox
import UtsushieCore

enum VideoEncoding {
    /// 小の画質。画面録画の実測で、大に比べて0.65は約1/5、0.75は約1/3の容量だった。
    static let compactQuality = 0.7
    /// 小のキーフレーム間隔(秒)。長いほど小さいが、編集画面のコマ取得とシークが遅くなる。
    static let compactKeyFrameSeconds = 10
    /// AVVideoQualityKeyのH.264での扱いは公開仕様にないため、エンコーダーがVideoToolboxの画質の指定を受け付けるかを確かめる。
    static let supportsQuality: Bool = {
        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: 640, height: 360, codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                         outputCallback: nil, refcon: nil, compressionSessionOut: &session) == noErr,
              let session else { return false }
        defer { VTCompressionSessionInvalidate(session) }
        var supported: CFDictionary?
        guard VTSessionCopySupportedPropertyDictionary(session, supportedPropertyDictionaryOut: &supported) == noErr,
              let properties = supported as? [String: Any] else { return false }
        return properties[kVTCompressionPropertyKey_Quality as String] != nil
    }()

    static func settings(width: Int, height: Int, fps: Int, compression: VideoCompression) -> [String: Any] {
        var properties: [String: Any] = [AVVideoExpectedSourceFrameRateKey: fps, AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel]
        // 画質を指定できないエンコーダーでは、小も大と同じ設定で書く。
        switch supportsQuality ? compression : .standard {
        case .compact:
            // 画面録画の実測では、平均ビットレートの指定より画質一定のほうが静止した画面を小さく書けた。
            // supportsQualityで確かめたVideoToolboxのキーをそのまま渡す。AVVideoQualityKeyも同じ文字列。
            properties[kVTCompressionPropertyKey_Quality as String] = compactQuality
            properties[AVVideoMaxKeyFrameIntervalKey] = fps * compactKeyFrameSeconds
            // VFRでは静止中のコマが少ないため、コマ数だけでなく秒でも間隔を区切る。
            properties[AVVideoMaxKeyFrameIntervalDurationKey] = compactKeyFrameSeconds
        case .standard:
            properties[AVVideoAverageBitRateKey] = min(40_000_000, max(500_000, Int(Double(width * height * fps) * 0.12)))
            properties[AVVideoMaxKeyFrameIntervalKey] = fps * 2
        }
        return [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: properties]
    }
    /// 録画と編集の音。入力の標本化周波数とチャンネル数はwriterが変換する。
    static var audioSettings: [String: Any] { [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                               AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000] }
    /// 読み取りと混ぜ合わせに使う中間の形式。
    static var pcmSettings: [String: Any] { [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000,
                                             AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                             AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false] }
}
