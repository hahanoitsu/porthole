import AppKit
import PortholeCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var windowController: MirrorWindowController?
    private var receiver: AirPlayReceiver?
    private let defaults = UserDefaults.standard

    private var soundMuted: Bool {
        get { defaults.bool(forKey: "soundMuted") }
        set {
            defaults.set(newValue, forKey: "soundMuted")
            receiver?.isAudioMuted = newValue
            windowController?.isSoundMuted = newValue
        }
    }

    /// On unless turned off.
    private var smoothPlayback: Bool {
        get { defaults.object(forKey: "smoothPlayback") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "smoothPlayback")
            receiver?.smoothPlayback = newValue
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Porthole/porthole.log")
        Log.shared.openFile(logURL)
        if defaults.bool(forKey: "debugLogging") { Log.shared.level = .debug }
        logInfo("Porthole starting on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")

        let config = Self.configFromDefaults()
        NSApp.mainMenu = makeMainMenu()
        let controller = MirrorWindowController()
        controller.receiverName = config.name
        controller.isSoundMuted = soundMuted
        windowController = controller
        controller.showWindow(nil)
        startReceiver(config)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        receiver?.stop()
    }

    private func startReceiver(_ config: ReceiverConfig) {
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Porthole", isDirectory: true)
            let identity = try ReceiverIdentity.loadOrCreate(at: support.appendingPathComponent("identity.json"))
            let receiver = AirPlayReceiver(config: config, identity: identity)
            receiver.delegate = windowController
            receiver.isAudioMuted = soundMuted
            receiver.smoothPlayback = smoothPlayback
            receiver.pictureOffset = defaults.double(forKey: "pictureOffsetMs") / 1000
            try receiver.start()
            self.receiver = receiver
        } catch {
            logError("Could not start the receiver: \(error)")
            let alert = NSAlert()
            alert.messageText = "Porthole couldn't start"
            alert.informativeText = "\(error)"
            alert.runModal()
        }
    }

    /// Settings live in user defaults, for example:
    ///   defaults write local.porthole.Porthole displayHeight -int 2160
    static func configFromDefaults() -> ReceiverConfig {
        let defaults = UserDefaults.standard
        var config = ReceiverConfig()
        if let name = defaults.string(forKey: "receiverName"), !name.isEmpty { config.name = name }
        if defaults.integer(forKey: "displayWidth") > 0 { config.displayWidth = defaults.integer(forKey: "displayWidth") }
        if defaults.integer(forKey: "displayHeight") > 0 { config.displayHeight = defaults.integer(forKey: "displayHeight") }
        if defaults.integer(forKey: "maxFPS") > 0 { config.maxFPS = defaults.integer(forKey: "maxFPS") }
        if defaults.object(forKey: "allowHEVC") != nil { config.allowHEVC = defaults.bool(forKey: "allowHEVC") }
        if defaults.object(forKey: "legacyPairing") != nil { config.legacyPairing = defaults.bool(forKey: "legacyPairing") }
        return config
    }

    // MARK: - Actions

    @objc func toggleSoundMuted(_ sender: Any?) {
        soundMuted.toggle()
        logInfo(soundMuted ? "Sound on this Mac muted" : "Sound on this Mac unmuted")
    }

    @objc func toggleSmoothPlayback(_ sender: Any?) {
        smoothPlayback.toggle()
        logInfo(smoothPlayback ? "Smooth playback on: frames are held just long enough to play evenly"
                               : "Smooth playback off: frames are shown as soon as they arrive")
    }

    /// The menu item's tag is the frame rate.
    @objc func chooseFrameRate(_ sender: NSMenuItem) {
        defaults.set(sender.tag, forKey: "maxFPS")
        receiver?.maxFPS = sender.tag
        logInfo("Frame rate limit set to \(sender.tag) fps; it applies the next time the phone starts mirroring")
    }

    @objc private func showLog(_ sender: Any?) {
        guard let url = Log.shared.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleSoundMuted(_:)):
            menuItem.state = soundMuted ? .on : .off
        case #selector(toggleSmoothPlayback(_:)):
            menuItem.state = smoothPlayback ? .on : .off
        case #selector(chooseFrameRate(_:)):
            menuItem.state = receiver?.maxFPS == menuItem.tag ? .on : .off
        default:
            break
        }
        return true
    }

    // MARK: - Menus

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Porthole", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Show Log in Finder", action: #selector(showLog(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Porthole", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Porthole", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(submenuItem(appMenu))

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Actual Size", action: #selector(MirrorWindowController.showActualSize(_:)), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "Fit to Screen", action: #selector(MirrorWindowController.fitToScreen(_:)), keyEquivalent: "2")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Float on Top", action: #selector(MirrorWindowController.toggleFloating(_:)), keyEquivalent: "t")
        viewMenu.addItem(.separator())
        let smooth = viewMenu.addItem(withTitle: "Smooth Playback", action: #selector(toggleSmoothPlayback(_:)), keyEquivalent: "")
        smooth.target = self
        smooth.toolTip = "Holds each frame just long enough for the picture to move evenly through Wi-Fi hiccups. "
            + "Turn off to show frames the moment they arrive."
        let frameRateMenu = NSMenu(title: "Frame Rate")
        for fps in [60, 30] {
            let item = frameRateMenu.addItem(withTitle: "\(fps) fps", action: #selector(chooseFrameRate(_:)), keyEquivalent: "")
            item.tag = fps
            item.target = self
            item.toolTip = "Applies the next time you start mirroring."
        }
        let frameRate = viewMenu.addItem(withTitle: "Frame Rate", action: nil, keyEquivalent: "")
        frameRate.submenu = frameRateMenu
        viewMenu.addItem(.separator())
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        mainMenu.addItem(submenuItem(viewMenu))

        let soundMenu = NSMenu(title: "Sound")
        let mute = soundMenu.addItem(withTitle: "Mute Sound on This Mac", action: #selector(toggleSoundMuted(_:)), keyEquivalent: "m")
        mute.keyEquivalentModifierMask = [.command, .shift]
        mute.target = self
        mainMenu.addItem(submenuItem(soundMenu))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        mainMenu.addItem(submenuItem(windowMenu))
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    private func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}
