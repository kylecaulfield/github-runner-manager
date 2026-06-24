import Foundation

/// Dotted-numeric version comparison for GitHub Actions runner versions
/// (e.g. "2.335.1" vs "v2.335.0"). Strips a leading 'v' and surrounding whitespace.
enum Version {
    /// Strip a leading 'v'/'V' and surrounding whitespace from a version string.
    static func normalize(_ s: String) -> String {
        var trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, first == "v" || first == "V" {
            trimmed.removeFirst()
        }
        // Trim again in case there was whitespace between the 'v' and the digits.
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Compare two dotted-numeric version strings component by component.
    /// Missing trailing components are treated as 0 (so "2.335" == "2.335.0").
    /// Non-numeric components are treated as 0.
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let aParts = components(normalize(a))
        let bParts = components(normalize(b))
        let count = max(aParts.count, bParts.count)
        for index in 0..<count {
            let aValue = index < aParts.count ? aParts[index] : 0
            let bValue = index < bParts.count ? bParts[index] : 0
            if aValue < bValue { return .orderedAscending }
            if aValue > bValue { return .orderedDescending }
        }
        return .orderedSame
    }

    /// True iff `candidate` is strictly newer than `current`.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    /// Split a normalized version into its numeric components.
    /// ASSUMPTION: components are dotted integers; any non-numeric component maps to 0.
    private static func components(_ normalized: String) -> [Int] {
        normalized
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
    }
}
