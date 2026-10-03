import AppKit
import ApplicationServices
import UtsushieCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var config = UtsushieConfig()
    private var warnings: [String] = []
    private let hotkey = GlobalHotkey()
    private let overlay = OverlayController()
    private let capture = CaptureService()
    private let thumbnails = ThumbnailController()
    private var lastArea: LastArea?
    private var busy = false
    private var warningItem: NSMenuItem!
    private var configURL: URL { ConfigLoader.defaultPath() }
    private var lastURL: URL { ConfigLoader.directory().appendingPathComponent("last-area.json") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        lastArea = LastArea.load(from: lastURL)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "UTSUSHIE")
        let menu = NSMenu(); menu.delegate = self
        for (title, selector) in [("撮影", #selector(shoot)), ("保存フォルダを開く", #selector(openFolder)), ("設定ファイルを開く", #selector(openConfig))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        warningItem = NSMenuItem(title: "", action: #selector(showWarnings), keyEquivalent: "")
        warningItem.target = self; menu.addItem(warningItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "終了", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; menu.addItem(quit)
        statusItem.menu = menu
        reloadConfig()
        hotkey.onPress = { [weak self] in self?.shoot() }
        overlay.onCapture = { [weak self] request, remember in self?.take(request, remember: remember) }
        overlay.onMoveLast = { [weak self] rect in self?.persistLast(rect) }
        overlay.onCancel = { [weak self] in self?.thumbnails.setSuspended(false) }
        overlay.onAccessibilityNeeded = { [weak self] in self?.openPrivacy("Privacy_Accessibility") }
    }
    func applicationWillTerminate(_ notification: Notification) { hotkey.stop(); overlay.close() }
    func menuWillOpen(_ menu: NSMenu) { reloadConfig() }
    private func reloadConfig() {
        let result = ConfigLoader.load()
        config = result.config; warnings = result.warnings
        if let warning = hotkey.register(config.hotkey) { warnings.append(warning) }
        updateWarnings()
    }
    private func updateWarnings() {
        warningItem?.isHidden = warnings.isEmpty
        warningItem?.title = "⚠ 警告 \(warnings.count)件…"
    }
    @objc private func showWarnings() { alert("UTSUSHIEの警告", warnings.joined(separator: "\n")) }
    @objc private func shoot() {
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
        overlay.show(last: last)
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
    @objc private func quitApp() { NSApp.terminate(nil) }
}
