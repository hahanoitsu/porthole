import AppKit
import notify
import PortholeCore

/// The mirror window. It locks to the phone's aspect ratio, resizes itself when the phone rotates,
/// and remembers how big you like it relative to the screen.
final class MirrorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, AirPlayReceiverDelegate {
    var receiverName = "Porthole" {
        didSet { updateOverlay() }
    }
    var isSoundMuted = false {
        didSet { updateSoundButton() }
    }

    private enum State { case starting, idle, connecting, showing, paused }

    private let videoView = VideoView()
    private let overlay = OverlayView()
    private let soundButton = NSButton()
    private let videoQueue = DispatchQueue(label: "porthole.video", qos: .userInteractive)

    /// The receiver the phone is mirroring to. Video events arrive on background threads, so
    /// this is read under a lock; events from any other receiver are ignored.
    private let activeLock = NSLock()
    private var activeReceiverID: ObjectIdentifier?

    // Main thread only.
    private var state = State.starting {
        didSet { updateOverlay() }
    }
    private var discoverable = false
    private var advertisingError: String? {
        didSet { updateOverlay() }
    }
    private var clientName: String?
    private var videoSize: CGSize?  // pixels
    /// Window size relative to the largest that fits on screen (1 = fill the screen's height or width).
    private var preferredScale: CGFloat = 1
    /// Set while we resize the window ourselves; an animated resize reports a live resize too.
    private var resizingProgrammatically = false
    private var snapshotToken: Int32 = 0

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Porthole"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .black
        window.minSize = NSSize(width: 160, height: 160)
        window.collectionBehavior = [.fullScreenPrimary]
        super.init(window: window)
        window.delegate = self

        let content = NSView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        for view in [videoView, overlay] as [NSView] {
            view.frame = content.bounds
            view.autoresizingMask = [.width, .height]
            content.addSubview(view)
        }
        window.contentView = content
        if !window.setFrameUsingName("PortholeWindow") { window.center() }
        window.setFrameAutosaveName("PortholeWindow")
        addSoundButton(to: window)
        updateOverlay()

