import Foundation

public enum DiskImageBackend: Equatable {
    case diskutil
    case hdiutil
}

public struct DiskImageInvocation: Equatable {
    public var executable: String
    public var arguments: [String]
    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
    public var rendered: String { ([executable] + arguments).joined(separator: " ") }
}

public struct DiskImageOutput: Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

/// Attach and detach commands. `diskutil image` is preferred when its help
/// command exits 0. Image creation stays on `hdiutil create` (ULMO); `diskutil
/// image create` is not used. `diskutil image attach` has no `--noautoopen`;
/// `--mountOptions nobrowse` is the documented Finder suppression. There is no
/// `diskutil image detach`; detach is `diskutil eject`, and a forced detach
/// that fails falls through to `diskutil unmount force`.
public enum DiskImageTool {
    public static let diskutil = "/usr/sbin/diskutil"
    public static let hdiutil = "/usr/bin/hdiutil"

    /// Exit status of `diskutil image --help`. The help text is not read.
    /// Zero means the `image` subcommand exists.
    public static func select(diskutilImageHelpStatus: Int32) -> DiskImageBackend {
        diskutilImageHelpStatus == 0 ? .diskutil : .hdiutil
    }

    public static func attachCommand(image: String, mountPoint: String, backend: DiskImageBackend) -> DiskImageInvocation {
        switch backend {
        case .diskutil:
            return DiskImageInvocation(
                executable: diskutil,
                arguments: ["image", "attach", "--plist", "--readOnly", "--mountOptions", "nobrowse", "--mountPoint", mountPoint, image]
            )
        case .hdiutil:
            return DiskImageInvocation(
                executable: hdiutil,
                arguments: ["attach", "-plist", "-readonly", "-nobrowse", "-noautoopen", "-mountpoint", mountPoint, image]
            )
        }
    }

    /// Forced diskutil detach is two commands: `eject force`, then `unmount force`
    /// only if eject did not exit 0. hdiutil force is one `detach -force`.
    public static func detachCommands(mountPoint: String, force: Bool, backend: DiskImageBackend) -> [DiskImageInvocation] {
        switch backend {
        case .diskutil:
            if force {
                return [
                    DiskImageInvocation(executable: diskutil, arguments: ["eject", "force", mountPoint]),
                    DiskImageInvocation(executable: diskutil, arguments: ["unmount", "force", mountPoint]),
                ]
            }
            return [DiskImageInvocation(executable: diskutil, arguments: ["eject", mountPoint])]
        case .hdiutil:
            if force {
                return [DiskImageInvocation(executable: hdiutil, arguments: ["detach", "-force", mountPoint])]
            }
            return [DiskImageInvocation(executable: hdiutil, arguments: ["detach", mountPoint])]
        }
    }

    public static func failureMessage(command: DiskImageInvocation, output: DiskImageOutput) -> String {
        let detail = String(data: output.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "Command failed: \(command.rendered) (exit \(output.status))\(detail.isEmpty ? "" : "\n\(detail)")"
    }

    /// Success is exit 0 and a plist that lists the requested mount point.
    /// The tool's sentence is stored on a non-zero exit and is not matched.
    public static func classifyAttach(command: DiskImageInvocation, output: DiskImageOutput, mountPoint: String) throws {
        guard output.status == 0 else {
            throw DisklesslyError.diskImage(failureMessage(command: command, output: output))
        }
        guard plistListsMountPoint(output.stdout, mountPoint) else {
            throw DisklesslyError.diskImage("attach exited 0 but the plist did not list mount point \(mountPoint)")
        }
    }

    /// Runs the detach sequence. A forced diskutil detach stops after the first
    /// command that exits 0. Classification is the exit status only.
    public static func classifyDetach(commands: [DiskImageInvocation], outputs: [DiskImageOutput]) throws {
        guard let command = commands.first, let output = outputs.first else {
            throw DisklesslyError.diskImage("detach produced no command result")
        }
        if commands.count == 1 || output.status == 0 {
            guard output.status == 0 else {
                throw DisklesslyError.diskImage(failureMessage(command: command, output: output))
            }
            return
        }
        guard outputs.count > 1 else {
            throw DisklesslyError.diskImage(failureMessage(command: command, output: output))
        }
        let second = commands[1]
        let secondOutput = outputs[1]
        guard secondOutput.status == 0 else {
            throw DisklesslyError.diskImage(failureMessage(command: second, output: secondOutput))
        }
    }

    public static func plistListsMountPoint(_ data: Data, _ mountPoint: String) -> Bool {
        guard let object = propertyList(data) else { return false }
        let wanted = pathForms(mountPoint)
        return containsPath(object, wanted)
    }

    private static func propertyList(_ data: Data) -> Any? {
        if let object = try? PropertyListSerialization.propertyList(from: data, format: nil) { return object }
        let xml = Data("<?xml".utf8)
        let binary = Data("bplist00".utf8)
        for marker in [xml, binary] {
            if let range = data.range(of: marker) {
                let slice = data.subdata(in: range.lowerBound..<data.endIndex)
                if let object = try? PropertyListSerialization.propertyList(from: slice, format: nil) { return object }
            }
        }
        return nil
    }

    private static func containsPath(_ value: Any, _ wanted: Set<String>) -> Bool {
        if let string = value as? String {
            return !pathForms(string).isDisjoint(with: wanted)
        }
        if let list = value as? [Any] {
            return list.contains { containsPath($0, wanted) }
        }
        if let dict = value as? [String: Any] {
            return dict.values.contains { containsPath($0, wanted) }
        }
        if let list = value as? NSArray {
            return list.contains { containsPath($0, wanted) }
        }
        if let dict = value as? NSDictionary {
            for key in dict.allKeys {
                if containsPath(dict.object(forKey: key) as Any, wanted) { return true }
            }
        }
        return false
    }

    static func pathForms(_ path: String) -> Set<String> {
        var forms: Set<String> = [path]
        let url = URL(fileURLWithPath: path)
        forms.insert(url.standardizedFileURL.path)
        forms.insert(url.resolvingSymlinksInPath().path)
        let pairs = [("/private/var", "/var"), ("/private/tmp", "/tmp"), ("/private/etc", "/etc")]
        let seed = forms
        for form in seed {
            for (long, short) in pairs {
                if form == long || form.hasPrefix(long + "/") {
                    forms.insert(short + String(form.dropFirst(long.count)))
                } else if form == short || form.hasPrefix(short + "/") {
                    forms.insert(long + String(form.dropFirst(short.count)))
                }
            }
        }
        return forms
    }
}
