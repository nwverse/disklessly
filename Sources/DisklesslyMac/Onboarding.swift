#if canImport(AppKit) && canImport(SwiftUI)
import AppKit
import SwiftUI
import DisklesslyEngine

// Permission onboarding. Before the dashboard opens, the app checks App Management (needed to
// swap apps in /Applications) and Full Disk Access (protected folders, iCloud repo). For each
// missing one it opens the System Settings pane and floats a small panel with the app icon,
// which the user drags into the list there.

final class PermissionModel: ObservableObject {
    @Published var states: [MacPermission: PermissionState] = [:]
    private let queue = DispatchQueue(label: "disklessly.permissions")

    func state(_ permission: MacPermission) -> PermissionState { states[permission] ?? .unknown }

    /// Full Disk Access is cheap and silent to test; App Management only when asked (a refusal
    /// can raise a system notification).
    func refresh(appManagement: Bool) {
        queue.async {
            let fda = PermissionProbe.fullDiskAccess()
            let apps = appManagement ? PermissionProbe.appManagement() : nil
            DispatchQueue.main.async {
                self.states[.fullDiskAccess] = fda
                if let apps { self.states[.appManagement] = apps }
            }
        }
    }

    /// A required permission must test as granted; "can't check" is not good enough for it.
    var requiredGranted: Bool { MacPermission.allCases.filter(\.required).allSatisfy { state($0) == .granted } }
    var allGranted: Bool { MacPermission.allCases.allSatisfy { state($0) != .denied } }
    /// Permissions still to turn on: denied ones, and required ones that could not be checked.
    var missing: [MacPermission] {
        MacPermission.allCases.filter { state($0) == .denied || ($0.required && state($0) != .granted) }
    }
}

enum Onboarding {
    static let fdaDeclinedKey = "onboarding.fullDiskAccessDeclined"

    /// Show the window at launch when App Management is missing, or Full Disk Access is missing
    /// and the user has not set it aside before.
    static func needed(_ states: [MacPermission: PermissionState]) -> Bool {
        if states[.appManagement] != .granted { return true }
        return states[.fullDiskAccess] == .denied && !UserDefaults.standard.bool(forKey: fdaDeclinedKey)
    }

    static func openSettings(_ permission: MacPermission) {
        for url in permission.settingsURLs where NSWorkspace.shared.open(url) { return }
    }

    /// Full Disk Access often takes effect only in a new process.
    static func relaunch() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundlePath]
        try? process.run()
        NSApp.terminate(nil)
    }
}

/// One language, following the system's preferred language (Chinese or English).
enum L {
    static let zh = Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") ?? false
    static func s(_ zh: String, _ en: String) -> String { Self.zh ? zh : en }
}

private extension MacPermission {
    var symbol: String { self == .appManagement ? "app.badge.checkmark" : "internaldrive" }
    var title: String { self == .appManagement ? L.s("App 管理", "App Management") : L.s("完全磁盘访问权限", "Full Disk Access") }
    var why: String {
        self == .appManagement
            ? L.s("卸载和还原时要把 /Applications 里的应用换成入口、再换回来。必需。",
                  "Needed to swap apps in /Applications for their launchers and back. Required.")
            : L.s("读取受保护的文件夹，用于磁盘占用分析，并避免 iCloud 仓库卡住。建议开启。",
                  "Reads protected folders for the usage map and keeps an iCloud repo from stalling. Recommended.")
    }
}

/// The app icon as a drag source: dropping it on a System Settings privacy list adds the app.
private struct DraggableAppIcon: View {
    var size: CGFloat = 64
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
            .resizable()
            .frame(width: size, height: size)
            .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }
            .help(L.s("拖到系统设置的列表里", "Drag into the list in System Settings"))
    }
}

private struct StatusBadge: View {
    let state: PermissionState
    var body: some View {
        switch state {
        case .granted:
            Label(L.s("已授权", "Granted"), systemImage: "checkmark.circle.fill").foregroundColor(.green)
        case .denied:
            Label(L.s("未授权", "Not granted"), systemImage: "exclamationmark.circle.fill").foregroundColor(.orange)
        case .unknown:
            Label(L.s("无法检测", "Can't check"), systemImage: "questionmark.circle").foregroundColor(.secondary)
        }
    }
}

