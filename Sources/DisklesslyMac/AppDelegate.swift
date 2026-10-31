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

    private var dashboardURL: URL? {
        guard let server, server.isRunning else { return nil }
        return URL(string: "http://127.0.0.1:\(server.port)/?token=\(server.token)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.mainMenu()
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
        openDashboard(nil)
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
        guard let webRoot = WebRootLocator.find(environment: env) else {
            throw DisklesslyError.failure("The web assets are missing from this app (expected Contents/Resources/web). Reinstall Disklessly.")
        }
        let server = LoopbackUIServer(token: UUID().uuidString) { request in
            ManagementUI.respond(engine: engine, webRoot: webRoot, request: request)
        }
        try server.start()
        self.server = server
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
