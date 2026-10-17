import Foundation

enum Secrets {
    /// Compares UTF-8 bytes with no early exit, so timing doesn't reveal how much of a
    /// token matched. A length mismatch is folded into the result after a full pass over
    /// the longer input.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) {
            diff |= Int(i < x.count ? x[i] : 0) ^ Int(i < y.count ? y[i] : 0)
        }
        return diff == 0
    }
}