private struct PermissionRow: View {
    let permission: MacPermission
    @ObservedObject var model: PermissionModel
    let open: (MacPermission) -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: permission.symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(permission.title).font(.headline)
                    Spacer()
                    StatusBadge(state: model.state(permission)).font(.callout)
                }
                Text(permission.why).font(.callout)
                if model.missing.contains(permission) || model.state(permission) == .unknown {
                    Button { open(permission) } label: { Text(L.s("打开系统设置", "Open Settings")) }
                        .padding(.top, 4)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: PermissionModel
    let open: (MacPermission) -> Void
    let recheck: () -> Void
    let later: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                DraggableAppIcon(size: 56)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L.s("开始前，给 Disklessly 两项权限", "Before you start, give Disklessly two permissions")).font(.title2).bold()
                }
            }
            ForEach(MacPermission.allCases, id: \.self) { permission in
                PermissionRow(permission: permission, model: model, open: open)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L.s("在系统设置里打开 Disklessly 的开关；列表里没有它时，把图标（或下方小窗里的图标）拖进去。macOS 不会为这两项弹出允许对话框。",
                         "Turn Disklessly on in System Settings; drag the icon in if it is not listed. macOS shows no prompt for these two."))
                    .font(.callout)
                Text(L.s("开关已打开但仍显示未授权时，重新打开 Disklessly 即可生效。", "If the switch is on but this still says not granted, relaunch Disklessly."))
                    .font(.caption).foregroundColor(.secondary).padding(.top, 4)
            }
            HStack {
                Button(L.s("重新检查", "Check again"), action: recheck)
                Button(L.s("重新打开", "Relaunch")) { Onboarding.relaunch() }
                Spacer()
                Button(L.s("稍后", "Later"), action: later)
                Button(L.s("开始使用", "Continue"), action: done)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.requiredGranted)
            }
        }
        .padding(22)
        .frame(width: 580)
    }
}

/// Floats over System Settings. Lists every permission still missing, not only the one whose
/// pane was opened, with a button to jump to each pane.
private struct DragHelperView: View {
    @ObservedObject var model: PermissionModel
    let open: (MacPermission) -> Void
    let close: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            DraggableAppIcon(size: 52)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(MacPermission.allCases, id: \.self) { permission in
                    HStack(spacing: 6) {
                        if model.state(permission) == .granted {
                            Label(L.s("\(permission.title)已授权", "\(permission.title) granted"), systemImage: "checkmark.circle.fill").foregroundColor(.green)
                        } else {
                            Label(L.s("在「\(permission.title)」里打开 Disklessly 的开关", "Turn Disklessly on under \(permission.title)"),
                                  systemImage: permission.required ? "exclamationmark.circle.fill" : "circle")
                                .foregroundColor(permission.required ? .orange : .primary)
                            Spacer(minLength: 4)
                            Button(L.s("前往", "Go")) { open(permission) }.controlSize(.small)
                        }
                    }
                    .font(.callout)
                }
                Text(L.s("开关已在列表里但是关着时，直接打开；没有 Disklessly 时把图标拖进去。",
                         "Turn the switch on if Disklessly is listed; otherwise drag the icon in."))
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer(minLength: 8)
            Button(L.s("完成", "Done"), action: close)
        }
        .padding(16)
        .frame(width: 500)
    }
}

final class OnboardingController: NSObject, NSWindowDelegate {
    private let model = PermissionModel()
    private var window: NSWindow?
    private var panel: NSPanel?
    private var timer: Timer?
    private var activeObserver: NSObjectProtocol?
    private var finished: (() -> Void)?

    init(initial: [MacPermission: PermissionState]) {
        super.init()
        model.states = initial
    }

    func show(onFinish: @escaping () -> Void) {
        finished = onFinish
        if window == nil {
            let view = OnboardingView(
                model: model,
                open: { [weak self] in self?.openSettings($0) },
                recheck: { [weak self] in self?.model.refresh(appManagement: true) },
                later: { [weak self] in
                    if self?.model.state(.fullDiskAccess) == .denied { UserDefaults.standard.set(true, forKey: Onboarding.fdaDeclinedKey) }
                    self?.finish()
                },
                done: { [weak self] in self?.finish() }
            )
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Disklessly"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Full Disk Access is polled; App Management is checked when the user comes back to the app.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.model.refresh(appManagement: false) }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.model.refresh(appManagement: true)
        }
        model.refresh(appManagement: true)
    }

    private func openSettings(_ permission: MacPermission) {
        Onboarding.openSettings(permission)
        showPanel()
    }

    /// A small floating panel at the bottom of the screen with the draggable icon. It stays above
    /// System Settings without taking focus from it.
    private func showPanel() {
        if let panel, panel.isVisible { return }
        panel?.close()
        let panel = NSPanel(contentRect: .zero, styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Disklessly"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentViewController = NSHostingController(rootView: DragHelperView(model: model, open: { Onboarding.openSettings($0) }, close: { [weak panel] in panel?.close() }))
        if let screen = NSScreen.main?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.minY + 40))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func finish() {
        let done = finished
        finished = nil
        teardown()
        window?.close()
        done?()
    }

    private func teardown() {
        timer?.invalidate(); timer = nil
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        activeObserver = nil
        panel?.close(); panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        teardown()
        if let done = finished { finished = nil; done() }
    }
}
#endif
