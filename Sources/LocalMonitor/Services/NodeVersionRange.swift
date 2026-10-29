import Foundation

/// Stable Node releases and the numeric subset of npm semver used by runtime declarations.
struct NodeVersion: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ text: String) throws {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2]),
              [major, minor, patch].allSatisfy({ $0 < Int.max - 1 }) else {
            throw NodeRuntimeError.unsupported(text)
        }
        self.init(major, minor, patch)
    }

    init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    var description: String { "\(major).\(minor).\(patch)" }
}

struct NodeVersionRange {
    private enum Bound {
        case atLeast(NodeVersion), greater(NodeVersion), less(NodeVersion), atMost(NodeVersion)

        func contains(_ version: NodeVersion) -> Bool {
            switch self {
            case .atLeast(let value): return version >= value
            case .greater(let value): return version > value
            case .less(let value): return version < value
            case .atMost(let value): return version <= value
            }
        }
    }

    private struct Partial {
        let numbers: [Int]
        var lower: NodeVersion {
            NodeVersion(numbers.first ?? 0, numbers.count > 1 ? numbers[1] : 0,
                        numbers.count > 2 ? numbers[2] : 0)
        }
        var upper: NodeVersion? {
            switch numbers.count {
            case 1: return NodeVersion(numbers[0] + 1)
            case 2: return NodeVersion(numbers[0], numbers[1] + 1)
            default: return nil
            }
        }

        init(_ text: String) throws {
            let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
            let parts = value.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count) else { throw NodeRuntimeError.unsupported(text) }
            var numbers: [Int] = []
            var wildcard = false
            for part in parts {
                if ["x", "X", "*"].contains(String(part)) {
                    wildcard = true
                } else {
                    guard !wildcard, !part.isEmpty, part.allSatisfy(\.isNumber),
                          let number = Int(part), number < Int.max - 1 else {
                        throw NodeRuntimeError.unsupported(text)
                    }
                    numbers.append(number)
                }
            }
            self.numbers = numbers
        }
    }

    private let alternatives: [[Bound]]

    init(_ text: String) throws {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"([<>=~^]+)\s+"#, with: "$1", options: .regularExpression)
        guard !normalized.isEmpty else { throw NodeRuntimeError.unsupported(text) }
        alternatives = try normalized.components(separatedBy: "||").map { alternative in
            let hyphen = alternative.components(separatedBy: " - ")
            if hyphen.count == 2 {
                let lower = try Partial(hyphen[0].trimmingCharacters(in: .whitespaces))
                let upper = try Partial(hyphen[1].trimmingCharacters(in: .whitespaces))
                guard !lower.numbers.isEmpty, !upper.numbers.isEmpty else {
                    throw NodeRuntimeError.unsupported(text)
                }
                return [.atLeast(lower.lower), upper.upper.map(Bound.less) ?? .atMost(upper.lower)]
            }
            let tokens = alternative.split(whereSeparator: \.isWhitespace)
            guard !tokens.isEmpty else { throw NodeRuntimeError.unsupported(text) }
            return try tokens.flatMap { token -> [Bound] in
                let op = String(token.prefix { "<>=~^".contains($0) })
                let partial = try Partial(String(token.dropFirst(op.count)))
                let lower = partial.lower
                switch op {
                case "", "=":
                    if partial.numbers.isEmpty { return [] }
                    return [.atLeast(lower), partial.upper.map(Bound.less) ?? .atMost(lower)]
                case ">=": return partial.numbers.isEmpty ? [] : [.atLeast(lower)]
                case ">":
                    if partial.numbers.isEmpty { return [.less(NodeVersion(0))] }
                    return partial.upper.map { [.atLeast($0)] } ?? [.greater(lower)]
                case "<": return [.less(lower)]
                case "<=":
                    if partial.numbers.isEmpty { return [] }
                    return [partial.upper.map(Bound.less) ?? .atMost(lower)]
                case "~":
                    if partial.numbers.isEmpty { return [] }
                    let upper = partial.numbers.count == 1
                        ? NodeVersion(lower.major + 1) : NodeVersion(lower.major, lower.minor + 1)
                    return [.atLeast(lower), .less(upper)]
                case "^":
                    if partial.numbers.isEmpty { return [] }
                    let upper: NodeVersion
                    if lower.major > 0 || partial.numbers.count == 1 {
                        upper = NodeVersion(lower.major + 1)
                    } else if lower.minor > 0 || partial.numbers.count == 2 {
                        upper = NodeVersion(0, lower.minor + 1)
                    } else {
                        upper = NodeVersion(0, 0, lower.patch + 1)
                    }
                    return [.atLeast(lower), .less(upper)]
                default: throw NodeRuntimeError.unsupported(text)
                }
            }
        }
    }

    func contains(_ version: NodeVersion) -> Bool {
        alternatives.contains { bounds in bounds.allSatisfy { $0.contains(version) } }
    }
}
