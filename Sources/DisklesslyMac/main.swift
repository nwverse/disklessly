// Disklessly menu-bar app. It runs the management page in-process on 127.0.0.1
// and shows it in a WKWebView window. The Dock icon shows only while that window is open.
#if canImport(AppKit)
import AppKit

// A write to a pipe or socket whose reader is gone (a child that exited, a closed
// browser connection) must fail with EPIPE, not kill the app: the default SIGPIPE
// action ends the process silently, with no crash report. Set before the CLI
// trampoline so the exec'd `disklessly` inherits it.
_ = signal(SIGPIPE, SIG_IGN)

// Engine code re-executes `argv[0]` for some jobs, such as the detached
// `hook watch` that follows a restore-mode launch. Inside the app bundle
// `argv[0]` is this executable, so CLI arguments are forwarded to the bundled
// `disklessly` instead of starting a second menu-bar app.
CLITrampoline.forwardIfNeeded(CommandLine.arguments)

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
#else
import Foundation
FileHandle.standardError.write(Data("DisklesslyMac needs macOS (AppKit). Use the disklessly CLI on this platform.\n".utf8))
exit(69)
#endif
