import Foundation
import Testing
import UtsushieCore

@Test func recentCapturesExcludeHiddenTemporaryDirectoriesAndOtherFormats() {
    let date = Date(timeIntervalSince1970: 0)
    let files = ["one.webp", "two.MP4", ".original.mp4", ".writing.webp", "pending.recording.mp4", "three.png", "four.webp.tmp"]
        .map { RecentCaptureFile(url: URL(fileURLWithPath: "/tmp/\($0)"), date: date) }
        + [RecentCaptureFile(url: URL(fileURLWithPath: "/tmp/folder.webp"), date: date, isRegularFile: false),
           RecentCaptureFile(url: URL(fileURLWithPath: "/tmp/hidden.webp"), date: date, isHidden: true)]
    #expect(RecentCaptures.newest(files).map { $0.url.lastPathComponent } == ["two.MP4", "one.webp"])
}

@Test func recentCapturesSortNewestFirstLimitBothFormatsTogetherAndBreakTiesStably() {
    let files = (0..<12).map { index in
        RecentCaptureFile(url: URL(fileURLWithPath: "/tmp/\(index).\(index.isMultiple(of: 2) ? "webp" : "mp4")"),
            date: Date(timeIntervalSince1970: Double(index)))
    }
    let result = RecentCaptures.newest(files.reversed())
    #expect(result.count == 10 && result.map(\.date) == files[2...].reversed().map(\.date))
    let sameDate = files.map { RecentCaptureFile(url: $0.url, date: Date(timeIntervalSince1970: 0)) }
    #expect(RecentCaptures.newest(sameDate) == RecentCaptures.newest(sameDate.reversed()))
}

@Test func recentCaptureTitlesUseLocalClockAndImagePixelsOrMovieDuration() {
    let zone = TimeZone(secondsFromGMT: 9 * 3600)!
    let image = RecentCaptureFile(url: URL(fileURLWithPath: "/tmp/image.webp"), date: Date(timeIntervalSince1970: 0))
    let video = RecentCaptureFile(url: URL(fileURLWithPath: "/tmp/video.mp4"), date: image.date)
    #expect(RecentCaptures.title(file: image, width: 960, height: 600, timeZone: zone) == "09:00 WebP 960×600")
    #expect(RecentCaptures.title(file: video, width: 960, height: 600, duration: 12.9, timeZone: zone) == "09:00 MP4 0:12")
    #expect(RecentCaptures.title(file: video, width: 0, height: 0, duration: .nan, timeZone: zone) == "09:00 MP4 0:00")
    #expect(RecentCaptures.title(file: video, width: 0, height: 0, duration: 65, timeZone: zone) == "09:00 MP4 1:05")
}
