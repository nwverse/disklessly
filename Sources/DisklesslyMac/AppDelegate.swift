#if canImport(AppKit)
import AppKit
import Foundation
import DisklesslyCore
import DisklesslyEngine

/// Forwards CLI invocations of this executable to the `disklessly` next to it.
enum CLITrampoline {
    /// Arguments that macOS or Xcode add when they start an app. They are not CLI commands.
    static func cliArguments(_ argv: [String]) -> [String] {
        var out: [String] = []
        var index = 1
        while index < argv.count {
            let arg = argv[index]
            if arg.hasPrefix("-psn_") { index += 1; continue }
            if arg.hasPrefix("-NS") || arg.hasPrefix("-Apple") { index += 2; continue }
            out.append(arg)
            index += 1
        }
        return out
    }

    static func forwardIfNeeded(_ argv: [String]) {
        let rest = cliArguments(argv)
        guard !rest.isEmpty else { return }
        let exe = URL(fileURLWithPath: Bundle.main.executablePath ?? argv[0]).resolvingSymlinksInPath()
        let cli = exe.deletingLastPathComponent().appendingPathComponent("disklessly")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            FileHandle.standardError.write(Data("Disklessly: bundled disklessly not found at \(cli.path)\n".utf8))
            exit(69)
        }
        var cArgs: [UnsafeMutablePointer<CChar>?] = ([cli.path] + rest).map { strdup($0) }
        cArgs.append(nil)
        execv(cli.path, &cArgs)
        FileHandle.standardError.write(Data("Disklessly: could not exec \(cli.path): \(String(cString: strerror(errno)))\n".utf8))
        exit(71)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var server: LoopbackUIServer?
    private var window: WebWindowController?
    private var engine: DisklesslyEngine?
    /// Set when the app was started to open placeholders; then the dashboard does not pop up.
    private var openedDocumentsAtLaunch = false
    private var launched = false
    /// Placeholders opened before the engine was set up.
    private var queued: [String] = []

    private var dashboardURL: URL? {
        guard let server, server.isRunning else { return nil }
        return URL(string: "http://127.0.0.1:\(server.port)/?token=\(server.token)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
        // Finder's right-click > Services (Quick Actions): "Offload with Disklessly", "Bring back with Disklessly".
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        installStatusItem()
        do {
            try startServer()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Disklessly could not start its dashboard"
            alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        launched = true
        if !queued.isEmpty { run(.fetch, queued); queued = [] }
        if !openedDocumentsAtLaunch { openDashboard(nil) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDashboard(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
    }

    private func startServer() throws {
        let env = ProcessInfo.processInfo.environment
        let config = RuntimeConfig.resolved(environment: env, home: NSHomeDirectory(), stateDirOverride: nil, explicitConfig: env["DISKLESSLY_CONFIG"])
        let engine = DisklesslyEngine(config: config)
        self.engine = engine
        guard let webRoot = WebRootLocator.find(environment: env) else {
            throw DisklesslyError.failure("The web assets are missing from this app (expected Contents/Resources/web). Reinstall Disklessly.")
        }
        let server = LoopbackUIServer(token: UUID().uuidString) { request in
            ManagementUI.respond(engine: engine, webRoot: webRoot, request: request)
        }
        try server.start()
        self.server = server
        // Apps packed before icons were saved, or on another Mac, show a blank tile until
        // their icon is extracted. Do that once in the background so the list fills in.
        DispatchQueue.global(qos: .utility).async {
            guard engine.missingIconCount() > 0 else { return }
            _ = try? engine.backfillIcons(appId: nil)
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "externaldrive.badge.icloud", accessibilityDescription: "Disklessly")
                ?? NSImage(systemSymbolName: "externaldrive", accessibilityDescription: "Disklessly") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "256"
            }
            button.toolTip = "Disklessly"
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Dashboard", action: #selector(openDashboard(_:)), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Copy Dashboard URL", action: #selector(copyDashboardURL(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let version = NSMenuItem(title: "Version \(EngineInstall.version) (\(EngineInstall.commit))", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Disklessly", action: #selector(quit(_:)), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    // MARK: Files

    /// Double-clicking a `.disklessly` placeholder brings its file back.
    func application(_ application: NSApplication, open urls: [URL]) {
        if !launched { openedDocumentsAtLaunch = true }
        let placeholders = urls.filter { $0.pathExtension == FilePlaceholder.fileExtension }
        run(.fetch, placeholders.map(\.path))
    }

    /// NSServices handler: `NSMessage` = offloadFiles.
    @objc func offloadFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        run(.offload, Self.filePaths(pasteboard))
    }

    /// NSServices handler: `NSMessage` = fetchFiles.
    @objc func fetchFiles(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        run(.fetch, Self.filePaths(pasteboard).filter { $0.hasSuffix("." + FilePlaceholder.fileExtension) })
    }

    static func filePaths(_ pasteboard: NSPasteboard) -> [String] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map(\.path)
    }

    enum FileAction { case offload, fetch }

    /// Runs off the main thread; one alert at the end lists what failed.
    private func run(_ action: FileAction, _ paths: [String]) {
        guard !paths.isEmpty else { return }
        guard let engine else {
            if action == .fetch { queued.append(contentsOf: paths) }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var failures: [String] = []
            var notes: [String] = []
            for path in paths {
                let name = (path as NSString).lastPathComponent
                do {
                    switch action {
                    case .offload: notes.append(contentsOf: try engine.offloadFile(path).warnings)
                    case .fetch: try engine.fetchFile(path)
                    }
                } catch {
                    failures.append("\(name): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                }
            }
            guard !failures.isEmpty || !notes.isEmpty else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = failures.isEmpty ? "Offloaded with notes" : (action == .offload ? "Disklessly could not offload everything" : "Disklessly could not bring everything back")
                alert.informativeText = (failures + notes).joined(separator: "\n")
                alert.alertStyle = failures.isEmpty ? .informational : .warning
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc func openDashboard(_ sender: Any?) {
        guard let url = dashboardURL else { return }
        let controller = window ?? WebWindowController(url: url)
        window = controller
        controller.present()
    }

    @objc func copyDashboardURL(_ sender: Any?) {
        guard let url = dashboardURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    @objc func quit(_ sender: Any?) {
        NSApp.terminate(nil)
    }

    /// An accessory app has no visible menu bar, but key equivalents still go
    /// through `mainMenu`. Without Edit items, Cmd-C and Cmd-V do nothing in the page.
    static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Disklessly", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Reload", action: #selector(WebWindowController.reload(_:)), keyEquivalent: "r")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        return main
    }
}

/// Finds the management page assets for the app.
enum WebRootLocator {
    static func find(environment: [String: String], fileManager: FileManager = .default) -> URL? {
        var candidates: [URL] = []
        if let override = environment["DISKLESSLY_WEB_ROOT"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override, isDirectory: true))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("web", isDirectory: true))
        }
        // `swift run DisklesslyMac` from a checkout: the CLI's SwiftPM resource bundle sits next to this executable.
        if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let dir = exe.deletingLastPathComponent()
            candidates.append(dir.appendingPathComponent("Disklessly_disklessly.bundle/web", isDirectory: true))
            candidates.append(dir.appendingPathComponent("Disklessly_disklessly.bundle/Contents/Resources/web", isDirectory: true))
        }
        return candidates.first { fileManager.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }
}
#endif
