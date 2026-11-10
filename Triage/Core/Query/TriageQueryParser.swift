import Foundation

/// Parses query text into a `TriageQuery.Node`.
///
///     query   := or
///     or      := and ("OR" and)*
///     and     := unary+
///     unary   := "-" unary | primary
///     primary := "(" or ")" | qualifier | text
struct TriageQueryParser {
    private enum Token: Equatable {
        case open, close, minus, or
        /// `colon` is the offset of the first unquoted colon in `value`.
        case word(value: String, colon: Int?)
    }

    private let tokens: [(token: Token, position: Int)]
    private var index = 0
    private let length: Int

    init(_ text: String) {
        tokens = Self.tokenize(text)
        length = text.count
    }

    mutating func parse() throws(TriageQueryError) -> TriageQuery.Node {
        guard !tokens.isEmpty else { throw TriageQueryError(message: "Enter a filter, e.g. is:review status:failing.", position: 0) }
        let node = try parseOr()
        if let (token, position) = peek {
            throw TriageQueryError(message: token == .close ? "Remove the extra “)”." : "Unexpected text.", position: position)
        }
        return node
    }

    // MARK: Grammar

    private var peek: (Token, Int)? { index < tokens.count ? tokens[index] : nil }

    private mutating func parseOr() throws(TriageQueryError) -> TriageQuery.Node {
        if let (token, position) = peek, token == .or {
            throw TriageQueryError(message: "Add a filter before OR.", position: position)
        }
        var parts = [try parseAnd()]
        while let (token, position) = peek, token == .or {
            index += 1
            guard let (next, _) = peek, next != .close, next != .or else {
                throw TriageQueryError(message: "Add a filter after OR.", position: position)
            }
            parts.append(try parseAnd())
        }
        return parts.count == 1 ? parts[0] : .any(parts)
    }

    private mutating func parseAnd() throws(TriageQueryError) -> TriageQuery.Node {
        var parts: [TriageQuery.Node] = []
        while let (token, _) = peek, token != .close, token != .or {
            parts.append(try parseUnary())
        }
        guard !parts.isEmpty else {
            throw TriageQueryError(message: "Add a filter here.", position: peek?.1 ?? length)
        }
        return parts.count == 1 ? parts[0] : .all(parts)
    }

    private mutating func parseUnary() throws(TriageQueryError) -> TriageQuery.Node {
        guard let (token, position) = peek else { throw TriageQueryError(message: "Add a filter here.", position: length) }
        switch token {
        case .minus:
            index += 1
            guard let (next, _) = peek, next != .close, next != .or else {
                throw TriageQueryError(message: "Add a filter after “-”.", position: position)
            }
            return .not(try parseUnary())
        case .open:
            index += 1
            if let (next, _) = peek, next == .close {
                throw TriageQueryError(message: "Add a filter inside the parentheses.", position: position)
            }
            let node = try parseOr()
            guard let (close, _) = peek, close == .close else {
                throw TriageQueryError(message: "Close the parenthesis opened here.", position: position)
            }
            index += 1
            return node
        case .word(let value, let colon):
            index += 1
            return try Self.term(value, colon: colon, position: position)
        case .close:
            throw TriageQueryError(message: "Remove the extra “)”.", position: position)
        case .or:
            throw TriageQueryError(message: "Add a filter before OR.", position: position)
        }
    }

    // MARK: Terms

