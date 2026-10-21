import AppKit
import UtsushieCore

/// 描くツールのカーソルを、置かれる注釈の見本にする。表示倍率を掛け、描いたときと同じ見た目の大きさにする。
@MainActor
enum AnnotationToolCursor {
    struct Sample: Hashable {
        var tool: AnnotationTool
        var inkColor: InkColor
        var highlighterColor: HighlighterColor
        var darkBackground: Bool
        var size: AnnotationSize
        /// 撮影時の1ptあたりの画素数。
        var scale: Double
        /// 画像1pxあたりの表示pt。
        var displayScale: Double
        var number: Int
        var backingScale: Double
        /// アクセシビリティのポインタの大きさ。OSはカーソルの画像もこの倍率で引き伸ばす。
        var cursorScale: Double
    }
    /// 読めなければ等倍。設定の範囲は1〜4倍。
    private(set) static var systemCursorScale = readSystemCursorScale()
    /// 他アプリの設定は読み取りがキャッシュされる。マウスの移動ごとではなく、編集画面がキーになったときに同期して読み直す。
    static func reloadSystemCursorScale() {
        CFPreferencesAppSynchronize(accessibilityDomain)
        systemCursorScale = readSystemCursorScale()
    }
    private static let accessibilityDomain = "com.apple.universalaccess" as CFString
    private static func readSystemCursorScale() -> Double {
        let value = CFPreferencesCopyAppValue("mouseDriverCursorSize" as CFString, accessibilityDomain)
        return min(max((value as? NSNumber)?.doubleValue ?? 1, 1), 4)
    }
    /// 縮小しても見本が消えない大きさと、カーソルとして扱える大きさの範囲。単位は表示pt。
    private static let minimumHeight = 12.0
    private static let maximumLength = 256.0
    private static let labelAlpha = 0.55
    private static var cached: (sample: Sample, cursor: NSCursor)?

    static func cursor(_ sample: Sample) -> NSCursor? {
        if let cached, cached.sample == sample { return cached.cursor }
        guard let cursor = make(sample) else { return nil }
        cached = (sample, cursor)
        return cursor
    }

    private static func make(_ sample: Sample) -> NSCursor? {
        let style = AnnotationStyle(size: sample.size, scale: sample.scale)
        let ds = sample.displayScale
        switch sample.tool {
        case .freehand:
            // 線と同じ太さのインクと縁の点。
            var ink = max(style.lineWidth * 1.5 * ds, 3), edge = max(style.edge * ds, 1)
            let fit = min(1, (maximumLength - 2) / (ink + edge * 2))
            ink *= fit; edge *= fit
            let diameter = ink + edge * 2
            let side = ceil(diameter) + 2
            return render(CGSize(width: side, height: side), hotSpot: CGPoint(x: side / 2, y: side / 2), backingScale: sample.backingScale, cursorScale: sample.cursorScale) { context in
                let center = CGPoint(x: side / 2, y: side / 2)
                for (radius, color) in [(diameter / 2, UITheme.inkEdge(sample.inkColor)), (ink / 2, UITheme.ink(sample.inkColor))] {
                    context.setFillColor(color.cgColor)
                    context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                }
            }
        case .highlighter:
            // 線の太さを高さにした細い縦の帯。横へ引いたときに塗られる幅が分かる。
            let height = min(max(style.highlighterWidth * ds, minimumHeight), maximumLength - 2)
            let width = max((height * 0.3).rounded(), 4)
            let canvas = CGSize(width: width + 2, height: height + 2)
            return render(canvas, hotSpot: CGPoint(x: canvas.width / 2, y: canvas.height / 2), backingScale: sample.backingScale, cursorScale: sample.cursorScale) { context in
                let rect = CGRect(x: 1, y: 1, width: width, height: height)
                let path = CGPath(roundedRect: rect, cornerWidth: width * 0.3, cornerHeight: width * 0.3, transform: nil)
                let color = UITheme.highlighter(sample.highlighterColor)
                context.setFillColor((sample.darkBackground ? color.withAlphaComponent(0.75) : color).cgColor)
                context.addPath(path); context.fillPath()
                // 白地でも帯の輪郭が見えるよう、墨の細い線で囲む。
                context.setStrokeColor(UITheme.ink.withAlphaComponent(0.55).cgColor); context.setLineWidth(1)
                context.addPath(path); context.strokePath()
            }
        case .number:
            let annotation = Annotation(tool: .number, start: .zero, inkColor: sample.inkColor, size: sample.size)
            let rect = style.numberRect(at: .zero, number: sample.number)
            // 縁と番号の影の分だけ余白を取る。
            let margin = style.edge + 4 * style.scale
            let content = rect.insetBy(dx: -margin, dy: -margin)
            let factor = min(max(ds, minimumHeight / rect.height), maximumLength / max(content.width, content.height))
            let canvas = CGSize(width: ceil(content.width * factor), height: ceil(content.height * factor))
            let hotSpot = CGPoint(x: -content.minX * factor, y: -content.minY * factor)
            return render(canvas, hotSpot: hotSpot, backingScale: sample.backingScale, cursorScale: sample.cursorScale) { context in
                context.scaleBy(x: factor, y: factor)
                context.translateBy(x: -content.minX, y: -content.minY)
                // 縁と面を1枚にまとめてから透かし、重なった部分だけ濃くならないようにする。
                context.setAlpha(labelAlpha)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                AnnotationRenderer.draw(annotation, number: sample.number, style: style, context: context)
                context.endTransparencyLayer()
            }
        case .selection, .crop, .rectangle, .spotlight, .text, .arrow, .line, .mosaic:
            return nil
        }
    }

    /// 左上原点の表示ptで描き、画面の倍率の画素で持つ。
    /// 画像の寸法はポインタの倍率で割り、OSが引き伸ばした後に表示ptの大きさと画素の細かさへ戻るようにする。
    private static func render(_ size: CGSize, hotSpot: CGPoint, backingScale: Double, cursorScale: Double, draw: (CGContext) -> Void) -> NSCursor? {
        let width = Int(ceil(size.width * backingScale)), height = Int(ceil(size.height * backingScale))
        guard width > 0, height > 0, let context = try? AnnotationRenderer.bitmap(width: width, height: height) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: backingScale, y: -backingScale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(context)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = CGSize(width: size.width / cursorScale, height: size.height / cursorScale)
        let result = NSImage(size: rep.size)
        result.addRepresentation(rep)
        return NSCursor(image: result, hotSpot: NSPoint(x: hotSpot.x / cursorScale, y: hotSpot.y / cursorScale))
    }
}
