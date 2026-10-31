import Foundation
import Crypto
import DisklesslyCore

// Maintainer-only tool. The private key is a file you keep offline (back it up in a password manager).
//
//   swift run disklessly-license keygen  [--dir DIR]                  new key pair; prints the public key
//   swift run disklessly-license issue   --edition pro|promo [--email E] [--expires YYYY-MM-DD]
//                                        [--updates-until YYYY-MM-DD] [--dir DIR]
//   swift run disklessly-license verify  CODE [--key BASE64_PUBLIC_KEY]
//
// DIR defaults to ~/.disklessly-license and holds private.key (base64, mode 600).

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("disklessly-license: \(message)\n".utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { fail("usage: keygen | issue | verify") }
let command = args.removeFirst()

func option(_ name: String) -> String? {
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    let value = args[index + 1]
    args.removeSubrange(index...index + 1)
    return value
}

let dir = URL(fileURLWithPath: option("--dir") ?? NSHomeDirectory() + "/.disklessly-license")
let keyFile = dir.appendingPathComponent("private.key")

func today() -> String { License.day(Date()) }

switch command {
case "keygen":
    if FileManager.default.fileExists(atPath: keyFile.path) { fail("\(keyFile.path) already exists; refusing to overwrite a license key") }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let key = Curve25519.Signing.PrivateKey()
    try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: keyFile, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
    print("private key: \(keyFile.path)  (back it up; without it no new codes can be issued)")
    print("public key:  \(key.publicKey.rawRepresentation.base64EncodedString())")
case "issue":
    guard let edition = option("--edition"), ["pro", "promo"].contains(edition) else { fail("--edition pro|promo is required") }
    let email = option("--email"), expires = option("--expires"), updates = option("--updates-until")
    if edition == "promo", expires == nil { fail("a promo code needs --expires YYYY-MM-DD") }
    guard let raw = try? Data(contentsOf: keyFile), let text = String(data: raw, encoding: .utf8),
          let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else { fail("cannot read \(keyFile.path); run keygen first") }
    let id = UUID().uuidString.prefix(8).lowercased()
    let payload = LicensePayload(id: String(id), edition: edition, email: email, issued: today(), expires: expires, updatesUntil: updates)
    print(try License.issue(payload, privateKey: key))
case "verify":
    let publicKey: Curve25519.Signing.PublicKey?
    if let b64 = option("--key") {
        publicKey = Data(base64Encoded: b64).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    } else if let raw = try? Data(contentsOf: keyFile), let text = String(data: raw, encoding: .utf8),
              let seed = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) {
        publicKey = key.publicKey
    } else {
        publicKey = License.publicKey
    }
    guard let code = args.first else { fail("verify CODE") }
    print(License.verify(code, publicKey: publicKey))
default:
    fail("unknown command \(command)")
}
