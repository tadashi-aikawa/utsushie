import AppKit
import ApplicationServices
import UtsushieCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var config = UtsushieConfig()
    private var warnings: [String] = []
    private let hotkey = GlobalHotkey()
    private let overlay = OverlayController()
    private let capture = CaptureService()
    private let thumbnails = ThumbnailController()
    private var recentCaptures: RecentCaptureMenu!
    private let annotationNavigationDiagnostics = AnnotationNavigationDiagnostics()
    private let recordingBorder = RecordingBorder()
    private var recordingState = RecordingState()
    private var activeRecording: RecordingService?
    private var recordingStartTask: Task<Void, Never>?
    private var recordingToken: UUID?
    private var recordingTimer: Timer?
    private var recordingHostStart: Double = 0
    private var recordingDate = Date()
    private var recordingConfig = UtsushieConfig()
    private var stopWhenStarted = false
    private var quitAfterRecording = false
    private var borderRect: CGRect?
    private var shootItem: NSMenuItem!
    private var lastArea: LastArea?
    private var busy = false
    private var warningItem: NSMenuItem!
    private var configURL: URL { ConfigLoader.defaultPath() }
    private var lastURL: URL { ConfigLoader.directory().appendingPathComponent("last-area.json") }

    // バンドル済みのアイコンを共有し、状態の更新ごとに読み直さない。
    private static let logoIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "utsushie", withExtension: "icns"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = false
        image.accessibilityDescription = "UTSUSHIE 待機中"
        return image
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        annotationNavigationDiagnostics.start()
        lastArea = LastArea.load(from: lastURL)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.image = Self.logoIcon ?? NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "UTSUSHIE")
        let menu = NSMenu(); menu.delegate = self; menu.autoenablesItems = false
        for (title, selector) in [("撮影", #selector(shoot)), ("保存フォルダを開く", #selector(openFolder)), ("設定ファイルを開く", #selector(openConfig))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
            if selector == #selector(shoot) { shootItem = item }
            if selector == #selector(shoot) { menu.addItem(.separator()) }
        }
        recentCaptures = RecentCaptureMenu(directory: { [weak self] in self?.config.outputURL() ?? UtsushieConfig().outputURL() },
            onFiles: { [weak self] files in self?.thumbnails.pruneMemory(to: files) },
            onSelect: { [weak self] url in self?.restoreCapture(url) })
        let recentItem = NSMenuItem(title: "最近の撮影", action: nil, keyEquivalent: "")
        recentItem.submenu = recentCaptures.menu; menu.insertItem(recentItem, at: 2)
        thumbnails.onArtifactsChange = { [weak self] in self?.recentCaptures.refresh() }
        warningItem = NSMenuItem(title: "", action: #selector(showWarnings), keyEquivalent: "")
        warningItem.target = self; menu.addItem(warningItem)
        warningItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "設定の警告")
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "開発版"
        let versionItem = NSMenuItem(title: "UTSUSHIE \(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false; menu.addItem(versionItem)
        let quit = NSMenuItem(title: "UTSUSHIEを終了", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        statusMenu = menu
        statusItem.menu = menu
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClicked)
        reloadConfig()
        warnings += VideoEditStore.cleanupAtLaunch(directory: config.outputURL())
        recentCaptures.refresh()
        updateWarnings()
        hotkey.onPress = { [weak self] in self?.shoot() }
        overlay.onCapture = { [weak self] request, remember, output in
            guard let self else { return }
            if output == .video { self.startRecording(request, remember: remember) }
            else { self.take(request, remember: remember) }
        }
        overlay.onMoveLast = { [weak self] rect in self?.persistLast(rect) }
        overlay.onCancel = { [weak self] in
            self?.recordingStartTask?.cancel()
            self?.thumbnails.setSuspended(false)
        }
        overlay.onAccessibilityNeeded = { [weak self] in self?.openPrivacy("Privacy_Accessibility") }
    }
    func applicationWillTerminate(_ notification: Notification) {
        annotationNavigationDiagnostics.stop()
        hotkey.stop(); overlay.close(); recordingBorder.close(); recordingTimer?.invalidate()
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        if recordingState.phase == .idle { reloadConfig() }
        recentCaptures.refresh()
        shootItem.isEnabled = recordingState.phase == .recording || !busy && recordingState.phase == .idle
    }
    private func reloadConfig() {
        let result = ConfigLoader.load()
        config = result.config; warnings = result.warnings
        if let warning = hotkey.register(config.hotkey) { warnings.append(warning) }
        updateHotkeyLabel()
        updateWarnings()
    }
    private func updateHotkeyLabel() {
        // 表示だけを設定から作る。グローバルホットキーの物理キー判定は登録側へ任せる。
        let title = recordingState.phase == .recording ? "録画を停止" : "撮影"
        shootItem.title = title
        let label = HotkeyPresentation.label(config.hotkey)
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 244)]
        let attributed = NSMutableAttributedString(string: title + "\t" + label,
            attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: style])
        attributed.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                range: NSRange(location: (title as NSString).length + 1, length: (label as NSString).length))
        shootItem.attributedTitle = attributed
    }
    private func updateWarnings() {
        warningItem?.isHidden = warnings.isEmpty
        warningItem?.title = "設定の警告 \(warnings.count)件…"
    }
    @objc private func showWarnings() { alert("UTSUSHIEの警告", warnings.joined(separator: "\n")) }
    private func restoreCapture(_ url: URL) {
        let seconds = config.thumbnailSeconds
        Task {
            do { try await thumbnails.restore(url, seconds: seconds, screen: NSScreen.main) }
            catch { alert("撮影のカードを開けませんでした", error.localizedDescription) }
        }
    }
    @objc private func shoot() {
        if recordingState.phase == .recording { stopRecording(); return }
        guard !busy else { return }
        if overlay.isVisible { overlay.repeatCapture(); return }
        reloadConfig()
        guard CGPreflightScreenCaptureAccess() else {
            _ = CGRequestScreenCaptureAccess()
            alert("画面収録の許可が必要です", "システム設定の「プライバシーとセキュリティ → 画面収録」でUTSUSHIEを許可してください。許可後にアプリを再起動してください。")
            openPrivacy("Privacy_ScreenCapture")
            return
        }
        let last = lastArea.flatMap { CaptureGeometry.isVisible($0.rect, displays: ScreenGeometry.displays) ? $0.rect : nil }
        thumbnails.setSuspended(true)
        overlay.config = config
        overlay.show(last: last)
    }
    private func startRecording(_ request: CaptureRequest, remember: Bool) {
        guard !busy else { return }
        guard VideoGeometry.display(containing: request.rect, displays: ScreenGeometry.displays) != nil else {
            overlay.showError(CaptureError.unavailable("動画は1つのディスプレイの中で選んでください")); return
        }
        guard recordingState.begin() else { return }
        busy = true; stopWhenStarted = false
        let token = UUID(); recordingToken = token
        recordingConfig = config; recordingDate = Date()
        updateRecordingStatus()
        recordingStartTask = Task {
            var prepared: RecordingService?
            do {
                // オーバーレイを出したままcontentを取得し、除外対象の自アプリを確実に列挙する。
                // 準備中のEscはTaskを取消し、非同期処理の後から録画が始まることを防ぐ。
                let session = try await RecordingService.prepare(request: request, config: recordingConfig.video,
                    directory: recordingConfig.outputURL(), onStop: { [weak self] in
                        // 古いSCStreamの遅延通知で次の録画を止めない。
                        guard let self, self.recordingToken == token else { return }
                        self.streamStopped()
                    })
                prepared = session
                try Task.checkCancellation()
                activeRecording = session
                overlay.close()
                borderRect = request.rect; recordingBorder.show(rect: request.rect)
                recordingHostStart = ProcessInfo.processInfo.systemUptime
                try await session.start()
                recordingState.didStart()
                if remember { persistLast(request.rect) }
                thumbnails.setSuspended(false)
                updateRecordingStatus()
                recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.recordingTick() }
                }
                recordingStartTask = nil
                if stopWhenStarted || quitAfterRecording { stopRecording() }
            } catch {
                await prepared?.abort()
                activeRecording = nil; recordingToken = nil; recordingState.reset(); busy = false
                recordingBorder.close(); borderRect = nil; thumbnails.setSuspended(false)
                recordingStartTask = nil; updateRecordingStatus()
                if !(error is CancellationError) {
                    if overlay.isVisible { overlay.showError(error) }
                    else { alert("録画を開始できませんでした", error.localizedDescription) }
                }
                if quitAfterRecording { NSApp.terminate(nil) }
            }
        }
    }
    private func streamStopped() {
        if recordingState.phase == .starting { stopWhenStarted = true }
        else { stopRecording() }
    }
    private func recordingTick() {
        guard recordingState.phase == .recording, let session = activeRecording else { return }
        updateRecordingStatus()
        guard ScreenGeometry.displays.contains(where: { $0.id == session.displayID }) else { stopRecording(); return }
        if case let .window(id, _) = session.request {
            let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]]
            guard let bounds = info?.first?[kCGWindowBounds as String] as? [String: Any],
                  let cgRect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { stopRecording(); return }
            let rect = ScreenGeometry.appKit(cgRect)
            if rect != borderRect { borderRect = rect; recordingBorder.show(rect: rect) }
        }
    }
    private func updateRecordingStatus() {
        let recording = recordingState.phase == .recording
        statusItem.menu = recording ? nil : statusMenu
        statusItem.length = recordingState.phase == .idle ? NSStatusItem.squareLength : NSStatusItem.variableLength
        let title = RecordingPresentation.title(phase: recordingState.phase, elapsed: ProcessInfo.processInfo.systemUptime - recordingHostStart)
        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.title = ""
        if recording {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.white]
            let textSize = (title as NSString).size(withAttributes: attributes)
            button.image = NSImage(size: CGSize(width: ceil(textSize.width) + 12, height: 18), flipped: false) { rect in
                UIDrawing.fill(rect, color: UITheme.redFace, radius: 5)
                (title as NSString).draw(at: CGPoint(x: 6, y: (18 - textSize.height) / 2), withAttributes: attributes)
                return true
            }
            button.image?.isTemplate = false
        } else if recordingState.phase == .idle {
            button.image = Self.logoIcon ?? NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "UTSUSHIE")
        } else {
            button.image = nil; button.title = title
        }
        button.setAccessibilityLabel(recording ? "録画を停止 \(title)" : "UTSUSHIE \(title)")
        updateHotkeyLabel()
        shootItem.isEnabled = recording || !busy && recordingState.phase == .idle
    }
    @objc private func statusClicked() {
        if RecordingPresentation.stopsOnClick(phase: recordingState.phase) { stopRecording() }
    }
    private func stopRecording() {
        guard let session = activeRecording, recordingState.stop() else { return }
        let stoppedAt = ProcessInfo.processInfo.systemUptime
        let duration = max(0, stoppedAt - recordingHostStart)
        recordingTimer?.invalidate(); recordingTimer = nil
        recordingBorder.close(); borderRect = nil; updateRecordingStatus()
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == session.displayID }
        Task {
            // finalizeが終わるまではファイルを共有させない。寿命も完了後から数える。
            let pending = SharedArtifact(url: recordingConfig.outputURL(), kind: .mp4, width: session.width,
                height: session.height, byteCount: 0, duration: duration)
            let cardID = thumbnails.add(pending, image: await session.firstFrame(), copied: false,
                seconds: recordingConfig.thumbnailSeconds, screen: screen, finalizing: true)
            await session.stop()
            var temporary: URL?
            do {
                let result = try await session.finish(hostTime: stoppedAt)
                temporary = result.temporaryURL
                let url = try ArtifactStore.publishVideo(from: result.temporaryURL, date: recordingDate)
                temporary = nil
                let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                let artifact = SharedArtifact(url: url, kind: .mp4, width: result.width, height: result.height,
                    byteCount: bytes, duration: result.duration, videoFPS: recordingConfig.video.fps)
                let copied = ClipboardWriter.copy(artifact, mode: recordingConfig.clipboard)
                thumbnails.complete(cardID, artifact: artifact, image: result.image, copied: copied)
            } catch {
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
                thumbnails.remove(cardID)
                alert("録画を保存できませんでした", error.localizedDescription)
            }
            activeRecording = nil; recordingToken = nil; recordingState.reset(); busy = false; updateRecordingStatus()
            if quitAfterRecording { NSApp.terminate(nil) }
        }
    }
    private func take(_ request: CaptureRequest, remember: Bool) {
        guard !busy else { return }
        busy = true
        overlay.close()
        let snapshot = config
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: request.rect.midX, y: request.rect.midY)) }
        Task {
            do {
                let image = try await capture.image(for: request, downscale: snapshot.downscale)
                // エンコードとディスク書き込みはメインスレッドを塞がない。
                let (data, url) = try await Task.detached(priority: .userInitiated) {
                    let data = try WebPEncoder.encode(image, quality: snapshot.quality, lossless: snapshot.lossless)
                    let url = try ArtifactStore.save(data: data, kind: .webP, directory: snapshot.outputURL())
                    return (data, url)
                }.value
                let artifact = SharedArtifact(url: url, kind: .webP, width: image.width, height: image.height, byteCount: data.count)
                let copied = ClipboardWriter.copy(artifact, data: data, mode: snapshot.clipboard)
                if remember { persistLast(request.rect) }
                thumbnails.setSuspended(false)
                thumbnails.add(artifact, image: image, copied: copied, seconds: snapshot.thumbnailSeconds, screen: screen)
            } catch {
                thumbnails.setSuspended(false)
                alert("撮影できませんでした", error.localizedDescription)
            }
            busy = false
        }
    }
    private func persistLast(_ rect: CGRect) {
        lastArea = LastArea(rect: rect)
        do { try lastArea?.save(to: lastURL) }
        catch { warnings.append("前回範囲を保存できません: \(error.localizedDescription)"); updateWarnings() }
    }
    @objc private func openFolder() {
        do {
            try FileManager.default.createDirectory(at: config.outputURL(), withIntermediateDirectories: true)
            NSWorkspace.shared.open(config.outputURL())
        } catch { alert("保存フォルダを開けません", error.localizedDescription) }
    }
    @objc private func openConfig() {
        do {
            if !FileManager.default.fileExists(atPath: configURL.path) {
                try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try ConfigLoader.template.write(to: configURL, atomically: true, encoding: .utf8)
            }
            NSWorkspace.shared.open(configURL)
        } catch { alert("設定ファイルを開けません", error.localizedDescription) }
    }
    private func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
    private func alert(_ title: String, _ body: String) {
        NSApp.activate()
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = body; alert.runModal()
    }
    @objc private func quitApp() {
        if recordingState.phase != .idle {
            quitAfterRecording = true
            if recordingState.phase == .starting { recordingStartTask?.cancel() }
            else { stopRecording() }
        } else { NSApp.terminate(nil) }
    }
}
