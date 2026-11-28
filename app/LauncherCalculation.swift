import Foundation

struct CalculationResult: Equatable {
    let display: String
    let copyValue: String
    let detail: String?

    init(display: String, copyValue: String, detail: String? = nil) {
        self.display = display
        self.copyValue = copyValue
        self.detail = detail
    }

    static func evaluate(_ query: String, rates: CurrencyRateSnapshot? = nil, preferChinese: Bool = false) -> Self? {
        let expression = query.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty, expression.utf8.count <= 128 else { return nil }

        if let conversion = convert(expression) { return conversion }
        if let currency = convertCurrency(expression, rates: rates ?? .fallback, preferChinese: preferChinese) {
            return currency
        }
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

    // MARK: - Currency Conversion

    private static let ambiguousYenToken = "¥"

    private static let currencyAliases: [String: String] = {
        let definitions: [(String, [String])] = [
            ("USD", ["usd", "us$", "$", "dollar", "dollars", "us dollar", "us dollars", "美元", "美金", "美刀"]),
            ("CNY", ["cny", "rmb", "cnh", "cn¥", "rmb¥", "人民币", "人民币元", "元", "块", "圆"]),
            ("HKD", ["hkd", "hk$", "港币", "港元", "港纸"]),
            ("TWD", ["twd", "ntd", "nt$", "新台币", "台币"]),
            ("MOP", ["mop", "mop$", "澳门元", "澳门币", "葡币"]),
            ("JPY", ["jpy", "jp¥", "yen", "日元", "日币", "円"]),
            ("EUR", ["eur", "€", "euro", "euros", "欧元"]),
            ("GBP", ["gbp", "£", "pound", "pounds", "sterling", "英镑"]),
            ("KRW", ["krw", "₩", "won", "韩元", "韩币"]),
            ("SGD", ["sgd", "s$", "sg$", "新币", "新加坡元", "新加坡币"]),
            ("AUD", ["aud", "a$", "au$", "澳元", "澳币", "澳大利亚元"]),
            ("CAD", ["cad", "c$", "ca$", "加元", "加币", "加拿大元"]),
            ("CHF", ["chf", "瑞郎", "瑞士法郎"]),
            ("NZD", ["nzd", "nz$", "纽币", "纽元", "新西兰元"]),
            ("INR", ["inr", "₹", "rupee", "rupees", "卢比", "印度卢比"]),
            ("THB", ["thb", "฿", "baht", "泰铢", "泰币"]),
            ("MYR", ["myr", "rm", "ringgit", "马币", "林吉特", "马来西亚林吉特"]),
            ("VND", ["vnd", "₫", "dong", "越南盾"]),
            ("PHP", ["php", "₱", "菲律宾比索", "菲币"]),
            ("IDR", ["idr", "rp", "印尼盾", "印尼卢比"]),
            ("RUB", ["rub", "₽", "ruble", "rubles", "卢布", "俄罗斯卢布"]),
            ("BRL", ["brl", "r$", "雷亚尔", "巴西雷亚尔"]),
            ("MXN", ["mxn", "mex$", "墨西哥比索"]),
            ("SEK", ["sek", "瑞典克朗"]),
            ("NOK", ["nok", "挪威克朗"]),
            ("DKK", ["dkk", "丹麦克朗"]),
            ("PLN", ["pln", "zł", "兹罗提", "波兰兹罗提"]),
            ("TRY", ["try", "₺", "lira", "里拉", "土耳其里拉"]),
            ("ZAR", ["zar", "南非兰特", "兰特"]),
            ("AED", ["aed", "迪拉姆", "阿联酋迪拉姆"]),
            ("SAR", ["sar", "里亚尔", "沙特里亚尔"]),
            (ambiguousYenToken, ["¥", "￥"]),
        ]
        var table: [String: String] = [:]
        for (code, aliases) in definitions {
            for alias in aliases {
                table[alias.lowercased()] = code
            }
        }
        return table
    }()

    private static let sortedPrefixSymbols: [String] = [
        "mop$", "mex$", "rmb¥", "us$", "hk$", "nt$", "sg$", "au$", "ca$", "nz$", "cn¥", "jp¥",
        "s$", "a$", "c$", "r$", "$", "€", "£", "¥", "￥", "₩", "฿", "₹", "₫", "₱", "₽", "₺",
    ]

    private static let sortedCurrencyAliases: [String] = currencyAliases.keys.sorted { lhs, rhs in
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        return lhs < rhs
    }

    private static let currencyConnectors: [String] = [
        "等于多少", "是多少", "合多少", "兑换为", "兑换成", "换算成", "转换为",
        "等于", "兑换", "换成", "换算", "转成", "转换", "转为", "折合",
        "into", "to", "in", "as", "->", "=>", "→", "=",
        "换", "转", "兑", "到", "成",
    ]

    private static let numberPrefixRegex = try! NSRegularExpression(
        pattern: #"^(\+?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?|\+?\.\d+)"#
    )

    private static func isASCIIWordChar(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else { return false }
        return (scalar.value >= 65 && scalar.value <= 90)
            || (scalar.value >= 97 && scalar.value <= 122)
            || (scalar.value >= 48 && scalar.value <= 57)
    }

    private static func matchLeadingAlias(in text: String) -> (code: String, remaining: String, hadTrailingSpace: Bool)? {
        let lower = text.lowercased()
        for alias in sortedCurrencyAliases {
            guard lower.hasPrefix(alias) else { continue }
            let endIdx = text.index(text.startIndex, offsetBy: alias.count)
            if let lastChar = alias.last, isASCIIWordChar(lastChar),
               endIdx < text.endIndex, isASCIIWordChar(text[endIdx]) {
                continue
            }
            let hadTrailingSpace = endIdx < text.endIndex && text[endIdx].isWhitespace
            let rest = String(text[endIdx...]).trimmingCharacters(in: .whitespaces)
            if let code = currencyAliases[alias] {
                return (code, rest, hadTrailingSpace)
            }
        }
        return nil
    }

    private static func stripConnector(from text: String) -> (hadConnector: Bool, remaining: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        for connector in currencyConnectors {
            guard lower.hasPrefix(connector) else { continue }
            let endIdx = trimmed.index(trimmed.startIndex, offsetBy: connector.count)
            if let lastChar = connector.last, isASCIIWordChar(lastChar),
               endIdx < trimmed.endIndex, isASCIIWordChar(trimmed[endIdx]) {
                continue
            }
            var rest = String(trimmed[endIdx...]).trimmingCharacters(in: .whitespaces)
            for suffix in ["是多少", "多少", "?"] where rest.hasPrefix(suffix) {
                rest = String(rest.dropFirst(suffix.count)).trimmingCharacters(in: .whitespaces)
            }
            return (true, rest)
        }
        return (false, trimmed)
    }

    private static func resolveYen(fromRaw: String, toRaw: String, fullQuery: String) -> (from: String, to: String) {
        let lower = fullQuery.lowercased()
        let hasJapaneseClue = lower.contains("日元") || lower.contains("日币") || lower.contains("円")
            || lower.contains("jpy") || lower.contains("yen") || lower.contains("jp¥")
        var from = fromRaw
        var to = toRaw
        if from == ambiguousYenToken && to == ambiguousYenToken {
            from = "JPY"
            to = "CNY"
        } else if from == ambiguousYenToken {
            if to == "CNY" || hasJapaneseClue {
                from = "JPY"
            } else {
                from = "CNY"
            }
        } else if to == ambiguousYenToken {
            if from == "CNY" || hasJapaneseClue {
                to = "JPY"
            } else {
                to = "CNY"
            }
        }
        return (from, to)
    }

    private static func convertCurrency(_ expression: String, rates: CurrencyRateSnapshot, preferChinese: Bool) -> Self? {
        var working = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = working.last, last == "?" || last == "？" {
            working.removeLast()
        }
        working = working.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !working.isEmpty else { return nil }

        let lowerWorking = working.lowercased()
        var prefixCurrency: String?
        for symbol in sortedPrefixSymbols {
            if lowerWorking.hasPrefix(symbol) {
                let endIdx = working.index(working.startIndex, offsetBy: symbol.count)
                if let lastChar = symbol.last, isASCIIWordChar(lastChar),
                   endIdx < working.endIndex, isASCIIWordChar(working[endIdx]) {
                    continue
                }
                prefixCurrency = currencyAliases[symbol]
                working = String(working[endIdx...]).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        guard let numMatch = numberPrefixRegex.firstMatch(in: working, range: NSRange(working.startIndex..., in: working)),
              let numRange = Range(numMatch.range(at: 1), in: working),
              let amount = Double(working[numRange].replacingOccurrences(of: ",", with: "")),
              amount.isFinite, amount >= 0 else {
            return nil
        }

        let afterNumber = String(working[numRange.upperBound...])
        let trimmedAfterNumber = afterNumber.trimmingCharacters(in: .whitespaces)
        guard !trimmedAfterNumber.isEmpty else { return nil }

        var sourceCode: String
        var afterSource: String
        var separatedByWhitespace = false

        if let prefix = prefixCurrency {
            sourceCode = prefix
            afterSource = trimmedAfterNumber
            // Allow optional clarifying currency right after number, e.g. "¥1000 jpy to usd"
            if let clarified = matchLeadingAlias(in: afterSource), !clarified.remaining.isEmpty {
                let (hadConn, _) = stripConnector(from: clarified.remaining)
                if hadConn {
                    if sourceCode == ambiguousYenToken || clarified.code == sourceCode {
                        sourceCode = clarified.code
                        afterSource = clarified.remaining
                    }
                }
            }
        } else {
            guard let matchedSource = matchLeadingAlias(in: trimmedAfterNumber),
                  !matchedSource.remaining.isEmpty else {
                return nil
            }
            sourceCode = matchedSource.code
            separatedByWhitespace = matchedSource.hadTrailingSpace
            afterSource = matchedSource.remaining
        }

        let (hadConnector, targetText) = stripConnector(from: afterSource)
        guard hadConnector || prefixCurrency != nil || separatedByWhitespace else { return nil }
        guard !targetText.isEmpty,
              let targetCodeRaw = currencyAliases[targetText.lowercased()] else {
            return nil
        }

        let resolved = resolveYen(fromRaw: sourceCode, toRaw: targetCodeRaw, fullQuery: expression)
        guard let converted = rates.convert(amount, from: resolved.from, to: resolved.to),
              let unitRate = rates.convert(1.0, from: resolved.from, to: resolved.to) else {
            return nil
        }

        let formattedAmount = formatCurrencyValue(converted)
        let formattedUnitRate = formatUnitRate(unitRate)
        let sourceTag = rates.isFallback
            ? (preferChinese ? "内置汇率" : "Built-in")
            : rates.updatedDate
        let detail = "1 \(resolved.from) = \(formattedUnitRate) \(resolved.to) · \(sourceTag)"
        return Self(
            display: "\(formattedAmount.display) \(resolved.to)",
            copyValue: formattedAmount.copy,
            detail: detail
        )
    }

    private static func formatCurrencyValue(_ value: Double) -> (display: String, copy: String) {
        let posix = Locale(identifier: "en_US_POSIX")
        let absVal = abs(value)
        let plain: String
        if absVal == 0 || absVal >= 0.01 {
            plain = String(format: "%.2f", locale: posix, value == 0 ? 0 : value)
        } else {
            let lead = max(2, Int(ceil(-log10(absVal))))
            let decimals = min(8, lead + 3)
            var raw = String(format: "%.\(decimals)f", locale: posix, value)
            while raw.hasSuffix("0") && raw.split(separator: ".").last?.count ?? 0 > 2 {
                raw.removeLast()
            }
            plain = raw
        }
        return (groupThousands(plain), plain)
    }

    private static func formatUnitRate(_ rate: Double) -> String {
        let posix = Locale(identifier: "en_US_POSIX")
        let absRate = abs(rate)
        var raw: String
        if absRate >= 100 {
            raw = String(format: "%.2f", locale: posix, rate)
        } else if absRate >= 0.01 {
            raw = String(format: "%.4f", locale: posix, rate)
        } else if absRate > 0 {
            let lead = max(2, Int(ceil(-log10(absRate))))
            let decimals = min(8, lead + 3)
            raw = String(format: "%.\(decimals)f", locale: posix, rate)
        } else {
            return "0"
        }
        if raw.contains(".") {
            while raw.hasSuffix("0") { raw.removeLast() }
            if raw.hasSuffix(".") { raw.removeLast() }
        }
        return groupThousands(raw)
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
