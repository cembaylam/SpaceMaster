import Foundation
import Testing
@testable import SMCore

@Test func byteFormatting() {
    #expect(ByteFormat.string(0) == "0 B")
    #expect(ByteFormat.string(999) == "999 B")
    #expect(ByteFormat.string(2_510_000_000) == "2.51 GB")
    #expect(ByteFormat.string(25_100_000_000) == "25.1 GB")
    #expect(ByteFormat.string(251_000_000_000) == "251 GB")
}

@Test func scannerSumsFilesAndAgreesWithTree() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sm-test-\(UUID().uuidString)")
    let fm = FileManager.default
    try fm.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
    try fm.createDirectory(at: root.appendingPathComponent("c"), withIntermediateDirectories: true)
    try Data(repeating: 1, count: 300_000).write(to: root.appendingPathComponent("a/b/big.bin"))
    try Data(repeating: 1, count: 100_000).write(to: root.appendingPathComponent("a/small.bin"))
    try Data(repeating: 1, count: 50_000).write(to: root.appendingPathComponent("c/x.bin"))
    defer { try? fm.removeItem(at: root) }

    let scanner = SizeScanner(threads: 4)
    let path = root.resolvingSymlinksInPath().path
    let node = scanner.node(forPath: path)
    scanner.scan(node)
    let deadline = Date().addingTimeInterval(10)
    while !node.isDone && Date() < deadline { usleep(2000) }
    #expect(node.isDone)
    #expect(node.totalBytes >= 450_000 && node.totalBytes < 520_000)
    let kids = scanner.children(of: node).sorted { $0.name < $1.name }
    #expect(kids.map(\.name) == ["a", "c"])
    #expect(kids[0].totalBytes > kids[1].totalBytes)
    // Deleting a directory subtracts it from ancestors.
    let before = node.totalBytes
    scanner.didRemoveDirectory(kids[1])
    #expect(node.totalBytes == before - kids[1].totalBytes)
}

@Test func safetyRules() {
    let c = SafetyClassifier(home: "/Users/test")
    #expect(c.classify(path: "/System/Library/CoreServices", flags: 0).level == .protected)
    #expect(c.classify(path: "/usr/bin/ls", flags: 0).level == .protected)
    #expect(c.classify(path: "/Users/test", flags: 0).level == .protected)
    #expect(c.classify(path: "/Users/test/Documents", flags: 0).level == .protected)
    #expect(c.classify(path: "/Users/test/Library/Keychains", flags: 0).level == .protected)
    #expect(c.classify(path: "/tmp/whatever", flags: FSFlags.restricted).level == .protected)
    #expect(c.classify(path: "/Volumes/Backup", flags: 0).level == .protected)
}

@Test func mixedFoldersContainingDeletableItems() {
    let c = SafetyClassifier(home: "/Users/test")
    let home = c.context(forDirectory: "/Users/test")
    #expect(c.classify(name: "Documents", flags: 0, isDirectory: true, in: home).level == .mixed)
    #expect(c.classify(name: ".ssh", flags: 0, isDirectory: true, in: home).level == .protected)
    #expect(c.classify(name: "Library", flags: 0, isDirectory: true, in: home).level == .mixed)
    let root = c.context(forDirectory: "/")
    #expect(c.classify(name: "Users", flags: 0, isDirectory: true, in: root).level == .mixed)
    #expect(c.classify(name: "bin", flags: 0, isDirectory: true, in: root).level == .protected)
    #expect(c.classify(name: "System", flags: 0, isDirectory: true, in: root).level == .protected)
    let lib = c.context(forDirectory: "/Users/test/Library")
    #expect(c.classify(name: "Keychains", flags: 0, isDirectory: true, in: lib).level == .protected)
    #expect(c.classify(name: "Application Support", flags: 0, isDirectory: true, in: lib).level == .mixed)
}
