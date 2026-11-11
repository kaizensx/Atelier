import Foundation

/// Command's calculator: a small recursive-descent parser over what a person types. It never
/// hands text to NSExpression, whose format parser raises an Objective-C exception (and so
/// aborts the app) on input such as "1+*2" or "1.2.3+1". Anything it does not understand is
/// simply not a calculation.
///
///     expression := term (('+' | '-') term)*
///     term       := unary (('*' | '/' | '%') unary | implicit-multiplication)*
///     unary      := ('-' | '+') unary | power
///     power      := postfix ('^' unary)?            right-associative: 2^3^2 = 2^9
///     postfix    := primary '%'?                    a trailing % is "per cent"
///     primary    := number | constant | function '(' expression ')' | '(' expression ')'
///
/// Functions: sqrt sin cos tan log (base 10) ln abs round. Constants: pi (π) and e. Angles are
/// radians. "x" and "×" multiply, "÷" divides, and a comma is a decimal point.
public enum Calculator {
    /// Longer input is not a calculation anyone types into Command.
    public static let maxLength = 200
    /// Parentheses and unary signs nest at most this deep, so the parser's stack stays small.
    public static let maxDepth = 64

    /// The value, or nil when the text is not a well-formed calculation or the result is not a
    /// finite number (division by zero, sqrt of a negative).
    public static func value(_ text: String) -> Double? {
        guard text.count <= maxLength, let tokens = tokenize(text), !tokens.isEmpty else { return nil }
        var parser = Parser(tokens: tokens)
        guard let result = parser.parseExpression(), parser.atEnd, result.isFinite else { return nil }
        return result
    }

    /// The answer as Command shows it, only for text that is really a calculation: a lone
    /// number, or a word like "e" or "pi", is left to the search.
    public static func evaluate(_ text: String) -> String? {
        guard looksLikeCalculation(text), let result = value(text) else { return nil }
        let rounded = abs(result) < 1e-12 ? 0 : result
        return rounded.formatted(.number.precision(.fractionLength(0...6)))
    }

    /// At least one operator or function call, with something numeric in it.
    static func looksLikeCalculation(_ text: String) -> Bool {
        guard let tokens = tokenize(text), tokens.count > 1 else { return false }
        let numeric = tokens.contains { if case .number = $0 { true } else if case .constant = $0 { true } else { false } }
        // A sign in front of a lone number ("-5") is not a sum.
        let acts = tokens.enumerated().contains { index, token in
            switch token {
            case .function: true
            case .op: index > 0
            default: false
            }
        }
        return numeric && acts
    }

    // MARK: Tokens

    enum Token: Equatable {
        case number(Double)
        case constant(Double)
        case function(String)
        case op(Character)
        case open, close
    }

    static let functionNames: Set<String> = ["sqrt", "sin", "cos", "tan", "log", "ln", "abs", "round"]

    static func apply(_ name: String, _ x: Double) -> Double? {
        switch name {
        case "sqrt": x.squareRoot()
        case "sin": sin(x)
        case "cos": cos(x)
        case "tan": tan(x)
        case "log": log10(x)
        case "ln": log(x)
        case "abs": Swift.abs(x)
        case "round": x.rounded()
        default: nil
        }
    }
    static let constants: [String: Double] = ["pi": .pi, "π": .pi, "e": M_E]

    static func tokenize(_ text: String) -> [Token]? {
        var tokens: [Token] = []
        let characters = Array(text.lowercased())
        var index = 0
        while index < characters.count {
            let c = characters[index]
            if c.isWhitespace { index += 1; continue }
            if c.isASCII && c.isNumber || c == "." || c == "," {
                var literal = ""
                var dots = 0
                while index < characters.count {
                    let d = characters[index]
                    if d.isASCII && d.isNumber { literal.append(d) }
                    else if d == "." || d == "," { dots += 1; literal.append(".") }
                    else { break }
                    index += 1
                }
                // "1.2.3" is not a number; nor is a lone ".".
                guard dots <= 1, literal != ".", let number = Double(literal) else { return nil }
                tokens.append(.number(number))
                continue
            }
            if c.isLetter || c == "π" {
                var word = ""
                while index < characters.count, characters[index].isLetter || characters[index] == "π" {
                    word.append(characters[index]); index += 1
                }
                if word == "x" { tokens.append(.op("*")) }
                else if functionNames.contains(word) { tokens.append(.function(word)) }
                else if let constant = constants[word] { tokens.append(.constant(constant)) }
                else { return nil }
                continue
            }
            switch c {
            case "+", "-", "*", "/", "^", "%": tokens.append(.op(c))
            case "−": tokens.append(.op("-"))
            case "×", "·": tokens.append(.op("*"))
            case "÷": tokens.append(.op("/"))
            case "(": tokens.append(.open)
            case ")": tokens.append(.close)
            default: return nil
            }
            index += 1
        }
        return tokens
    }

