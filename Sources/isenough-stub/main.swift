import Foundation
#if os(macOS)
import AppKit

@main struct StubLauncher {
    static func main() {
        let bundle = Bundle.main
        let resource = bundle.bundleURL.appendingPathComponent("Contents/Resources/manifest.json")
        guard let data = try? Data(contentsOf: resource),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bundleId = obj["bundleId"] as? String, !bundleId.isEmpty else {
            fputs("isenough-stub: could not read a valid app manifest\n", stderr)
            exit(1)
        }

        guard let cli = resolveCLI(in: ProcessInfo.processInfo.environment["PATH"] ?? "") else {
            fputs("isenough-stub: isenough CLI was not found on PATH\n", stderr)
            exit(1)
        }

        // Process.arguments excludes argv[0]. Put the command and app identifier
        // first; documents and URLs are options belonging to the launch command.
        let forwarded = Array(CommandLine.arguments.dropFirst())
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["launch", bundleId] + forwarded
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                fputs("isenough-stub: launch exited with status \(process.terminationStatus)\n", stderr)
                exit(process.terminationStatus)
            }
        } catch {
            fputs("isenough-stub: could not start \(cli): \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func resolveCLI(in path: String) -> String? {
        for directory in path.split(separator: ":", omittingEmptySubsequences: false) {
            let candidate = URL(fileURLWithPath: String(directory.isEmpty ? "." : directory))
                .appendingPathComponent("isenough").standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }
}
#else
@main struct StubLauncher { static func main() {} }
#endif
