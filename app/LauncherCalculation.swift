import Foundation

struct CalculationResult: Equatable {
    let display: String
    let copyValue: String

    static func evaluate(_ query: String) -> Self? {
        let expression = query.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty, expression.utf8.count <= 128 else { return nil }

        if let conversion = convert(expression) { return conversion }
        let explicit = expression.hasPrefix("=")
        if !explicit && expression.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil { return nil }
        var parser = Parser(input: Array(explicit ? expression.dropFirst() : expression[...]))
        guard let value = parser.sum(), parser.finished, explicit || parser.calculated,
              let answer = format(value) else { return nil }
        return Self(display: answer.display, copyValue: answer.copy)
    }

    private static func format(_ value: Double) -> (display: String, copy: String)? {
        guard value.isFinite else { return nil }
        let plain = String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value == 0 ? 0 : value)
        return (groupThousands(plain), plain)
    }

    private static func groupThousands(_ plain: String) -> String {
        guard !plain.contains("e"), !plain.contains("E") else { return plain }
        let negative = plain.hasPrefix("-")
        let unsigned = negative ? plain.dropFirst() : plain[...]
        let parts = unsigned.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integer = parts[0]
        guard integer.count > 3 else { return plain }
        var grouped = ""
        grouped.reserveCapacity(plain.count + (integer.count - 1) / 3)
        if negative { grouped.append("-") }
        for (index, ch) in integer.enumerated() {
            if index > 0 && (integer.count - index) % 3 == 0 { grouped.append(",") }
            grouped.append(ch)
        }
        if parts.count == 2 {
            grouped.append(".")
            grouped.append(contentsOf: parts[1])
        }
        return grouped
    }

    private struct Unit {
        let dimension: String
        let symbol: String
        let factor: Double
        let offset: Double

        init(_ dimension: String, _ symbol: String, _ factor: Double, _ offset: Double = 0) {
            self.dimension = dimension
            self.symbol = symbol
            self.factor = factor
            self.offset = offset
        }
    }

    private static let units: [String: Unit] = {
        let definitions: [(Unit, [String])] = [
            (Unit("length", "km", 1_000), ["公里", "千米"]),
            (Unit("length", "m", 1), ["米"]),
            (Unit("length", "cm", 0.01), ["厘米"]),
            (Unit("length", "mm", 0.001), ["毫米"]),
            (Unit("length", "mi", 1609.344), ["mile", "miles", "英里"]),
            (Unit("length", "ft", 0.3048), ["feet", "foot", "英尺"]),
            (Unit("length", "in", 0.0254), ["inch", "inches", "英寸"]),
            (Unit("mass", "kg", 1), ["公斤", "千克"]),
            (Unit("mass", "g", 0.001), ["克"]),
            (Unit("mass", "mg", 0.000001), ["毫克"]),
            (Unit("mass", "lb", 0.45359237), ["lbs", "pound", "pounds", "磅"]),
            (Unit("mass", "oz", 0.028349523125), ["ounce", "ounces", "盎司"]),
            (Unit("volume", "L", 1), ["升", "liter", "litre"]),
            (Unit("volume", "mL", 0.001), ["毫升"]),
            (Unit("volume", "US gal", 3.785411784), ["gal", "usgal", "美制加仑"]),
            (Unit("time", "s", 1), ["sec", "秒"]),
            (Unit("time", "min", 60), ["分钟"]),
            (Unit("time", "h", 3600), ["hr", "小时"]),
            (Unit("temperature", "°C", 1, 273.15), ["c", "摄氏度"]),
            (Unit("temperature", "°F", 5.0/9.0, 255.3722222222222), ["f", "华氏度"]),
            (Unit("temperature", "K", 1), ["开尔文"]),
        ]
        return Dictionary(uniqueKeysWithValues: definitions.flatMap { unit, aliases in
            (aliases + [unit.symbol.lowercased()]).map { ($0, unit) }
        })
    }()

    private static let conversionRegex = try! NSRegularExpression(
        pattern: #"^([+-]?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d*)?|[+-]?\.\d+)\s*([\p{L}°]+)\s*(?:\b(?:to|in)\b|到|转成|转换为)\s*([\p{L}°]+)$"#,
        options: [.caseInsensitive]
    )

    private static func convert(_ value: String) -> Self? {
        guard let match = conversionRegex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        let fields = (1...3).compactMap { Range(match.range(at: $0), in: value).map { String(value[$0]).lowercased() } }
        guard fields.count == 3,
              let amount = Double(fields[0].replacingOccurrences(of: ",", with: "")),
              let from = units[fields[1]], let to = units[fields[2]],
              from.dimension == to.dimension else { return nil }
        let converted = (amount * from.factor + from.offset - to.offset) / to.factor
        guard let result = format(from.dimension == "temperature" && abs(converted) < 1e-10 ? 0 : converted) else { return nil }
        return Self(display: "\(result.display) \(to.symbol)", copyValue: "\(result.copy) \(to.symbol)")
    }

    private struct Parser {
        let input: [Character]
        var offset = 0
        var calculated = false
        var finished: Bool { input[offset...].allSatisfy(\.isWhitespace) }

        mutating func peek() -> Character? {
            while offset < input.count && input[offset].isWhitespace { offset += 1 }
            return offset < input.count ? input[offset] : nil
        }

        mutating func sum() -> Double? {
            guard var left = product() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                offset += 1
                guard let right = product() else { return nil }
                calculated = true
                left = op == "+" ? left + right : left - right
            }
            return left
        }

        mutating func product() -> Double? {
            guard var left = unary() else { return nil }
            while let op = peek(), op == "*" || op == "/" {
                offset += 1
                guard let right = unary(), op != "/" || right != 0 else { return nil }
                calculated = true
                left = op == "*" ? left * right : left / right
            }
            return left
        }

        mutating func unary() -> Double? {
            if let sign = peek(), sign == "+" || sign == "-" {
                offset += 1
                guard let value = unary() else { return nil }
                return sign == "-" ? -value : value
            }
            return power()
        }

        mutating func power() -> Double? {
            guard let base = primary() else { return nil }
            if peek() == "^" {
                offset += 1
                guard let exponent = unary() else { return nil }
                calculated = true
                let result = pow(base, exponent)
                guard result.isFinite else { return nil }
                return result
            }
            return base
        }

        mutating func primary() -> Double? {
            var number: Double
            if peek() == "(" {
                offset += 1
                guard let result = sum(), peek() == ")" else { return nil }
                offset += 1
                number = result
            } else {
                guard let result = parseNumber() else { return nil }
                number = result
            }
            if peek() == "%" {
                offset += 1
                calculated = true
                number /= 100
            }
            return number
        }

        mutating func parseNumber() -> Double? {
            let start = offset
            var digits = ""
            var groupLength = 0
            while offset < input.count, ("0"..."9").contains(input[offset]) {
                digits.append(input[offset])
                groupLength += 1
                offset += 1
            }
            let hasIntegerDigits = groupLength > 0

            if offset < input.count && input[offset] == "," {
                guard hasIntegerDigits, (1...3).contains(groupLength) else { return nil }
                while offset < input.count && input[offset] == "," {
                    offset += 1
                    var count = 0
                    while offset < input.count, ("0"..."9").contains(input[offset]) {
                        digits.append(input[offset])
                        count += 1
                        offset += 1
                    }
                    guard count == 3 else { return nil }
                }
            }

            if offset < input.count && input[offset] == "." {
                digits.append(".")
                offset += 1
                var fracCount = 0
                while offset < input.count, ("0"..."9").contains(input[offset]) {
                    digits.append(input[offset])
                    fracCount += 1
                    offset += 1
                }
                if offset < input.count && (input[offset] == "," || input[offset] == ".") { return nil }
                if !hasIntegerDigits && fracCount == 0 { return nil }
            }

            guard start < offset, let result = Double(digits), result.isFinite else { return nil }
            return result
        }
    }
}
