import Foundation

/// Finder-style decimal byte formatting ("2.51 GB", "25.1 GB", "251 GB").
public enum ByteFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    public static func string(_ bytes: Int64) -> String {
        if bytes < 1000 { return "\(max(0, bytes)) B" }
        var v = Double(bytes)
        var u = 0
        while v >= 1000, u < units.count - 1 { v /= 1000; u += 1 }
        let tenths = (v * 10).rounded() / 10
        if v >= 100 || u == 1 && v >= 10 {
            return "\(Int(v.rounded())) \(units[u])"
        } else if v >= 10 {
            return "\(Int(tenths)).\(Int((tenths * 10).rounded()) % 10) \(units[u])"
        } else {
            let h = Int((v * 100).rounded())
            return "\(h / 100).\(h % 100 < 10 ? "0" : "")\(h % 100) \(units[u])"
        }
    }

    public static func count(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
