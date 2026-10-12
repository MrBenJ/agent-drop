/// Short ids (spec §3.1): 6 chars from a 32-symbol alphabet with no 0/o or 1/l.
public enum DropID {
    public static let alphabet: [Character] = Array("abcdefghijkmnpqrstuvwxyz23456789")
    public static let length = 6

    public static func generate() -> String {
        random(length: length)
    }

    /// Random id for a store (spec §5.3 `storeId`).
    public static func storeID() -> String {
        random(length: 12)
    }

    public static func isWellFormed(_ value: String) -> Bool {
        value.count == length && value.allSatisfy { alphabet.contains($0) }
    }

    private static func random(length: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
    }
}
