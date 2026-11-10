import Foundation
import SMCore

// usage: sm-bench [path] [threads]
let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : NSHomeDirectory()
let threads = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 0 : 0
let scanner = threads > 0 ? SizeScanner(threads: threads) : SizeScanner()
let node = scanner.node(forPath: path)
let t0 = Date()
scanner.scan(node)
var lastPrint = Date()
while !node.isDone {
    usleep(5_000)
    if Date().timeIntervalSince(lastPrint) > 1 {
        lastPrint = Date()
        FileHandle.standardError.write(Data("  … \(ByteFormat.string(node.totalBytes)), \(node.itemCount) items\n".utf8))
    }
}
let dt = Date().timeIntervalSince(t0)
print("path:    \(path)")
print("size:    \(ByteFormat.string(node.totalBytes))")
print("items:   \(node.itemCount)  dirs: \(scanner.dirsScanned.load(ordering: .relaxed))  denied: \(scanner.denied.load(ordering: .relaxed))")
print(String(format: "time:    %.3f s  (%.0f items/s)", dt, Double(node.itemCount) / dt))
let top = scanner.children(of: node).sorted { $0.totalBytes > $1.totalBytes }.prefix(8)
for c in top { print("  \(ByteFormat.string(c.totalBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(c.name)") }
