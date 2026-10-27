import Foundation

enum Format {
    /// Read once: "o, Ko, Mo" in French, "B, KB, MB" in English.
    private static let units = [String(localized: "B", comment: "Byte unit"), String(localized: "KB"),
                                String(localized: "MB"), String(localized: "GB"), String(localized: "TB")]

    static func bytes(_ v: Double, decimals: Int = 1) -> String {
        var v = max(0, v)
        var i = 0
        while v >= 1000, i < units.count - 1 {
            v /= 1024
            i += 1
        }
        if i == 0 { return "\(Int(v)) \(units[0])" }
        let d = v >= 100 ? 0 : decimals
        return String(format: "%.\(d)f %@", v, units[i])
    }

    static func bytes(_ v: UInt64) -> String { bytes(Double(v)) }
    static func bytes(_ v: Int64) -> String { bytes(Double(v)) }

    static func rate(_ v: Double) -> String { bytes(v) + "/s" }

    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    /// Process CPU, already in percent of one core.
    static func cpu(_ v: Double) -> String {
        v < 10 ? String(format: "%.1f%%", v) : "\(Int(v.rounded()))%"
    }
}
