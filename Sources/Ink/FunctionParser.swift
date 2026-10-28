import Foundation

/// A parsed y = f(x), ready to evaluate many times.
indirect enum Expr {
    case number(Double)
    case x
    case negate(Expr)
    case call(String, Expr)
    case binary(Character, Expr, Expr)

    func callAsFunction(_ x: Double) -> Double {
        switch self {
        case .number(let v): return v
        case .x: return x
        case .negate(let e): return -e(x)
        case .call(let name, let e):
            let v = e(x)
            switch name {
            case "sin": return sin(v)
            case "cos": return cos(v)
            case "tan": return tan(v)
            case "asin": return asin(v)
            case "acos": return acos(v)
            case "atan": return atan(v)
            case "sinh": return sinh(v)
            case "cosh": return cosh(v)
            case "tanh": return tanh(v)
            case "sqrt": return v.squareRoot()
            case "cbrt": return cbrt(v)
            case "abs": return abs(v)
            case "ln": return log(v)
            case "log": return log10(v)
            case "exp": return exp(v)
            case "floor": return floor(v)
            case "ceil": return ceil(v)
            default: return .nan
            }
        case .binary(let op, let a, let b):
            let l = a(x), r = b(x)
            switch op {
            case "+": return l + r
            case "-": return l - r
            case "*": return l * r
            case "/": return l / r
            case "^": return pow(l, r)
            default: return .nan
            }
        }
    }
}

/// Reads things like "y = 2x^2 - 3sin(x)", "f(x)=√(x+1)", "e^-x", with implicit multiplication.
enum FunctionParser {
    static let functions: Set<String> = ["sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh",
                                         "sqrt", "cbrt", "abs", "ln", "log", "exp", "floor", "ceil"]

    static func parse(_ raw: String) -> Expr? {
        var text = raw.lowercased()
        // drop a leading "y =" or "f(x) ="
        if let eq = text.firstIndex(of: "=") { text = String(text[text.index(after: eq)...]) }
        let swaps: [(String, String)] = [("\u{00D7}", "*"), ("\u{00B7}", "*"), ("\u{00F7}", "/"), ("\u{2212}", "-"),
                                         ("\u{03C0}", "pi"), ("\u{221A}", "sqrt"), ("\u{00B2}", "^2"), ("\u{00B3}", "^3"), ("**", "^")]
        for (a, b) in swaps { text = text.replacingOccurrences(of: a, with: b) }
        guard let tokens = tokenize(text), !tokens.isEmpty else { return nil }
        var parser = Parser(tokens: tokens)
        guard let expr = parser.expression(), parser.atEnd else { return nil }
        return expr
    }

    enum Token: Equatable {
        case number(Double), name(String), op(Character), open, close
    }

    private static func tokenize(_ text: String) -> [Token]? {
        var tokens: [Token] = []
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == " " {
                i += 1
            } else if c.isNumber || c == "." {
                let start = i
                while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
                guard let v = Double(String(chars[start..<i])) else { return nil }
                tokens.append(.number(v))
            } else if c.isLetter {
                let start = i
                while i < chars.count, chars[i].isLetter { i += 1 }
                tokens.append(contentsOf: splitName(String(chars[start..<i])))
            } else if "+-*/^".contains(c) {
                tokens.append(.op(c))
                i += 1
            } else if c == "(" || c == "[" {
                tokens.append(.open)
                i += 1
            } else if c == ")" || c == "]" {
                tokens.append(.close)
                i += 1
            } else {
                return nil
            }
        }
        return tokens
    }

    /// "xsinx" or "2pix" written without spaces: peel off known names, x, pi and e.
    private static func splitName(_ word: String) -> [Token] {
        var out: [Token] = []
        var rest = Substring(word)
        let names = functions.sorted { $0.count > $1.count } + ["pi", "x", "e"]
        while !rest.isEmpty {
            if let name = names.first(where: { rest.hasPrefix($0) }) {
                out.append(.name(name))
                rest = rest.dropFirst(name.count)
            } else {
                out.append(.name(String(rest)))
                break
            }
        }
        return out
    }

    private struct Parser {
        let tokens: [Token]
        var i = 0

        var atEnd: Bool { i == tokens.count }
        private var peek: Token? { i < tokens.count ? tokens[i] : nil }

        mutating func expression() -> Expr? {
            guard var value = term() else { return nil }
            while case .op(let op)? = peek, op == "+" || op == "-" {
                i += 1
                guard let rhs = term() else { return nil }
                value = .binary(op, value, rhs)
            }
            return value
        }

        /// Products, including implicit ones like 2x, 3sin(x), (x+1)(x-1).
        mutating func term() -> Expr? {
            guard var value = unary() else { return nil }
            while let next = peek {
                if case .op(let op) = next, op == "*" || op == "/" {
                    i += 1
                    guard let rhs = unary() else { return nil }
                    value = .binary(op, value, rhs)
                } else if startsFactor(next) {
                    guard let rhs = power() else { return nil }
                    value = .binary("*", value, rhs)
                } else {
                    break
                }
            }
            return value
        }

        private func startsFactor(_ token: Token) -> Bool {
            switch token {
            case .number, .name, .open: true
            default: false
            }
        }

        mutating func unary() -> Expr? {
            if case .op("-")? = peek {
                i += 1
                return unary().map { .negate($0) }
            }
            if case .op("+")? = peek {
                i += 1
                return unary()
            }
            return power()
        }

        mutating func power() -> Expr? {
            guard let base = primary() else { return nil }
            guard case .op("^")? = peek else { return base }
            i += 1
            // right-associative, and allows e^-x
            guard let exponent = unary() else { return nil }
            return .binary("^", base, exponent)
        }

        mutating func primary() -> Expr? {
            guard let token = peek else { return nil }
            i += 1
            switch token {
            case .number(let v):
                return .number(v)
            case .open:
                guard let inner = expression(), peek == .close else { return nil }
                i += 1
                return inner
            case .name(let name):
                switch name {
                case "x": return .x
                case "pi": return .number(.pi)
                case "e": return .number(M_E)
                default:
                    guard FunctionParser.functions.contains(name) else { return nil }
                    // sin x and sin(x) both work
                    guard let argument = power() else { return nil }
                    return .call(name, argument)
                }
            default:
                return nil
            }
        }
    }
}

extension GraphSpec {
    /// Rounded tick spacing: 1, 2 or 5 times a power of ten.
    static func step(for span: Double, ticks: Double = 8) -> Double {
        guard span > 0, span.isFinite else { return 1 }
        let raw = span / ticks
        let power = pow(10, floor(log10(raw)))
        let unit = raw / power
        return (unit < 1.5 ? 1 : unit < 3.5 ? 2 : unit < 7.5 ? 5 : 10) * power
    }

    /// Y range covering every curve over the current x range, with a little room.
    func fittedY() -> (Double, Double)? {
        var low = Double.infinity, high = -Double.infinity
        for f in functions.compactMap(FunctionParser.parse) {
            for i in 0...200 {
                let y = f(xMin + (xMax - xMin) * Double(i) / 200)
                guard y.isFinite, abs(y) < 1e6 else { continue }
                low = min(low, y)
                high = max(high, y)
            }
        }
        guard low.isFinite, high.isFinite else { return nil }
        if high - low < 1e-9 { return (low - 1, high + 1) }
        let pad = (high - low) * 0.1
        return (low - pad, high + pad)
    }
}