    private static func term(_ word: String, colon: Int?, position: Int) throws(TriageQueryError) -> TriageQuery.Node {
        guard let colon, !word.dropFirst(colon + 1).hasPrefix("//") else { return .text(word) }
        let keyText = String(word.prefix(colon))
        let rawValue = String(word.dropFirst(colon + 1))
        guard let key = TriageQuery.Qualifier(rawValue: keyText.lowercased()) else {
            guard keyText.allSatisfy({ $0.isLetter || $0 == "-" }), !keyText.isEmpty else { return .text(word) }
            var message = "Unknown filter “\(keyText):”."
            if let suggestion = closestQualifier(to: keyText.lowercased()) { message += " Did you mean “\(suggestion):”?" }
            throw TriageQueryError(message: message, position: position)
        }
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            throw TriageQueryError(message: "Add a value after “\(key.rawValue):”, e.g. \(key.example).", position: position)
        }
        if let (aliasKey, aliasValue) = TriageQuery.aliases["\(key.rawValue):\(value.lowercased())"] {
            return .qualifier(aliasKey, aliasValue)
        }
        return .qualifier(key, try validated(value, for: key, position: position))
    }

    private static func validated(_ value: String, for key: TriageQuery.Qualifier, position: Int) throws(TriageQueryError) -> String {
        let lowered = value.lowercased()
        switch key.comparison {
        case .age?:
            guard TriageQueryComparison(age: lowered) != nil else {
                throw TriageQueryError(message: "Use a comparison and an age for “\(key.rawValue):”, e.g. \(key.example) or \(key.rawValue):<2w.", position: position)
            }
            return lowered
        case .number?:
            if TriageQueryComparison(number: lowered) != nil { return lowered }
            if key == .priority, PriorityBand(rawValue: lowered) != nil { return lowered }
            let hint = key == .priority ? "high, medium, low, or a number like priority:>70" : "a number like \(key.example)"
            throw TriageQueryError(message: "“\(key.rawValue):” needs \(hint).", position: position)
        case nil:
            break
        }
        if let known = key.knownValues {
            guard known.contains(where: { $0.value == lowered }) else {
                let options = known.map(\.value).joined(separator: ", ")
                throw TriageQueryError(message: "“\(key.rawValue):\(value)” isn't a filter. Use one of: \(options).", position: position)
            }
            return lowered
        }
        if key == .check, TriageQuery.splitCheck(value).name.isEmpty {
            throw TriageQueryError(message: "Add a check name, e.g. \(key.example).", position: position)
        }
        return value
    }

    private static func closestQualifier(to key: String) -> String? {
        TriageQuery.Qualifier.allCases
            .map { ($0.rawValue, editDistance(key, $0.rawValue)) }
            .filter { $0.1 <= 2 }
            .min { $0.1 < $1.1 }?.0
    }

    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs), b = Array(rhs)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    // MARK: Tokens

    private static func tokenize(_ text: String) -> [(token: Token, position: Int)] {
        let characters = Array(text)
        var result: [(Token, Int)] = []
        var i = 0
        while i < characters.count {
            let character = characters[i]
            if character.isWhitespace { i += 1; continue }
            if character == "(" { result.append((.open, i)); i += 1; continue }
            if character == ")" { result.append((.close, i)); i += 1; continue }
            if character == "-", i + 1 < characters.count, !characters[i + 1].isWhitespace, characters[i + 1] != ")" {
                result.append((.minus, i)); i += 1; continue
            }
            let start = i
            var value = ""
            var colon: Int?
            var quoted = false
            var wasQuoted = false
            while i < characters.count {
                let c = characters[i]
                if c == "\"" { quoted.toggle(); wasQuoted = true; i += 1; continue }
                if !quoted, c.isWhitespace || c == "(" || c == ")" { break }
                if !quoted, c == ":", colon == nil { colon = value.count }
                value.append(c)
                i += 1
            }
            if !wasQuoted, value == "OR" {
                result.append((.or, start))
            } else {
                result.append((.word(value: value, colon: colon), start))
            }
        }
        return result
    }
}

/// A parsed comparison such as `>14d`, `<=500`, or `70`.
struct TriageQueryComparison: Equatable, Sendable {
    enum Operator: String, Sendable { case greater = ">", greaterOrEqual = ">=", less = "<", lessOrEqual = "<=", equal = "=" }

    let op: Operator
    let amount: Int

    init?(number text: String) {
        guard let (op, digits) = Self.split(text), !digits.isEmpty, digits.allSatisfy(\.isNumber), let amount = Int(digits) else { return nil }
        self.op = op
        self.amount = amount
    }

    /// `>14d` or `<2w`; an operator is required. `amount` is in days.
    init?(age text: String) {
        guard text.hasPrefix(">") || text.hasPrefix("<"), let (op, rest) = Self.split(text),
              let unit = rest.last, unit == "d" || unit == "w",
              let count = Int(rest.dropLast()), count >= 0
        else { return nil }
        self.op = op
        amount = unit == "w" ? count * 7 : count
    }

    func holds(_ value: Int) -> Bool {
        switch op {
        case .greater: value > amount
        case .greaterOrEqual: value >= amount
        case .less: value < amount
        case .lessOrEqual: value <= amount
        case .equal: value == amount
        }
    }

    func holds(_ value: Double) -> Bool {
        switch op {
        case .greater: value > Double(amount)
        case .greaterOrEqual: value >= Double(amount)
        case .less: value < Double(amount)
        case .lessOrEqual: value <= Double(amount)
        case .equal: Int(value) == amount
        }
    }

    private static func split(_ text: String) -> (Operator, String)? {
        for op in [Operator.greaterOrEqual, .lessOrEqual, .greater, .less, .equal] where text.hasPrefix(op.rawValue) {
            return (op, String(text.dropFirst(op.rawValue.count)))
        }
        return (.equal, text)
    }
}
