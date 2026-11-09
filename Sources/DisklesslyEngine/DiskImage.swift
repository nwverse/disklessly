import Foundation
import DisklesslyCore

enum LiveDiskImage {
    private static var cachedBackend: DiskImageBackend?

    static func backend() -> DiskImageBackend {
        if let cachedBackend { return cachedBackend }
        let selected = DiskImageTool.select(diskutilImageHelpStatus: diskutilImageHelpStatus())
        cachedBackend = selected
        return selected
    }

    static func attach(image: URL, mountPoint: URL) throws {
        let command = DiskImageTool.attachCommand(image: image.path, mountPoint: mountPoint.path, backend: backend())
        let output = try capture(command)
        try DiskImageTool.classifyAttach(command: command, output: output, mountPoint: mountPoint.path)
    }

    static func detach(mountPoint: URL, force: Bool) throws {
        let commands = DiskImageTool.detachCommands(mountPoint: mountPoint.path, force: force, backend: backend())
        var outputs: [DiskImageOutput] = []
        for command in commands {
            let output = try capture(command)
            outputs.append(output)
            if output.status == 0 { break }
            if !force || commands.count == 1 { break }
        }
        try DiskImageTool.classifyDetach(commands: Array(commands.prefix(outputs.count)), outputs: outputs)
    }

    /// `diskutil image --help` exits 0 when the subcommand exists. Its text is discarded.
    private static func diskutilImageHelpStatus() -> Int32 {
        #if os(macOS)
        let process = ParsedCommand.process(path: DiskImageTool.diskutil, arguments: ["image", "--help"])
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return 1 }
        process.waitUntilExit()
        return process.terminationStatus
        #else
        return 1
        #endif
    }

    private static func capture(_ command: DiskImageInvocation) throws -> DiskImageOutput {
        let process = ParsedCommand.process(path: command.executable, arguments: command.arguments)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch {
            throw DisklesslyError.failure("Could not start \(command.rendered): \(error.localizedDescription)")
        }
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return DiskImageOutput(status: process.terminationStatus, stdout: out, stderr: err)
    }
}
