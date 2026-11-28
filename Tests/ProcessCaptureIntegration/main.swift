import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func makeProcess(_ script: String) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    return process
}

let large = makeProcess("yes o | head -c 1048576; yes e | head -c 1048576 >&2")
let startedLarge = Date()
let largeResult = try ProcessCapture.run(large, timeout: 10)
let largeSeconds = Date().timeIntervalSince(startedLarge)
check(!largeResult.timedOut, "large dual-stream capture timed out")
check(largeResult.status == 0, "large dual-stream capture exited \(largeResult.status)")
check(largeResult.stdout.count == 1_048_576, "stdout was truncated: \(largeResult.stdout.count)")
check(largeResult.stderr.count == 1_048_576, "stderr was truncated: \(largeResult.stderr.count)")

let unbounded = makeProcess("printf unbounded-stdout; printf unbounded-stderr >&2")
let unboundedResult = try ProcessCapture.run(unbounded)
check(!unboundedResult.timedOut, "no-timeout capture reported a timeout")
check(unboundedResult.status == 0, "no-timeout capture exited \(unboundedResult.status)")
check(unboundedResult.stdout == Data("unbounded-stdout".utf8), "no-timeout stdout changed")
check(unboundedResult.stderr == Data("unbounded-stderr".utf8), "no-timeout stderr changed")

let grandchild = makeProcess("(sleep 5) & echo done")
let startedGrandchild = Date()
let grandchildResult = try ProcessCapture.run(grandchild, timeout: 0.5)
let grandchildSeconds = Date().timeIntervalSince(startedGrandchild)
check(grandchildResult.timedOut, "grandchild-held pipes bypassed the timeout")
check(grandchildResult.status == 0, "direct child status was \(grandchildResult.status)")
check(grandchildResult.stdout == Data("done\n".utf8), "direct child output was not preserved")
check(grandchildSeconds < 2, "grandchild-held pipes took \(grandchildSeconds)s")

let ignoresTerm = makeProcess("trap '' TERM; while :; do :; done")
let startedIgnore = Date()
let ignoreResult = try ProcessCapture.run(ignoresTerm, timeout: 0.25)
let ignoreSeconds = Date().timeIntervalSince(startedIgnore)
check(ignoreResult.timedOut, "SIGTERM-ignoring child did not time out")
check(!ignoresTerm.isRunning, "SIGTERM-ignoring child was not escalated to SIGKILL")
check(ignoreSeconds < 3, "SIGTERM-ignoring child took \(ignoreSeconds)s")

print(String(
    format: "process-capture-ok large=%.3fs grandchild=%.3fs sigterm-ignore=%.3fs",
    largeSeconds,
    grandchildSeconds,
    ignoreSeconds
))
