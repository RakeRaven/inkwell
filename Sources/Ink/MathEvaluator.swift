import Foundation

enum MathEvaluator {
    /// Common misreads of handwritten math, mapped to parser symbols.
    private static let replacements: [(String, String)] = [
        ("×", "*"), ("x", "*"), ("X", "*"), ("·", "*"), ("•", "*"),
        ("÷", "/"), (":", "/"),
        ("−", "-"), ("–", "-"), ("—", "-"), ("_", "-"),
        ("O", "0"), ("o", "0"), ("l", "1"), ("I", "1"), ("|", "1"),
        ("[", "("), ("]", ")"), ("{", "("), ("}", ")"),
        (",", ""), (" ", ""), ("=", ""),
    ]

    /// Evaluates arithmetic like "12 × 3 + 4"; nil unless it parses and has an operator.
    static func evaluate(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for (from, to) in replacements {
            s = s.replacingOccurrences(of: from, with: to)
        }
        let allowed = Set("0123456789.+-*/^%()")
        guard !s.isEmpty,
              s.allSatisfy({ allowed.contains($0) }),
              s.dropFirst().contains(where: { "+-*/^".contains($0) }) else { return nil }
        var parser = Parser(chars: Array(s))
        guard let value = parser.expression(), parser.atEnd, value.isFinite else { return nil }
        return format(value)
    }

    static func format(_ value: Double) -> String {
        if value.rounded() == value, abs(value) < 1e15 {
            return String(Int64(value))
        }
        return value.formatted(.number.precision(.significantDigits(1...10)).grouping(.never))
    }

    /// Recursive descent: + - over * / (and implicit "2(3)") over unary minus over ^ over numbers, parens, %.
    private struct Parser {
        let chars: [Character]
        var i = 0

        var atEnd: Bool { i == chars.count }
        private var peek: Character? { i < chars.count ? chars[i] : nil }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let op = peek, op == "+" || op == "-" {
                i += 1
                guard let rhs = term() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func term() -> Double? {
            guard var value = unary() else { return nil }
            while let op = peek, op == "*" || op == "/" || op == "(" {
                if op != "(" { i += 1 }
                guard let rhs = unary() else { return nil }
                value = op == "/" ? value / rhs : value * rhs
            }
            return value
        }

        mutating func unary() -> Double? {
            if peek == "-" {
                i += 1
                return unary().map { -$0 }
            }
            if peek == "+" {
                i += 1
                return unary()
            }
            return power()
        }

        mutating func power() -> Double? {
            guard let base = primary() else { return nil }
            guard peek == "^" else { return base }
            i += 1
            guard let exponent = unary() else { return nil }
            return pow(base, exponent)
        }

        mutating func primary() -> Double? {
            var value: Double
            if peek == "(" {
                i += 1
                guard let inner = expression(), peek == ")" else { return nil }
                i += 1
                value = inner
            } else {
                let start = i
                while let c = peek, c.isASCII, c.isNumber || c == "." { i += 1 }
                guard i > start, let number = Double(String(chars[start..<i])) else { return nil }
                value = number
            }
            while peek == "%" {
                i += 1
                value /= 100
            }
            return value
        }
    }
}
