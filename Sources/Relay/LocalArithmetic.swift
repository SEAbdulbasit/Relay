import Foundation

/// Bounded local arithmetic grammar. Never evaluates code, identifiers, or commands.
nonisolated enum LocalArithmetic {
    struct Result: Equatable, Sendable {
        let value: String
        let rounded: Bool
    }

    static func evaluate(_ expression: String) throws -> Result {
        guard !expression.isEmpty, expression.utf8.count <= 512 else { throw failure("Use an arithmetic expression up to 512 bytes.") }
        var parser = Parser(characters: Array(expression))
        var result = try parser.expression(depth: 0)
        parser.skipSpaces()
        guard parser.index == parser.characters.count else { throw failure("Unsupported arithmetic syntax. Use numbers, +, -, ×, ÷ and parentheses only.") }
        return Result(value: NSDecimalString(&result, Locale(identifier: "en_US_POSIX")), rounded: parser.rounded)
    }

    // NSDecimalDivide can report noError for a recurring decimal. Removing
    // factors 2 and 5 from the denominator distinguishes finite decimal ratios.
    private static func hasTerminatingQuotient(_ left: Decimal, _ right: Decimal) -> Bool {
        var denominator = abs(right.significand)
        let numerator = abs(left.significand)
        func wholeQuotient(_ dividend: Decimal, _ divisor: Decimal) -> Decimal {
            var ratio = dividend / divisor, integer = Decimal()
            NSDecimalRound(&integer, &ratio, 0, .down)
            return integer
        }
        for prime in [Decimal(2), Decimal(5)] {
            for _ in 0..<256 {
                let quotient = wholeQuotient(denominator, prime)
                guard quotient * prime == denominator else { break }
                denominator = quotient
            }
        }
        return wholeQuotient(numerator, denominator) * denominator == numerator
    }

    private static func failure(_ message: String) -> RelayError { .message(message) }

    private struct Parser {
        let characters: [Character]
        var index = 0
        var operations = 0
        var rounded = false
        mutating func skipSpaces() {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
        }
        mutating func take(_ options: [Character]) -> Character? {
            skipSpaces()
            guard index < characters.count, options.contains(characters[index]) else { return nil }
            defer { index += 1 }
            return characters[index]
        }
        mutating func expression(depth: Int) throws -> Decimal {
            var value = try term(depth: depth)
            while let op = take(["+", "-", "−"]) { value = try apply(value, term(depth: depth), op: op) }
            return value
        }
        mutating func term(depth: Int) throws -> Decimal {
            var value = try primary(depth: depth)
            while let op = take(["*", "x", "X", "×", "/", "÷"]) { value = try apply(value, primary(depth: depth), op: op) }
            return value
        }
        mutating func primary(depth: Int) throws -> Decimal {
            guard depth < 24 else { throw LocalArithmetic.failure("Arithmetic nesting exceeds 24 levels.") }
            if let sign = take(["+", "-", "−"]) {
                let value = try primary(depth: depth + 1)
                return sign == "+" ? value : -value
            }
            if take(["("]) != nil {
                let value = try expression(depth: depth + 1)
                guard take([")"]) != nil else { throw LocalArithmetic.failure("Close every arithmetic parenthesis.") }
                return value
            }
            skipSpaces()
            let start = index
            var digits = 0, dots = 0
            while index < characters.count {
                let character = characters[index]
                if character >= "0", character <= "9" { digits += 1 }
                else if character == "." { dots += 1 }
                else { break }
                index += 1
            }
            guard digits > 0, digits <= 38, dots <= 1,
                  let value = Decimal(string: String(characters[start..<index]), locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else {
                throw LocalArithmetic.failure("Use decimal numbers with at most 38 digits; no identifiers or exponent notation.")
            }
            return value
        }
        mutating func apply(_ left: Decimal, _ right: Decimal, op: Character) throws -> Decimal {
            operations += 1
            guard operations <= 128 else { throw LocalArithmetic.failure("Arithmetic exceeds 128 operations.") }
            var left = left, right = right, result = Decimal()
            let status: Decimal.CalculationError
            switch op {
            case "+": status = NSDecimalAdd(&result, &left, &right, .plain)
            case "-", "−": status = NSDecimalSubtract(&result, &left, &right, .plain)
            case "*", "x", "X", "×": status = NSDecimalMultiply(&result, &left, &right, .plain)
            default:
                guard right != 0 else { throw LocalArithmetic.failure("Division by zero is undefined.") }
                if !LocalArithmetic.hasTerminatingQuotient(left, right) { rounded = true }
                status = NSDecimalDivide(&result, &left, &right, .plain)
            }
            switch status {
            case .noError: break
            case .lossOfPrecision: rounded = true
            default: throw LocalArithmetic.failure("Arithmetic exceeds the supported decimal range; no result was returned.")
            }
            guard !result.isNaN else { throw LocalArithmetic.failure("Arithmetic result is undefined.") }
            return result
        }
    }
}