        // Debugging aid, off by default: `notifyutil -p local.porthole.snapshot` saves the frame on
        // screen next to the log. Turn on with `defaults write local.porthole.Porthole debugSnapshots -bool true`.
        if UserDefaults.standard.bool(forKey: "debugSnapshots") {
            notify_register_dispatch("local.porthole.snapshot", &snapshotToken, .main) { [weak self] _ in
                self?.saveDebugSnapshot()
            }
            logInfo("Debug snapshots are on (notifyutil -p local.porthole.snapshot)")
        }
    }

    /// A speaker button at the right end of the (transparent) title bar. Its action travels up the
    /// responder chain to the app delegate, which owns the mute setting.
    private func addSoundButton(to window: NSWindow) {
        soundButton.isBordered = false
        soundButton.imagePosition = .imageOnly
        soundButton.contentTintColor = .white
        soundButton.target = nil
        soundButton.action = #selector(AppDelegate.toggleSoundMuted(_:))
        soundButton.frame = NSRect(x: 4, y: 2, width: 28, height: 24)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 28))
        container.addSubview(soundButton)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .trailing
        accessory.view = container
        window.addTitlebarAccessoryViewController(accessory)
        updateSoundButton()
    }

    private func updateSoundButton() {
        let symbol = isSoundMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        let tip = isSoundMuted ? "Sound on this Mac is off. Click to turn it on (⇧⌘M)."
                               : "Sound plays on this Mac. Click to mute it (⇧⌘M)."
        soundButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        soundButton.toolTip = tip
    }

    private func isActive(_ receiver: AirPlayReceiver) -> Bool {
        activeLock.lock()
        defer { activeLock.unlock() }
        return activeReceiverID == ObjectIdentifier(receiver)
    }

    private func saveDebugSnapshot() {
        logWindowGeometry("snapshot")
        guard let url = Log.shared.fileURL?.deletingLastPathComponent().appendingPathComponent("snapshot.png") else { return }
        videoQueue.async {
            guard let png = self.videoView.snapshotPNG() else {
                logWarning("Snapshot: no frame on screen")
                return
            }
            do {
                try png.write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                logInfo("Snapshot saved to \(url.path) (\(png.count) bytes)")
            } catch {
                logError("Snapshot failed: \(error)")
            }
        }
    }

    private func logWindowGeometry(_ reason: String) {
        guard let window else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        var line = "Window (\(reason)): \(Int(content.width))x\(Int(content.height)) pt at (\(Int(content.minX)), \(Int(content.minY))), "
            + "\(window.backingScaleFactor)x; screen area \(Int(screen.width))x\(Int(screen.height)) pt"
        if let videoSize {
            let shown = content.height * window.backingScaleFactor / videoSize.height
            line += String(format: "; video %dx%d px shown at %.0f%% of its resolution; size preference %.2f",
                           Int(videoSize.width), Int(videoSize.height), shown * 100, preferredScale)
        }
        if window.level == .floating { line += "; floating" }
        logInfo(line)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: - AirPlayReceiverDelegate (background threads unless noted)

    /// Main queue.
    func receiverDidBecomeDiscoverable(_ receiver: AirPlayReceiver) {
        discoverable = true
        advertisingError = nil
        if state == .starting { state = .idle }
    }

    /// Main queue.
    func receiver(_ receiver: AirPlayReceiver, couldNotAdvertise reason: String) {
        advertisingError = reason
    }

    func receiver(_ receiver: AirPlayReceiver, didStartMirroringFrom clientName: String?) {
        activeLock.lock()
        activeReceiverID = ObjectIdentifier(receiver)
        activeLock.unlock()
        DispatchQueue.main.async {
            self.clientName = clientName
            self.window?.title = clientName ?? "Porthole"
            if self.state == .idle || self.state == .starting { self.state = .connecting }
        }
    }

    func receiver(_ receiver: AirPlayReceiver, didChangeVideoFormat format: VideoStreamFormat) {
        guard isActive(receiver) else { return }
        videoQueue.async {
            guard let size = self.videoView.setFormat(format) else { return }
            DispatchQueue.main.async { self.applyVideoSize(size) }
        }
    }

    func receiver(_ receiver: AirPlayReceiver, didReceive frame: VideoFrame) {
        guard isActive(receiver) else { return }
        videoQueue.async {
            guard self.videoView.enqueue(frame) else { return }
            DispatchQueue.main.async {
                if self.state != .paused { self.state = .showing }
            }
        }
    }

    func receiver(_ receiver: AirPlayReceiver, didPauseVideo paused: Bool) {
        guard isActive(receiver) else { return }
        DispatchQueue.main.async {
            if paused {
                self.state = .paused
            } else if self.state == .paused {
                self.state = .showing
            }
        }
    }

    func receiverDidStopMirroring(_ receiver: AirPlayReceiver) {
        activeLock.lock()
        let wasActive = activeReceiverID == ObjectIdentifier(receiver)
        if wasActive { activeReceiverID = nil }
        activeLock.unlock()
        guard wasActive else { return }  // the phone already moved to the other receiver

        videoQueue.async { self.videoView.reset() }
        DispatchQueue.main.async {
            self.state = self.discoverable ? .idle : .starting
            self.clientName = nil
            self.videoSize = nil
            self.window?.title = "Porthole"
            self.window?.contentResizeIncrements = NSSize(width: 1, height: 1)  // unlocks the aspect ratio
        }
    }

    // MARK: - Sizing

    private func applyVideoSize(_ pixels: CGSize) {
        guard let window, pixels.width > 0, pixels.height > 0 else { return }
        let firstFormat = videoSize == nil
        videoSize = pixels
        window.contentAspectRatio = pixels
        guard !window.styleMask.contains(.fullScreen) else { return }
        resizeWindow(toContentSize: fittedSize(for: pixels, scale: preferredScale), animate: !firstFormat)
        logWindowGeometry(firstFormat ? "new stream" : "stream changed shape")
    }

    /// The content size that shows `pixels` as large as fits on screen, times `scale`.
    private func fittedSize(for pixels: CGSize, scale: CGFloat) -> CGSize {
        let screen = (window?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let titlebar = (window?.frame.height ?? 0) - (window?.contentLayoutRect.height ?? 0)
        let available = CGSize(width: screen.width - 32, height: screen.height - 32 - max(titlebar, 0))
        let fit = min(available.width / pixels.width, available.height / pixels.height)
        let size = CGSize(width: (pixels.width * fit * scale).rounded(), height: (pixels.height * fit * scale).rounded())
        // Scaling up by a few percent only softens the picture, so show it pixel for pixel instead.
        let backing = window?.backingScaleFactor ?? 2
        let ratio = size.height * backing / pixels.height
        if ratio > 1, ratio <= 1.1 {
            return CGSize(width: (pixels.width / backing).rounded(), height: (pixels.height / backing).rounded())
        }
        return size
    }

    /// Resizes around the window's current center, then nudges it fully on screen.
    private func resizeWindow(toContentSize contentSize: CGSize, animate: Bool) {
        guard let window else { return }
        let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        var frame = NSRect(x: window.frame.midX - size.width / 2, y: window.frame.midY - size.height / 2,
                           width: size.width, height: size.height)
        if let screen = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        }
        resizingProgrammatically = true
        window.setFrame(frame, display: true, animate: animate)
        resizingProgrammatically = false
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard !resizingProgrammatically, let window, let pixels = videoSize else { return }
        let largest = fittedSize(for: pixels, scale: 1)
        let current = window.contentRect(forFrameRect: window.frame).size
        preferredScale = max(0.1, min(1, current.height / largest.height))
        logWindowGeometry("resized by hand")
    }

    // MARK: - Menu actions

    /// One video pixel per screen pixel (or as close as fits).
    @objc func showActualSize(_ sender: Any?) {
        guard let window, let pixels = videoSize else { return }
        let largest = fittedSize(for: pixels, scale: 1)
        let actualHeight = pixels.height / window.backingScaleFactor
        preferredScale = min(1, actualHeight / largest.height)
        resizeWindow(toContentSize: fittedSize(for: pixels, scale: preferredScale), animate: true)
    }

    @objc func fitToScreen(_ sender: Any?) {
        preferredScale = 1
        guard let pixels = videoSize else { return }
        resizeWindow(toContentSize: fittedSize(for: pixels, scale: 1), animate: true)
    }

    @objc func toggleFloating(_ sender: Any?) {
        guard let window else { return }
        window.level = window.level == .floating ? .normal : .floating
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleFloating(_:)):
            menuItem.state = window?.level == .floating ? .on : .off
            return true
        case #selector(showActualSize(_:)), #selector(fitToScreen(_:)):
            return videoSize != nil && !(window?.styleMask.contains(.fullScreen) ?? false)
        default:
            return true
        }
    }

    // MARK: - Overlay

    private func updateOverlay() {
        if let advertisingError, state == .starting || state == .idle {
            overlay.show(title: "iPhones can't see Porthole", detail: advertisingError, dimmed: false)
            return
        }
        switch state {
        case .starting:
            overlay.show(title: "Getting ready…",
                         detail: "If macOS asks whether Porthole may find devices on your local network, choose Allow.",
                         dimmed: false)
        case .idle:
            overlay.show(title: "Ready to mirror",
                         detail: "On your iPhone, open Control Center, tap Screen Mirroring, and choose “\(receiverName)”.",
                         dimmed: false)
        case .connecting:
            overlay.show(title: "Connecting…",
                         detail: clientName.map { "Waiting for the picture from \($0)." } ?? "Waiting for the picture.",
                         dimmed: false)
        case .showing:
            overlay.hide()
        case .paused:
            overlay.show(title: "Paused", detail: "The iPhone stopped sending its screen. It's probably locked.", dimmed: true)
        }
    }
}

/// Centered status text over the video. Clicks pass through so the window stays draggable.
final class OverlayView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        detailLabel.font = .systemFont(ofSize: 13)
        detailLabel.textColor = NSColor(white: 1, alpha: 0.7)
        detailLabel.alignment = .center
        detailLabel.preferredMaxLayoutWidth = 260

        let stack = NSStackView(views: [titleLabel, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(title: String, detail: String, dimmed: Bool) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        layer?.backgroundColor = dimmed ? NSColor(white: 0, alpha: 0.55).cgColor : NSColor.clear.cgColor
        isHidden = false
    }

    func hide() {
        isHidden = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