    // MARK: Parser

    struct Parser {
        let tokens: [Token]
        var position = 0
        var depth = 0

        init(tokens: [Token]) { self.tokens = tokens }

        var atEnd: Bool { position == tokens.count }
        private var peek: Token? { position < tokens.count ? tokens[position] : nil }
        private mutating func advance() { position += 1 }

        /// Whether a token can begin an operand, for implicit multiplication ("2pi", "(2)(3)").
        private func startsOperand(_ token: Token?) -> Bool {
            switch token {
            case .number, .constant, .function, .open: true
            default: false
            }
        }

        mutating func parseExpression() -> Double? {
            guard var value = parseTerm() else { return nil }
            while case .op(let op)? = peek, op == "+" || op == "-" {
                advance()
                guard let rhs = parseTerm() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func parseTerm() -> Double? {
            guard var value = parseUnary() else { return nil }
            while true {
                if case .op(let op)? = peek, op == "*" || op == "/" || op == "%" {
                    advance()
                    guard let rhs = parseUnary() else { return nil }
                    switch op {
                    case "*": value *= rhs
                    case "/":
                        guard rhs != 0 else { return nil }
                        value /= rhs
                    default:
                        guard rhs != 0 else { return nil }
                        value = value.truncatingRemainder(dividingBy: rhs)
                    }
                } else if startsOperand(peek) {
                    guard let rhs = parseUnary() else { return nil }
                    value *= rhs
                } else {
                    return value
                }
            }
        }

        mutating func parseUnary() -> Double? {
            if case .op(let op)? = peek, op == "-" || op == "+" {
                guard depth < Calculator.maxDepth else { return nil }
                depth += 1
                defer { depth -= 1 }
                advance()
                guard let operand = parseUnary() else { return nil }
                return op == "-" ? -operand : operand
            }
            return parsePower()
        }

        mutating func parsePower() -> Double? {
            guard let base = parsePostfix() else { return nil }
            guard case .op("^")? = peek else { return base }
            guard depth < Calculator.maxDepth else { return nil }
            depth += 1
            defer { depth -= 1 }
            advance()
            guard let exponent = parseUnary() else { return nil }
            return pow(base, exponent)
        }

        mutating func parsePostfix() -> Double? {
            guard var value = parsePrimary() else { return nil }
            // "50%" and "50% - 1" are per cent; "7 % 3" is the remainder, left for parseTerm.
            while case .op("%")? = peek {
                let next = position + 1 < tokens.count ? tokens[position + 1] : nil
                if startsOperand(next) { break }
                advance()
                value /= 100
            }
            return value
        }

        mutating func parsePrimary() -> Double? {
            guard let token = peek else { return nil }
            switch token {
            case .number(let value), .constant(let value):
                advance()
                return value
            case .function(let name):
                advance()
                guard case .open? = peek, let argument = parseGroup(),
                      let result = Calculator.apply(name, argument), result.isFinite else { return nil }
                return result
            case .open:
                return parseGroup()
            case .op, .close:
                return nil
            }
        }

        private mutating func parseGroup() -> Double? {
            guard case .open? = peek, depth < Calculator.maxDepth else { return nil }
            depth += 1
            defer { depth -= 1 }
            advance()
            guard let inner = parseExpression(), case .close? = peek else { return nil }
            advance()
            return inner
        }
    }
}
