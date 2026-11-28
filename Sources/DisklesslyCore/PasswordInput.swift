import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Reads a password from standard input. A terminal submits on Return and has
/// echo disabled; redirected input keeps the historical read-to-EOF behavior so
/// existing pipelines continue to work.
public enum PasswordInput {
    public static func readPassword() throws -> String {
        try select(
            isTerminal: isatty(STDIN_FILENO) == 1,
            terminalLine: { try readSecretLine(fileDescriptor: STDIN_FILENO) },
            redirectedData: { FileHandle.standardInput.readDataToEndOfFile() }
        )
    }

    static func select(
        isTerminal: Bool,
        terminalLine: () throws -> String?,
        redirectedData: () throws -> Data
    ) throws -> String {
        let raw: String
        if isTerminal {
            raw = try terminalLine() ?? ""
        } else {
            raw = String(decoding: try redirectedData(), as: UTF8.self)
        }
        let password = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else { throw DisklesslyError.usage("password from stdin was empty") }
        return password
    }

    private static func readSecretLine(fileDescriptor: Int32) throws -> String? {
        var original = termios()
        guard tcgetattr(fileDescriptor, &original) == 0 else {
            throw DisklesslyError.failure("cannot read a password without terminal echo")
        }
        var hidden = original
        hidden.c_lflag &= ~tcflag_t(ECHO)
        guard tcsetattr(fileDescriptor, TCSAFLUSH, &hidden) == 0 else {
            throw DisklesslyError.failure("cannot hide terminal echo for the password")
        }
        FileHandle.standardError.write(Data("Password: ".utf8))
        defer {
            _ = tcsetattr(fileDescriptor, TCSAFLUSH, &original)
            FileHandle.standardError.write(Data("\n".utf8))
        }
        return readLine(strippingNewline: true)
    }
}
