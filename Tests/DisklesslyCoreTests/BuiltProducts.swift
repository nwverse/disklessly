import Foundation

/// `disklessly` from the same build as this test runner, if it was built.
func builtCLISibling() -> URL? {
    let fm = FileManager.default
    #if os(Linux)
    // Bundle.allBundles crashes in swift-corelibs-foundation 6.0. On Linux the test
    // runner is an executable next to the products, also under --scratch-path.
    let runner = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let sibling = runner.deletingLastPathComponent().appendingPathComponent("disklessly")
    return fm.isExecutableFile(atPath: sibling.path) ? sibling : nil
    #else
    for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
        let sibling = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("disklessly")
        if fm.isExecutableFile(atPath: sibling.path) { return sibling }
    }
    return nil
    #endif
}
