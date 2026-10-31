import AppKit
import CoreText
import Foundation
import PDFKit
import Vision

struct InvoiceRow: Identifiable, Codable {
    var id = UUID()
    var sourcePath: String? = nil
    var sl: Int
    var consumerNo: String
    var station: String
    var bpcAmount: Double?
    var gst: Double?
    var total: Double?
    var outstanding: Double?
    var otherOutstanding: Double?
    var cycle: String
    var docNo: String? = nil
}

struct InvoicePageData: Codable {
    var consumerNo: String
    var consumerName: String
    var billNo: String
    var bpcAmount: Double?
    var gst: Double?
    var total: Double?
    var billDate: String
    var stationHint: String
    var outstanding: Double?
    var otherOutstanding: Double?
    var cycle: String
}

struct InvoiceDocument: Codable {
    var path: String
    var month = ""
    var reference = ""
    var date = ""
    var cycle = ""
    var totalWords = ""
    var totalAmount: Double?
    var rows: [InvoiceRow] = []
    var invoices: [InvoicePageData] = []
}

struct ReceiptRecord: Identifiable, Codable {
    var id = UUID()
    var sourcePath: String? = nil
    var docNo: String
    var consumerNo: String?
    var bpNo: String?
    var amount: Double?
    var amountWords: String
    var date: String
    var station: String
    var cycle: String
}

struct OutstandingRecord: Identifiable {
    var id = UUID()
    var month: String
    var consumerNo: String
    var station: String
    var outstanding: Double
    var otherOutstanding: Double
}

private struct OCRTextLine {
    var text: String
    var bounds: CGRect
}

private struct ExtractedPDFPage {
    var text: String
    var ocrLines: [OCRTextLine]
    var pdfTextTokens: [OCRTextLine] = []
    var pageSize: CGSize = .zero
}

private struct PositionedSettlementRow {
    var invoice: InvoiceRow
    var docNo: String
}

enum BPCError: LocalizedError {
    case invalidPDF(String)
    case noExtractableText(String)
    case invalidInvoice(String)
    case export(String)
    case invalidStation(String)

    var errorDescription: String? {
        switch self {
        case .invalidPDF(let reason): return "Cannot open PDF: \(reason)"
        case .noExtractableText(let reason): return "No usable text was found. \(reason)"
        case .invalidInvoice(let name): return "No bills found in \(name). This may not be a BPC e-bill PDF."
        case .export(let reason): return "Could not create output: \(reason)"
        case .invalidStation(let reason): return reason
        }
    }
}

enum BPCServices {
    static let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BPCEbillReconciler", isDirectory: true)
    static let defaultOutput = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Desktop/BPC Output", isDirectory: true)

    static let canonicalStations: [String: String] = [
        "10125147": "Wamling BTS", "10125166": "Langdurbi BTS",
        "10125306": "Tingtibi Exchange Office", "10105930": "Zhemgang Town BTS",
        "10026759": "Dangkharpokto D-site", "10125099": "Yebilaptsa BTS",
        "10029795": "Goling BTS", "10063029": "Goling Sector Additional",
        "10125891": "Khomshar BTS", "10125278": "Phawa Top BTS",
        "10125322": "Phawa BTS", "10106913": "Bermo BTS",
        "10125307": "Malingpong BTS", "10029794": "Buli BTS",
        "10186151": "Jiwangolai D-Site", "10026758": "Tingtibi Trong D-Site",
        "10125164": "Tali BTS", "10186150": "Zhemgang RLDC D-site",
        "10125213": "Thajong BTS", "10105931": "Zhemgang Exchange Office",
        "10106995": "Kalamti BTS", "10209150": "Burgangchu BTS",
        "10125390": "Remiya BTS", "10105927": "Gompong BTS",
        "10125287": "Malaya Top"
    ]

    static func ensureAppSupport() throws {
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
    }

    static func savedStations() -> [String: String] {
        let url = appSupport.appendingPathComponent("stations.json")
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return value
    }

    static func hiddenStations() -> Set<String> {
        let url = appSupport.appendingPathComponent("hidden_stations.json")
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(value)
    }

    static func allStations() -> [String: String] {
        var result = canonicalStations
        result.merge(savedStations()) { _, new in new }
        for no in hiddenStations() { result.removeValue(forKey: no) }
        return result
    }

    static func saveStations(_ mapping: [String: String]) throws {
        try ensureAppSupport()
        let data = try JSONEncoder().encode(mapping)
        try data.write(to: appSupport.appendingPathComponent("stations.json"), options: .atomic)
    }

    static func addStation(number: String, name: String) throws -> String {
        let digits = number.filter(\.isNumber)
        let station = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !digits.isEmpty else { throw BPCError.invalidStation("Consumer No. must contain digits.") }
        guard !station.isEmpty else { throw BPCError.invalidStation("Station name cannot be empty.") }
        var saved = savedStations()
        saved[digits] = station
        try saveStations(saved)
        var hidden = hiddenStations()
        hidden.remove(digits)
        try ensureAppSupport()
        try JSONEncoder().encode(hidden.sorted()).write(to: appSupport.appendingPathComponent("hidden_stations.json"), options: .atomic)
        return digits
    }

    static func removeStation(number: String) throws {
        var saved = savedStations()
        saved.removeValue(forKey: number)
        try saveStations(saved)
        if canonicalStations[number] != nil {
            var hidden = hiddenStations()
            hidden.insert(number)
            try ensureAppSupport()
            try JSONEncoder().encode(hidden.sorted()).write(to: appSupport.appendingPathComponent("hidden_stations.json"), options: .atomic)
        }
    }

    static func outputFolder() -> URL {
        let settings = appSupport.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: settings),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let path = object["output_folder"], FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return defaultOutput
    }

    static func setOutputFolder(_ url: URL) throws {
        try ensureAppSupport()
        let data = try JSONSerialization.data(withJSONObject: ["output_folder": url.path], options: [.prettyPrinted])
        try data.write(to: appSupport.appendingPathComponent("config.json"), options: .atomic)
    }

    static func extractPages(from url: URL) throws -> [String] {
        try extractPageContents(from: url).map(\.text)
    }

    private static func extractPageContents(from url: URL) throws -> [ExtractedPDFPage] {
        guard let pdf = PDFDocument(url: url), pdf.pageCount > 0 else {
            throw BPCError.invalidPDF("The file could not be opened as a PDF.")
        }
        var pages: [ExtractedPDFPage] = []
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else {
                pages.append(ExtractedPDFPage(text: "", ocrLines: []))
                continue
            }
            let embeddedText = page.string ?? ""
            let pdfTextTokens = positionedPDFTextTokens(embeddedText, on: page)
            var text = embeddedText
            var ocrLines: [OCRTextLine] = []
            let shouldCheckReceiptOCR = receiptTextQualityScore(embeddedText) > 0
            if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 60 || shouldCheckReceiptOCR {
                if let image = page.thumbnail(of: CGSize(width: 1800, height: 2400), for: .mediaBox)
                    .cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = true
                    request.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    ocrLines = (request.results ?? []).compactMap { observation in
                        guard let recognized = observation.topCandidates(1).first?.string else { return nil }
                        return OCRTextLine(text: recognized, bounds: observation.boundingBox)
                    }
                    let recognizedText = ocrLines.map(\.text).joined(separator: "\n")
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 60 ||
                        receiptTextQualityScore(recognizedText) >= receiptTextQualityScore(embeddedText) &&
                        receiptTextQualityScore(embeddedText) > 0 {
                        text = recognizedText
                    } else {
                        ocrLines = []
                    }
                }
            }
            pages.append(ExtractedPDFPage(text: text, ocrLines: ocrLines,
                                          pdfTextTokens: pdfTextTokens,
                                          pageSize: page.bounds(for: .mediaBox).size))
        }
        guard pages.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw BPCError.noExtractableText("This PDF may be an image-only scan; the built-in OCR could not read it.")
        }
        return pages
    }

    private static func receiptTextQualityScore(_ text: String) -> Int {
        let receiptMarkers = matches(#"(?i)\b(?:CA\s*No|MONEY\s+RECEIPT|An\s*amount\s*of\s*Nu)\b"#, in: text).count
        guard receiptMarkers > 0 else { return 0 }
        let headings = matches(#"(?i)\bMONEY\s+RECEIPT\b"#, in: text).count
        let consumers = matches(#"(?i)\bCA\s*No\.?\s*[:.'’\s]*\d{8}\b"#, in: text).count
        let amounts = matches(#"(?i)An\s*amount\s*of\s*Nu\s*[:.'’\s]*[\d,]+\.\d{2}"#, in: text).count
        let documents = matches(#"(?i)\bDoc\s*No\b[^0-9]{0,24}106\d{6}\b"#, in: text).count
        let dates = matches(#"\b\d{2}\.\d{2}\.\d{4}\b"#, in: text).count
        return headings + consumers + amounts + documents + dates
    }

    private static func ocrInvoiceBalances(_ lines: [OCRTextLine]) -> (outstanding: Double?, otherOutstanding: Double?) {
        let summaryLabels: [(String, String)] = [
            ("net charge", #"Net\s*Charge"#),
            ("gst", #"GST\s*5%"#),
            ("outstanding", #"^Outstanding$"#),
            ("penalty", #"^Penalty$"#),
            ("gross amount", #"^Gross\s+Amount$"#),
            ("other outstanding", #"^Other\s+Outstanding$"#),
            ("excess payment", #"^Excess\s+Payment$"#),
            ("net amount", #"Net\s*Amount"#)
        ]
        let labelLines = lines.compactMap { line -> (String, OCRTextLine)? in
            guard line.bounds.minX < 0.24,
                  (0.35...0.62).contains(line.bounds.midY) else { return nil }
            let normalized = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let label = summaryLabels.first(where: { !matches($0.1, in: normalized).isEmpty })?.0 else {
                return nil
            }
            return (label, line)
        }.sorted { $0.1.bounds.midY > $1.1.bounds.midY }

        guard labelLines.count == summaryLabels.count,
              let first = labelLines.first, let last = labelLines.last else { return (nil, nil) }
        let amountLines = lines.filter {
            (0.52...0.70).contains($0.bounds.midX) &&
            $0.bounds.midY >= last.1.bounds.midY - 0.035 &&
            $0.bounds.midY <= first.1.bounds.midY + 0.035 &&
            ocrSummaryAmount($0.text) != nil
        }.sorted { $0.bounds.midY > $1.bounds.midY }
        guard amountLines.count >= labelLines.count else { return (nil, nil) }

        var matchesByPosition = Array(
            repeating: Array<(cost: CGFloat, indices: [Int])?>(repeating: nil, count: amountLines.count + 1),
            count: labelLines.count + 1
        )
        matchesByPosition[0][0] = (0, [])
        for labelIndex in 0...labelLines.count {
            for amountIndex in 0..<amountLines.count {
                guard let state = matchesByPosition[labelIndex][amountIndex] else { continue }
                if matchesByPosition[labelIndex][amountIndex + 1] == nil ||
                    state.cost < matchesByPosition[labelIndex][amountIndex + 1]!.cost {
                    matchesByPosition[labelIndex][amountIndex + 1] = state
                }
                guard labelIndex < labelLines.count else { continue }
                let distance = abs(labelLines[labelIndex].1.bounds.midY - amountLines[amountIndex].bounds.midY)
                guard distance <= 0.035 else { continue }
                let matched = (state.cost + distance, state.indices + [amountIndex])
                if matchesByPosition[labelIndex + 1][amountIndex + 1] == nil ||
                    matched.0 < matchesByPosition[labelIndex + 1][amountIndex + 1]!.cost {
                    matchesByPosition[labelIndex + 1][amountIndex + 1] = matched
                }
            }
        }
        guard let selectedAmounts = matchesByPosition[labelLines.count][amountLines.count]?.indices,
              selectedAmounts.count == labelLines.count else { return (nil, nil) }

        var paired: [String: Double] = [:]
        for index in labelLines.indices {
            guard let amount = ocrSummaryAmount(amountLines[selectedAmounts[index]].text) else { continue }
            paired[labelLines[index].0] = amount
        }
        return (paired["outstanding"], paired["other outstanding"])
    }

    private static func ocrSummaryAmount(_ text: String) -> Double? {
        guard var amount = capture(text, #"(?<![\d.])(-?\d[\d,]*[.,]\d{1,2}-?)(?!\d)"#) else { return nil }
        let negative = amount.hasPrefix("-") || amount.hasSuffix("-")
        amount.removeAll { $0 == "-" }
        if amount.contains(",") && !amount.contains(".") {
            amount = amount.replacingOccurrences(of: ",", with: ".")
        } else {
            amount.removeAll { $0 == "," }
        }
        guard let value = Double(amount) else { return nil }
        return (negative ? -value : value).rounded2
    }

    static func parseInvoice(_ url: URL) throws -> InvoiceDocument {
        let extractedPages = try extractPageContents(from: url)
        let pages = extractedPages.map(\.text)
        var document = InvoiceDocument(path: url.path)
        var cover: [String: String] = [:]
        for page in pages.prefix(3) where page.localizedCaseInsensitiveContains("Electricity bill") {
            if let value = capture(page, #"(?i)\bRef\.?\s*(?:No\.?)?\s*[:.]?\s*(\S+)"#) {
                cover["reference"] = value.trimmingCharacters(in: CharacterSet(charactersIn: " /,"))
            }
            if let value = capture(page, #"(?i)Date\s*[:.]\s*(\d{1,2}/\d{1,2}/\d{2,4})"#) { cover["date"] = value }
            if let value = capture(page, #"(?i)for the month of\s+([A-Za-z]+\s+\d{4})"#) {
                cover["month"] = value.capitalized
            } else if let month = capture(page, #"(?i)for month of\s+([A-Za-z]+)[,\-\s]*(\d{4})"#, group: 1),
                      let year = capture(page, #"(?i)for month of\s+[A-Za-z]+[,\-\s]*(\d{4})"#) {
                cover["month"] = "\(month.capitalized) \(year)"
            }
            if let match = captures(page, #"(?is)amount(?:ing)?\s*to\s*Nu\s*[.\s:]*([\d,.\s]+?)\s*\(\s*([A-Za-z][^)]*?)\s*\)"#) {
                if let amount = money(match[0]) { document.totalAmount = amount }
                document.totalWords = match[1].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            }
            break
        }
        if let value = cover["reference"] { document.reference = value }
        if let value = cover["date"] { document.date = value }
        if let value = cover["month"] { document.month = value }

        var statementIndex: Int?
        var statementRows: [InvoiceRow] = []
        var statementTotals: [Double]?
        for (idx, page) in pages.enumerated() where page.contains("Electricity Bill Statement for") && page.contains("Sl. No.") {
            statementIndex = idx
            statementRows = parseStatement(page)
            statementTotals = parseStatementTotals(page)
            if document.month.isEmpty,
               let month = capture(page, #"(?i)Statement for\s+([A-Za-z]+\s+\d{4})"#) {
                document.month = month.capitalized
            }
            if document.totalAmount == nil {
                document.totalAmount = statementTotals?.last
                    ?? statementRows.reduce(0) { $0 + ($1.total ?? 0) }
            }
            break
        }
        if statementIndex == nil {
            var inSettlement = false
            var settlementRows: [InvoiceRow] = []
            var lastSettlementPage: Int?
            for (idx, page) in extractedPages.enumerated() {
                if page.text.range(of: #"Electricity\s+Bill\s+payment\s+settlement"#,
                                   options: [.regularExpression, .caseInsensitive]) != nil {
                    inSettlement = true
                    if document.month.isEmpty,
                       let month = capture(page.text, #"(?i)settlement\s+for\s+.*?\bfor\s+([A-Za-z]+\s+\d{4})"#) {
                        document.month = month.capitalized
                    }
                    if document.cycle.isEmpty,
                       let cycle = capture(page.text, #"(?i)\bCycle\s*[:.]?\s*(\d{1,2})\b"#) {
                        document.cycle = cycle
                    }
                }
                if inSettlement,
                   page.text.range(of: #"(?m)^\s*MONEY\s+RECEIPT\s*$"#,
                                   options: [.regularExpression, .caseInsensitive]) != nil {
                    break
                }
                guard inSettlement else { continue }
                let rows = parseSettlementStatement(page)
                if !rows.isEmpty {
                    settlementRows.append(contentsOf: rows)
                    lastSettlementPage = idx
                }
            }
            if !settlementRows.isEmpty {
                statementRows = settlementRows
                statementIndex = lastSettlementPage
                document.totalAmount = settlementRows.reduce(0) { $0 + ($1.total ?? 0) }
            }
        }
        if statementIndex == nil {
            for (idx, page) in extractedPages.enumerated() {
                let rows = parseScannedStatement(page)
                guard !rows.isEmpty else { continue }
                statementIndex = idx
                statementRows = rows
                document.totalAmount = rows.reduce(0) { $0 + ($1.total ?? 0) }
                break
            }
        }

        let start = statementIndex.map { $0 + 1 } ?? 0
        document.invoices = pages.indices.dropFirst(start).compactMap { index in
            parseInvoicePage(pages[index], ocrLines: extractedPages[index].ocrLines)
        }
        if !statementRows.isEmpty, statementRows.contains(where: { ($0.total ?? 0) != 0 }) {
            document.rows = statementRows
            backfillInvoiceAmounts(&document.rows, invoices: document.invoices)
            backfillOutstanding(&document.rows, invoices: document.invoices)
            backfillCycle(&document.rows, invoices: document.invoices)
            let rowTotal = document.rows.reduce(0) { $0 + ($1.total ?? 0) }
            if document.totalAmount == nil || abs((document.totalAmount ?? 0) - rowTotal) > 0.01 {
                document.totalAmount = rowTotal
            }
        } else if !document.invoices.isEmpty {
            var mapping = referenceStations(for: url)
            mapping.merge(savedStations()) { _, new in new }
            var firstIndex: [String: Int] = [:]
            for (idx, invoice) in document.invoices.enumerated() where firstIndex[invoice.consumerNo] == nil {
                firstIndex[invoice.consumerNo] = idx
            }
            var dominant = mostCommon(document.invoices.map(\.cycle).filter { (1...12).contains(Int($0) ?? 0) })
            for (number, idx) in firstIndex.sorted(by: { $0.value < $1.value }) {
                let invoice = document.invoices[idx]
                let station = mapping[number] ?? (invoice.stationHint.isEmpty ? invoice.consumerName : invoice.stationHint)
                document.rows.append(InvoiceRow(sl: document.rows.count + 1, consumerNo: number,
                    station: station, bpcAmount: invoice.bpcAmount, gst: invoice.gst,
                    total: invoice.total, outstanding: invoice.outstanding,
                    otherOutstanding: invoice.otherOutstanding,
                    cycle: dominant.isEmpty ? invoice.cycle : dominant))
            }
            if dominant.isEmpty { dominant = document.invoices.first(where: { !$0.cycle.isEmpty })?.cycle ?? "" }
        }
        if document.month.isEmpty { document.month = billingMonth(document.invoices.map(\.billDate)) }
        if document.totalAmount == nil {
            document.totalAmount = document.rows.reduce(0) { $0 + ($1.total ?? 0) }
        }
        if document.reference.isEmpty { document.reference = "BTL/CR/ZHE/2026" }
        if document.date.isEmpty {
            let now = Calendar.current.dateComponents([.day, .month, .year], from: Date())
            document.date = "\(now.day ?? 1)/\(now.month ?? 1)/\(now.year ?? 2026)"
        }
        if document.cycle.isEmpty {
            document.cycle = mostCommon(document.invoices.map(\.cycle).filter { (1...12).contains(Int($0) ?? 0) })
            if document.cycle.isEmpty { document.cycle = cycleFromMonth(document.month) }
        }
        guard !document.rows.isEmpty else { throw BPCError.invalidInvoice(url.lastPathComponent) }
        for idx in document.rows.indices { document.rows[idx].sourcePath = url.path }
        return document
    }

    static func parseInvoiceIfAvailable(_ url: URL) throws -> InvoiceDocument? {
        do {
            return try parseInvoice(url)
        } catch BPCError.invalidInvoice(_) {
            return nil
        }
    }

    private static func positionedPDFTextTokens(_ text: String, on page: PDFPage) -> [OCRTextLine] {
        matches(#"\S+"#, in: text).compactMap { match in
            guard let token = group(match, 0, in: text),
                  let selection = page.selection(for: match.range) else { return nil }
            let bounds = selection.bounds(for: page)
            guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return nil }
            return OCRTextLine(text: token, bounds: bounds)
        }
    }

    private static func parseSettlementStatement(_ page: ExtractedPDFPage) -> [InvoiceRow] {
        parsePositionedSettlementRows(page).map(\.invoice)
    }

    private static func parsePositionedSettlementRows(_ page: ExtractedPDFPage) -> [PositionedSettlementRow] {
        let tokens = page.pdfTextTokens
        guard page.pageSize.width > 0, !tokens.isEmpty else { return [] }
        let consumers = tokens.filter {
            (0.055...0.30).contains($0.bounds.midX / page.pageSize.width) &&
            !matches(#"^\d{8}$"#, in: $0.text).isEmpty
        }
        let moneyTokens = tokens.filter {
            !matches(#"^(?:(?:\d{1,3}(?:,\d{3})+)|\d+)\.\d{2}$"#, in: $0.text).isEmpty
        }
        let receiptNumbers = tokens.filter {
            !matches(#"^106\d{6}$"#, in: $0.text).isEmpty
        }
        guard consumers.count >= 3 else { return [] }
        let rowTolerance = max(3, page.pageSize.height * 0.009)

        let rows = consumers.compactMap { consumer -> (OCRTextLine, PositionedSettlementRow)? in
            let number = consumer.text
            let rowMoney = moneyTokens
                .filter { abs($0.bounds.midY - consumer.bounds.midY) <= rowTolerance }
                .sorted { $0.bounds.midX < $1.bounds.midX }
            let rowDocs = receiptNumbers.filter {
                abs($0.bounds.midY - consumer.bounds.midY) <= rowTolerance
            }
            guard rowMoney.count == 3, !rowDocs.isEmpty,
                  let bpc = money(rowMoney[0].text),
                  let gst = money(rowMoney[1].text),
                  let total = money(rowMoney[2].text),
                  abs((bpc + gst).rounded2 - total) <= 0.02 else { return nil }

            let stationTokens = tokens.filter {
                abs($0.bounds.midY - consumer.bounds.midY) <= rowTolerance &&
                $0.bounds.midX > consumer.bounds.maxX + 1 &&
                $0.bounds.midX < rowMoney[0].bounds.minX - 1 &&
                matches(#"^\d+$"#, in: $0.text).isEmpty
            }.sorted { $0.bounds.minX < $1.bounds.minX }
            let station = stationTokens.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " ,:;"))
            return (consumer, PositionedSettlementRow(
                invoice: InvoiceRow(sl: 0, consumerNo: number, station: cleanStation(station),
                                    bpcAmount: bpc, gst: gst, total: total,
                                    outstanding: nil, otherOutstanding: nil, cycle: "",
                                    docNo: rowDocs[0].text),
                docNo: rowDocs[0].text))
        }
        return rows
            .sorted { $0.0.bounds.midY > $1.0.bounds.midY }
            .enumerated()
            .map { index, element in
                var row = element.1
                row.invoice.sl = index + 1
                return row
            }
    }

    private static func parseStatement(_ page: String) -> [InvoiceRow] {
        let consumerMatches = matches(#"(?<!\d)(\d{8})(?!\d)"#, in: page)
        let amountPattern = #"((?<!\d)(?:(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})(?![\d,]))"#
        return consumerMatches.enumerated().map { index, match in
            let number = group(match, 1, in: page) ?? ""
            let start = NSMaxRange(match.range)
            let end = index + 1 < consumerMatches.count
                ? consumerMatches[index + 1].range.location
                : (page as NSString).length
            let block = (page as NSString).substring(with: NSRange(location: start, length: max(0, end - start)))
            let amounts = allMatches(amountPattern, in: block).compactMap(money)
            let stationText = replacing(block, pattern: amountPattern, with: " ")
            let station = stationText.components(separatedBy: .newlines)
                .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
                .first { !$0.isEmpty && capture($0, #"^\d{1,2}$"#) == nil } ?? ""
            return InvoiceRow(sl: index + 1, consumerNo: number, station: station,
                bpcAmount: amounts.indices.contains(0) ? amounts[0] : nil,
                gst: amounts.indices.contains(1) ? amounts[1] : nil,
                total: amounts.indices.contains(2) ? amounts[2] : nil,
                outstanding: nil, otherOutstanding: nil, cycle: "")
        }
    }

    private static func parseScannedStatement(_ page: ExtractedPDFPage) -> [InvoiceRow] {
        let lines = page.ocrLines
        let consumers = lines.filter {
            (0.49...0.59).contains($0.bounds.midY) &&
            $0.bounds.midX > 0.39 && $0.bounds.midX < 0.90 &&
            capture($0.text, #"(?<!\d)(\d{8})(?!\d)"#) != nil
        }.sorted { $0.bounds.midX > $1.bounds.midX }
        guard consumers.count >= 3 else { return [] }

        func column(_ verticalRange: ClosedRange<CGFloat>) -> [OCRTextLine] {
            lines.filter {
                verticalRange.contains($0.bounds.midY) &&
                $0.bounds.midX > 0.39 && $0.bounds.midX < 0.90
            }.sorted { $0.bounds.midX > $1.bounds.midX }
        }
        let stations = column(0.65...0.82)
        let charges = column(0.43...0.50)
        let taxes = column(0.35...0.43)
        let totals = column(0.28...0.35)
        guard stations.count >= consumers.count - 2,
              charges.count == consumers.count,
              taxes.count == consumers.count,
              totals.count == consumers.count else { return [] }

        return consumers.indices.compactMap { index in
            guard let consumer = capture(consumers[index].text, #"(?<!\d)(\d{8})(?!\d)"#) else { return nil }
            let station = stations.min { abs($0.bounds.midX - consumers[index].bounds.midX) < abs($1.bounds.midX - consumers[index].bounds.midX) }
                .flatMap { abs($0.bounds.midX - consumers[index].bounds.midX) <= 0.02 ? $0.text : nil } ?? ""
            return InvoiceRow(sl: index + 1, consumerNo: consumer,
                station: station.trimmingCharacters(in: .whitespacesAndNewlines),
                bpcAmount: ocrLineMoney(charges[index]), gst: ocrLineMoney(taxes[index]),
                total: ocrLineMoney(totals[index]),
                outstanding: nil, otherOutstanding: nil, cycle: "")
        }
    }

    private static func ocrLineMoney(_ line: OCRTextLine) -> Double? {
        guard let amount = capture(line.text, #"(?<![\d.])(\d[\d,]*\.\d{2})(?!\d)"#) else { return nil }
        return money(amount)
    }

    private static func backfillInvoiceAmounts(_ rows: inout [InvoiceRow], invoices: [InvoicePageData]) {
        let index = Dictionary(invoices.map { ($0.consumerNo, $0) }, uniquingKeysWith: { first, _ in first })
        for rowIndex in rows.indices {
            guard let invoice = index[rows[rowIndex].consumerNo] else { continue }
            if rows[rowIndex].station.isEmpty &&
               !invoice.stationHint.localizedCaseInsensitiveContains("registered office") {
                rows[rowIndex].station = invoice.stationHint.isEmpty ? invoice.consumerName : invoice.stationHint
            }
            rows[rowIndex].gst = rows[rowIndex].gst ?? invoice.gst
            rows[rowIndex].total = invoice.total ?? rows[rowIndex].total
            rows[rowIndex].bpcAmount = rows[rowIndex].bpcAmount
                ?? (rows[rowIndex].total.flatMap { total in rows[rowIndex].gst.map { (total - $0).rounded2 } })
                ?? invoice.bpcAmount
        }
    }

    private static func parseStatementTotals(_ page: String) -> [Double]? {
        var lastTotals: [Double]?
        for line in page.components(separatedBy: .newlines) {
            guard capture(line, #"(?<!\d)(\d{8})(?!\d)"#) == nil else { continue }
            let amounts = allMatches(#"(?<!\d)(?:(?:\d{1,3}(?:,\d{3})+|\d+)\.\d{2})(?![\d,])"#, in: line)
                .compactMap(money)
            if amounts.count >= 3 { lastTotals = amounts }
        }
        return lastTotals
    }

    private static func referenceStations(for invoiceURL: URL) -> [String: String] {
        let manager = FileManager.default
        let directories = [
            invoiceURL.deletingLastPathComponent(),
            URL(fileURLWithPath: manager.currentDirectoryPath, isDirectory: true),
            Bundle.main.bundleURL
        ]
        var candidates: [URL] = []
        for directory in directories {
            guard let files = try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { continue }
            candidates.append(contentsOf: files.filter { file in
                guard file.pathExtension.lowercased() == "pdf" else { return false }
                let name = file.deletingPathExtension().lastPathComponent.lowercased()
                return name == "sample" || name.hasPrefix("sample")
            }.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending })
        }
        let legacy = appSupport.appendingPathComponent("memorized_sample.pdf")
        if manager.fileExists(atPath: legacy.path) { candidates.append(legacy) }
        for sample in candidates where sample.standardizedFileURL != invoiceURL.standardizedFileURL {
            guard let pages = try? extractPages(from: sample) else { continue }
            for page in pages where page.contains("Electricity Bill Statement for") && page.contains("Sl. No.") {
                let rows = parseStatement(page)
                if !rows.isEmpty { return Dictionary(rows.map { ($0.consumerNo, $0.station) }, uniquingKeysWith: { _, new in new }) }
            }
        }
        return canonicalStations
    }

    private static func parseInvoicePage(_ text: String, ocrLines: [OCRTextLine] = []) -> InvoicePageData? {
        guard text.localizedCaseInsensitiveContains("Net Amount") ||
              text.localizedCaseInsensitiveContains("Consumer No") else { return nil }
        let rawNo = capture(text, #"(?i)(?:C|Z)?onsumer\s+N[ao]\.?\s*[:,;]*\s*(\d+)"#)
            ?? capture(text, #"(?i)(?:C|Z)?onsumer\s+Ame\.?\s*[:,;]*\s*(\d+)"#)
            ?? capture(text, #"(?<!\d)(\d{8})(?!\d)"#)
        guard let rawNo else { return nil }
        let digits = rawNo.filter(\.isNumber)
        let consumer = String(digits.suffix(8))
        guard !consumer.isEmpty else { return nil }
        let nameRaw = capture(text, #"(?i)Consumer Name\.?\s*:?\s*(.+)"#) ?? ""
        let name = capture(nameRaw, #"(?i)^(.*?)(?:Status|Meter No\.?|Bill No\.?|Bill Date|Type|Due Date|Reader|Reading Date|Rating|Business Partner)\b"#) ?? nameRaw
        let net = ocrMoney(label: #"Net\s*Amount"#, lines: ocrLines)
            ?? allMatches(#"(?i)Net\s*Amount\s*[:.]?\s*([\d,]+\.\d{2})"#, in: text).first.flatMap(money)
            ?? ocrAmountWords(lines: ocrLines)
        var charge = ocrMoney(label: #"Net\s*Charge"#, lines: ocrLines)
            ?? allMatches(#"(?i)Net\s*Charge\s*[:.]?\s*([\d,]+\.\d{2})"#, in: text).first.flatMap(money)
        let gst = ocrMoney(label: #"GST\s*5%"#, lines: ocrLines, nearAmount: net.map { $0 / 21 })
            ?? allMatches(#"(?i)GST\s*5%\s*([\d,]+\.\d{2})"#, in: text).first.flatMap(money)
        guard net != nil || charge != nil || gst != nil else { return nil }
        if charge == nil, let net, let gst { charge = (net - gst).rounded2 }
        if let net, let gst, let currentCharge = charge, abs(currentCharge - (net - gst)) > 2 {
            charge = (net - gst).rounded2
        }

        let cycleMatch = capture(text, #"(?i)Cycle\s*[:.]?\s*["']?\s*(\d+)"#)
        let billDate = capture(text, #"(?i)Bill Date[^\d\n]{0,12}(\d{2}\.\d{2}\.\d{4})"#) ?? ""
        let other: Double?
        let outstanding: Double?
        if ocrLines.isEmpty {
            other = allMatches(#"(?i)(?:Other\s+Outstanding|Others?\s+(?:Out\s*stand\w*|Balance|Due|Arrears?)|Misc\.?\s+(?:Out\s*stand\w*|Balance|Due|Arrears?)|Extra\s+(?:Out\s*stand\w*|Balance|Due|Arrears?))\s*[:.\-]*\s*(-?[\d,]+\.\d{2})"#, in: text).first.flatMap(money)
            outstanding = parseOutstanding(text, net: net)
        } else {
            let balances = ocrInvoiceBalances(ocrLines)
            other = balances.otherOutstanding
            outstanding = balances.outstanding
        }
        return InvoicePageData(
            consumerNo: consumer,
            consumerName: name.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            billNo: capture(text, #"(?i)Bill No\.?\s*:?\s*(\S+)"#) ?? "",
            bpcAmount: charge, gst: gst, total: net, billDate: billDate,
            stationHint: stationHint(text, name: name), outstanding: outstanding,
            otherOutstanding: other, cycle: cycleMatch ?? "")
    }

    private static func ocrMoney(label: String, lines: [OCRTextLine], nearAmount: Double? = nil) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: label, options: .caseInsensitive),
              let labelLine = lines.first(where: {
                  regex.firstMatch(in: $0.text, range: NSRange(location: 0, length: ($0.text as NSString).length)) != nil
              }) else { return nil }
        let candidates = lines.filter {
            $0.bounds.minX >= labelLine.bounds.maxX - 0.015 &&
            abs($0.bounds.midY - labelLine.bounds.midY) <= 0.012
        }.sorted {
            abs($0.bounds.midY - labelLine.bounds.midY) < abs($1.bounds.midY - labelLine.bounds.midY)
        }
        let values = candidates.compactMap { candidate -> Double? in
            guard let amount = capture(candidate.text, #"(?<![\d.])(-?\d[\d,]*\.\d{2})(?!\d)"#) else { return nil }
            return money(amount)
        }
        if let nearAmount {
            return values.min { abs($0 - nearAmount) < abs($1 - nearAmount) }
        }
        return values.first
    }

    private static func ocrAmountWords(lines: [OCRTextLine]) -> Double? {
        guard let label = lines.first(where: {
            $0.text.range(of: #"Net\s*Amount"#, options: .regularExpression.union(.caseInsensitive)) != nil
        }) else { return nil }
        for line in lines where
            line.bounds.midY < label.bounds.midY &&
            label.bounds.midY - line.bounds.midY <= 0.04 &&
            line.text.localizedCaseInsensitiveContains("Nu") {
            guard let words = capture(line.text, #"(?i)Nu\.?\s*[:.]?\s*([A-Za-z][A-Za-z -]*)"#),
                  let value = wordsNumber(words) else { continue }
            return value
        }
        return nil
    }

    private static func parseOutstanding(_ text: String, net: Double?) -> Double? {
        let cleaned = replacing(text, pattern: #"(?i)(?:Other\s+Outstanding|Others?\s+(?:Out\s*stand\w*|Balance|Due|Arrears?)|Misc\.?\s+(?:Out\s*stand\w*|Balance|Due|Arrears?)|Extra\s+(?:Out\s*stand\w*|Balance|Due|Arrears?))\s*[:.\-]*\s*-?[\d,]+\.\d{2}"#, with: " ")
        let patterns = [
            #"(?i)Out\s*stand\w*\s*(?:Amount|Amt|Balance|Bal|Due)?\s*[:.\-]*\s*(-?[\d,]+\.\d{2})"#,
            #"(?i)Total\s+Out\s*stand\w*\s*[:.\-]*\s*(-?[\d,]+\.\d{2})"#,
            #"(?i)Arrear\w*\s*(?:Amount|Amt|Balance|Bal)?\s*[:.\-]*\s*(-?[\d,]+\.\d{2})"#,
            #"(?i)(?:Previous|Prev\.?|Other)\s+(?:Balance|Bal|Due|Outstanding|Out\s*standing|Arrears?|Amount)\s*[:.\-]*\s*(-?[\d,]+\.\d{2})"#,
            #"(?i)Balance\s+(?:B/?F|Brought\s+Forward|C/?F|Carried\s+Forward)\s*[:.\-]*\s*(-?[\d,]+\.\d{2})"#
        ]
        let values = patterns.flatMap { allMatches($0, in: cleaned).compactMap(money) }
        if let best = values.max(by: { abs($0) < abs($1) }) { return best < 0.005 ? 0 : best }
        if let payable = capture(cleaned, #"(?i)Total\s+(?:Amount\s+)?Payable\s*[:.\-]*\s*(-?[\d,]+\.\d{2})"#
        ).flatMap(money), let net, payable - net >= 0.005 {
            return (payable - net).rounded2
        }
        return nil
    }

    private static func stationHint(_ text: String, name: String) -> String {
        let lines = text.components(separatedBy: .newlines).map {
            $0.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }.filter { !$0.isEmpty }
        var address: [String] = []
        var inAddress = false
        for line in lines {
            if line.range(of: "Consumer Name", options: .caseInsensitive) != nil {
                inAddress = true
                if let value = capture(line, #"(?i)Consumer Name\.?\s*:?\s*(.+)"#), !value.isEmpty { address.append(value) }
                continue
            }
            if inAddress && line.range(of: #"Meter No|Tariff Block|Current Reading|GST TPN|Consumption\(kwh\)"#, options: .regularExpression.union(.caseInsensitive)) != nil { break }
            if inAddress && line.range(of: #"Bill Date|Bill No|Reading Date|Due Date|Prev\.|Sub-category|Portion|Cycle|Rating|D\.M\.F|C\.T\.R|P\.T\.R|Business Partner|^Company\s*$"#, options: .regularExpression.union(.caseInsensitive)) == nil {
                address.append(line)
            }
        }
        for line in address {
            if line.range(of: #"bts|d-site|dsite|d site|exchange|office|sector|rldc|pokto"#, options: .regularExpression.union(.caseInsensitive)) != nil {
                var cleaned = line
                if !line.localizedCaseInsensitiveContains("Flat No") {
                    cleaned = line.components(separatedBy: CharacterSet(charactersIn: ",:")).first ?? line
                }
                return cleanStation(cleaned)
            }
        }
        let cleanName = capture(name, #"(?i)^(.*?)(?:Status|Meter No\.?|Bill No\.?|Bill Date|Type|Due Date|Reader|Reading Date|Rating|Business Partner)\b"#) ?? name
        return cleanStation(cleanName)
    }

    private static func cleanStation(_ raw: String) -> String {
        var value = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        value = replacing(value, pattern: #"(?i)\bBTs\b"#, with: "BTS")
        value = replacing(value, pattern: #"(?i)\bBT\b(?=\s*$)"#, with: "BTS")
        value = replacing(value, pattern: #"(?i)\bexcha\b"#, with: "Exchange Office")
        value = replacing(value, pattern: #"(?i)\bRemeya\b"#, with: "Remiya")
        value = replacing(value, pattern: #"(?i)\bLangdubi\b"#, with: "Langdurbi")
        value = replacing(value, pattern: #"(?i)\bAdditonal\b"#, with: "Additional")
        value = replacing(value, pattern: #"(?i)\bJiawan\s*Goli\b"#, with: "Jiwangolai")
        value = replacing(value, pattern: #"(?i)\bBTS\s+Gompong\b"#, with: "Gompong BTS")
        return value.trimmingCharacters(in: CharacterSet(charactersIn: " ,:;"))
    }

    private static func backfillOutstanding(_ rows: inout [InvoiceRow], invoices: [InvoicePageData]) {
        var index: [String: InvoicePageData] = [:]
        for invoice in invoices {
            if let current = index[invoice.consumerNo] {
                if (invoice.outstanding ?? 0) > (current.outstanding ?? 0) ||
                    (invoice.otherOutstanding ?? 0) > (current.otherOutstanding ?? 0) {
                    index[invoice.consumerNo] = invoice
                }
            } else { index[invoice.consumerNo] = invoice }
        }
        let rowConsumers = Set(rows.map(\.consumerNo))
        var unmatchedInvoices: [Int: [InvoicePageData]] = [:]
        var unmatchedRows: [Int: [Int]] = [:]
        for invoice in invoices where !rowConsumers.contains(invoice.consumerNo) {
            guard let total = invoice.total else { continue }
            unmatchedInvoices[Int((total * 100).rounded()), default: []].append(invoice)
        }
        for i in rows.indices where index[rows[i].consumerNo] == nil {
            guard let total = rows[i].total else { continue }
            unmatchedRows[Int((total * 100).rounded()), default: []].append(i)
        }
        for i in rows.indices {
            let invoice: InvoicePageData?
            if let exact = index[rows[i].consumerNo] {
                invoice = exact
            } else if let total = rows[i].total {
                let cents = Int((total * 100).rounded())
                if unmatchedRows[cents]?.count == 1, unmatchedInvoices[cents]?.count == 1 {
                    invoice = unmatchedInvoices[cents]?.first
                } else {
                    invoice = nil
                }
            } else {
                invoice = nil
            }
            guard let invoice else { continue }
            if invoice.outstanding != nil { rows[i].outstanding = invoice.outstanding }
            if invoice.otherOutstanding != nil { rows[i].otherOutstanding = invoice.otherOutstanding }
        }
    }

    private static func backfillCycle(_ rows: inout [InvoiceRow], invoices: [InvoicePageData]) {
        let plausible = invoices.map(\.cycle).filter { (1...12).contains(Int($0) ?? 0) }
        let dominant = mostCommon(plausible)
        for i in rows.indices where !dominant.isEmpty { rows[i].cycle = dominant }
    }

    static func parseReceipts(_ url: URL) throws -> [ReceiptRecord] {
        let extractedPages = try extractPageContents(from: url)
        let pages = extractedPages.map(\.text)
        let text = pages.joined(separator: "\n")
        let cycle = cycleFromReceipt(text)
        let saved = savedStations()
        var details = parseIndividualReceiptPages(pages, cycle: cycle, stations: saved)
        let positionedSummary = extractedPages.flatMap { page in
            parsePositionedSettlementRows(page).map { row in
                ReceiptRecord(docNo: row.docNo, consumerNo: row.invoice.consumerNo, bpNo: nil,
                    amount: row.invoice.total, amountWords: "", date: "",
                    station: saved[row.invoice.consumerNo] ?? canonicalStations[row.invoice.consumerNo] ?? row.invoice.station,
                    cycle: cycle)
            }
        }
        if !positionedSummary.isEmpty && positionedSummary.count > details.count {
            return positionedSummary.map { summary in
                let detail = details.first {
                    $0.consumerNo == summary.consumerNo || (!summary.docNo.isEmpty && $0.docNo == summary.docNo)
                }
                return ReceiptRecord(docNo: summary.docNo, consumerNo: summary.consumerNo,
                    bpNo: detail?.bpNo, amount: detail?.amount ?? summary.amount,
                    amountWords: detail?.amountWords ?? "", date: detail?.date ?? "",
                    station: summary.station, cycle: cycle)
            }
        }
        if details.isEmpty {
            let detailAnchors = matches(#"(?i)An amount of Nu\s*[:.]"#, in: text)
            for (idx, anchor) in detailAnchors.enumerated() {
                let start = idx > 0 ? detailAnchors[idx - 1].range.location + detailAnchors[idx - 1].range.length : 0
                let end = idx + 1 < detailAnchors.count ? detailAnchors[idx + 1].range.location : (text as NSString).length
                let segment = (text as NSString).substring(with: NSRange(location: start, length: max(0, end - start)))
                let nearOffset = anchor.range.location - start
                let document = nearestMatch(#"\b(\d{9})\b"#, in: segment, target: nearOffset, limit: 1000).flatMap { group($0, 1, in: segment) } ?? ""
                let consumerRaw = nearestMatch(#"(?i)CA\s*No[^\dA-Za-z]*(\d[\d\s'’]*)"#, in: segment, target: nearOffset, limit: 400).flatMap { group($0, 1, in: segment) }
                let bp = nearestMatch(#"(?i)BP\s*No[^\dA-Za-z]*(\d[\d\s'’]*)"#, in: segment, target: nearOffset, limit: 400).flatMap { group($0, 1, in: segment) }.map(digitsOnly)
                let date = nearestMatch(#"\b(\d{2}\.\d{2}\.\d{4})\b"#, in: segment, target: nearOffset, limit: 400).flatMap { group($0, 1, in: segment) } ?? ""
                let amountRange = NSRange(location: anchor.range.location, length: min(220, (text as NSString).length - anchor.range.location))
                let amountMatch = matches(#"(?i)An amount of Nu\s*[:.,\s]*([\d,][\d,.\s]*\.\d{2})"#, in: text, range: amountRange).first
                let digitAmount = amountMatch.flatMap { group($0, 1, in: text) }.flatMap(receiptMoney)
                let wordsRange = NSRange(location: anchor.range.location, length: min(280, (text as NSString).length - anchor.range.location))
                let wordMatch = matches(#"(?is)/\s*([A-Za-z][^/]*?)\s*(?:Nu\.?|only)"#, in: text, range: wordsRange).first
                let words = wordMatch.flatMap { group($0, 1, in: text) } ?? ""
                let wordAmount = wordsNumber(words)
                details.append(ReceiptRecord(docNo: digitsOnly(document), consumerNo: consumerRaw.map(digitsOnly).map { String($0.suffix(8)) },
                    bpNo: bp, amount: digitAmount ?? wordAmount, amountWords: words, date: date,
                    station: "", cycle: cycle))
            }
        }

        let summaryRange: Range<String.Index>
        if let marker = text.range(of: #"(?m)^\s*MONEY\s+RECEIPT\s*$"#,
                                   options: [.regularExpression, .caseInsensitive]) {
            summaryRange = text.startIndex..<marker.lowerBound
        } else {
            summaryRange = text.startIndex..<text.endIndex
        }
        let summaryText = String(text[summaryRange])
        let consumers = matches(#"(?<![\d.])(\d{8})(?![\d.])"#, in: summaryText)
        var summary: [ReceiptRecord] = []
        let amountPattern = #"(\b\d{1,3}(?:,\d{3})*\.\d{2}\b)"#
        for (index, consumerMatch) in consumers.enumerated() {
            guard let number = group(consumerMatch, 1, in: summaryText) else { continue }
            let start = NSMaxRange(consumerMatch.range)
            let end = index + 1 < consumers.count
                ? consumers[index + 1].range.location
                : (summaryText as NSString).length
            let block = (summaryText as NSString).substring(with: NSRange(location: start, length: max(0, end - start)))
            let amounts = allMatches(amountPattern, in: block).compactMap(money)
            let total = amounts.count >= 3 ? amounts[2] : amounts.first
            let blockDocs = allMatches(#"\b(106\d{6})\b"#, in: block)
            let detail = details.first { $0.consumerNo == number } ?? details.first { item in
                !item.docNo.isEmpty && blockDocs.contains(item.docNo)
            }
            let docNo = detail.flatMap { $0.docNo.isEmpty ? nil : $0.docNo } ?? blockDocs.first ?? ""
            summary.append(ReceiptRecord(docNo: docNo, consumerNo: number,
                bpNo: detail?.bpNo, amount: detail?.amount ?? total,
                amountWords: detail?.amountWords ?? "", date: detail?.date ?? "",
                station: saved[number] ?? canonicalStations[number] ?? "", cycle: cycle))
        }
        guard !summary.isEmpty else {
            return details.map { item in
                var record = item
                record.station = item.consumerNo.flatMap { saved[$0] ?? canonicalStations[$0] } ?? ""
                return record
            }
        }
        if details.count >= positionedSummary.count,
           details.allSatisfy({ $0.consumerNo != nil && $0.amount != nil }) {
            return details
        }
        return summary
    }

    private static func parseIndividualReceiptPages(_ pages: [String], cycle: String,
                                                    stations: [String: String]) -> [ReceiptRecord] {
        var records: [ReceiptRecord] = []
        for page in pages {
            let headings = matches(#"(?im)^\s*MONEY\s+RECEIPT\s*$"#, in: page)
            for (index, heading) in headings.enumerated() {
                let start = heading.range.location
                let end = index + 1 < headings.count
                    ? headings[index + 1].range.location
                    : (page as NSString).length
                let block = (page as NSString).substring(
                    with: NSRange(location: start, length: max(0, end - start)))
                let docNo = capture(block, #"(?i)\bDoc\s*No\.?\s*[:.'’\s]*(106\d{6})\b"#) ?? ""
                let consumerRaw = capture(block, #"(?i)\bCA\s*No\.?\s*[:.'’\s]*([\d'’\s]{8,})"#)
                let bpRaw = capture(block, #"(?i)\bBP\s*No\.?\s*[:.'’\s]*([\d'’\s]{6,})"#)
                let amountText = capture(block, #"(?i)An\s*amount\s*of\s*Nu\s*[:.'’\s]*([\d,]+\.\d{2})"#)
                let amount = amountText.flatMap(money)
                let words = capture(block, #"(?is)/\s*([A-Za-z][A-Za-z -]*?)\s*(?:Nu\.?|only)"#) ?? ""
                let date = capture(block, #"\b(\d{2}\.\d{2}\.\d{4})\b"#) ?? ""
                let consumerNo = consumerRaw.map(digitsOnly).map { String($0.suffix(8)) }
                guard consumerNo != nil || amount != nil || !docNo.isEmpty else { continue }
                records.append(ReceiptRecord(docNo: digitsOnly(docNo), consumerNo: consumerNo,
                    bpNo: bpRaw.map(digitsOnly), amount: amount ?? wordsNumber(words),
                    amountWords: words, date: date,
                    station: consumerNo.flatMap { stations[$0] ?? canonicalStations[$0] } ?? "",
                    cycle: cycle))
            }
        }
        return records
    }

    static func outstanding(in documents: [InvoiceDocument]) -> [OutstandingRecord] {
        var items: [OutstandingRecord] = []
        for doc in documents {
            for row in doc.rows {
                let current = row.outstanding ?? 0
                let other = row.otherOutstanding ?? 0
                if current >= 0.005 || other >= 0.005 {
                    let station = row.station.isEmpty
                        ? (doc.invoices.first(where: { $0.consumerNo == row.consumerNo })?.consumerName ?? row.consumerNo)
                        : row.station
                    items.append(OutstandingRecord(month: doc.month, consumerNo: row.consumerNo,
                        station: station, outstanding: current >= 0.005 ? current : 0,
                        otherOutstanding: other >= 0.005 ? other : 0))
                }
            }
            if doc.rows.isEmpty {
                for invoice in doc.invoices where (invoice.outstanding ?? 0) >= 0.005 || (invoice.otherOutstanding ?? 0) >= 0.005 {
                    items.append(OutstandingRecord(month: doc.month, consumerNo: invoice.consumerNo,
                        station: invoice.stationHint.isEmpty ? invoice.consumerName : invoice.stationHint,
                        outstanding: (invoice.outstanding ?? 0) >= 0.005 ? invoice.outstanding! : 0,
                        otherOutstanding: (invoice.otherOutstanding ?? 0) >= 0.005 ? invoice.otherOutstanding! : 0))
                }
            }
        }
        return items
    }

    static func outstandingText(_ items: [OutstandingRecord]) -> String {
        var lines = ["Outstanding amount found in \(items.count) station(s):"]
        for item in items {
            var detail: [String] = []
            if item.outstanding >= 0.005 { detail.append("Outstanding Nu.\(item.outstanding.moneyString)") }
            if item.otherOutstanding >= 0.005 { detail.append("Other Outstanding Nu.\(item.otherOutstanding.moneyString)") }
            lines.append("- \(item.station) (CA \(item.consumerNo)): \(detail.joined(separator: " | "))\(item.month.isEmpty ? "" : " [\(item.month)]")")
        }
        lines.append("Total Outstanding: Nu.\(items.reduce(0) { $0 + $1.outstanding }.moneyString)")
        lines.append("Total Other Outstanding: Nu.\(items.reduce(0) { $0 + $1.otherOutstanding }.moneyString)")
        return lines.joined(separator: "\n")
    }

    static func tally(documents: [InvoiceDocument], receipts: [ReceiptRecord]) -> (confirmed: Bool, text: String, stats: [String: Double]) {
        let ledger = documents.flatMap { doc in doc.rows.map { (doc.month, $0.consumerNo, $0.station, $0.total) } }
        var matched: [ReceiptRecord] = []
        var mismatch: [(ReceiptRecord, (String, String, String, Double?))] = []
        var unmatched: [ReceiptRecord] = []
        var unknown: [ReceiptRecord] = []
        for receipt in receipts {
            guard let number = receipt.consumerNo, let amount = receipt.amount else { unknown.append(receipt); continue }
            let candidates = ledger.filter { $0.1 == number }
            if candidates.contains(where: { abs(($0.3 ?? .infinity) - amount) <= 0.01 }) {
                matched.append(receipt)
            } else if let invoice = candidates.first {
                mismatch.append((receipt, invoice))
            } else {
                unmatched.append(receipt)
            }
        }
        let paid = Set(matched.compactMap(\.consumerNo))
        let unpaid = ledger.filter { !paid.contains($0.1) }
        let invTotal = ledger.reduce(0) { $0 + ($1.3 ?? 0) }
        let recTotal = receipts.reduce(0) { $0 + ($1.amount ?? 0) }
        let matchedTotal = matched.reduce(0) { $0 + ($1.amount ?? 0) }
        let mismatchTotal = mismatch.reduce(0) { $0 + ($1.0.amount ?? 0) }
        let extraTotal = unmatched.reduce(0) { $0 + ($1.amount ?? 0) }
        let unknownTotal = unknown.reduce(0) { $0 + ($1.amount ?? 0) }
        let out = outstanding(in: documents)
        let confirmed = !matched.isEmpty && mismatch.isEmpty && unknown.isEmpty && unpaid.isEmpty
        var lines = [String(repeating: "=", count: 66), "            INVOICE vs RECEIPT TALLY REPORT", String(repeating: "=", count: 66), "", "INVOICES PROVIDED"]
        for doc in documents {
            let total = doc.rows.reduce(0) { $0 + ($1.total ?? 0) }
            lines.append("  \(URL(fileURLWithPath: doc.path).lastPathComponent)  [\(doc.month)]")
            lines.append(String(format: "      consumers: %3d   invoice total: Nu.%@", doc.rows.count, total.moneyString))
        }
        lines += ["  Overall invoice total: Nu.\(invTotal.moneyString)", "", "RECEIPTS PROVIDED",
                  "  receipts parsed: \(receipts.count)   receipt total: Nu.\(recTotal.moneyString)", "",
                  "MATCHING RESULT",
                  String(format: "  matched exactly (consumer + amount): %3d  Nu.%@", matched.count, matchedTotal.moneyString)]
        if !mismatch.isEmpty {
            lines.append(String(format: "  consumer found but amount differs   : %3d  Nu.%@", mismatch.count, mismatchTotal.moneyString))
            for (receipt, invoice) in mismatch {
                lines.append("      - receipt \(receipt.docNo) CA \(receipt.consumerNo ?? "?") paid Nu.\((receipt.amount ?? 0).moneyString) vs invoice Nu.\((invoice.3 ?? 0).moneyString) (\(invoice.0), \(invoice.2))")
            }
        }
        if !unmatched.isEmpty {
            lines.append(String(format: "  extra receipts (no invoice in set)  : %3d  Nu.%@", unmatched.count, extraTotal.moneyString))
            for receipt in unmatched { lines.append("      - receipt \(receipt.docNo) CA \(receipt.consumerNo ?? "?") Nu.\((receipt.amount ?? 0).moneyString)") }
        }
        if !unknown.isEmpty {
            lines.append(String(format: "  receipts with missing amount/CA no  : %3d  Nu.%@", unknown.count, unknownTotal.moneyString))
        }
        lines += ["", "OUTSTANDING AMOUNTS (as printed on the invoice pages)"]
        for item in out.prefix(50) { lines.append("      - CA \(item.consumerNo)  \(item.station) Nu.\(item.outstanding.moneyString)  (\(item.month))") }
        lines.append("  Outstanding stations: \(out.count)   outstanding total: Nu.\(out.reduce(0) { $0 + $1.outstanding }.moneyString)")
        lines.append("")
        if !unpaid.isEmpty {
            lines.append("INVOICE ROWS WITHOUT RECEIPTS (unpaid per receipts)")
            for item in unpaid.prefix(50) { lines.append("      - CA \(item.1)  \(item.2) Nu.\((item.3 ?? 0).moneyString)  (\(item.0))") }
        }
        lines += ["", "SUMMARY", "  Total invoiced      : Nu.\(invTotal.moneyString)",
                  "  Total receipted     : Nu.\(recTotal.moneyString)",
                  "  Receipts matched    : Nu.\(matchedTotal.moneyString)", "",
                  confirmed ? ">>> TALLY CONFIRMED - every invoice has a matching receipt." : ">>> TALLY DOES NOT MATCH - see details above.",
                  String(repeating: "=", count: 66)]
        let stats: [String: Double] = [
            "inv_total": invTotal, "rec_total": recTotal, "matched_total": matchedTotal,
            "extra_total": extraTotal, "unpaid_total": unpaid.reduce(0) { $0 + ($1.3 ?? 0) },
            "mismatch_total": mismatchTotal, "outstanding_total": out.reduce(0) { $0 + $1.outstanding },
            "outstanding_count": Double(out.count), "matched_count": Double(matched.count),
            "inv_count": Double(ledger.count), "rec_count": Double(receipts.count)
        ]
        return (confirmed, lines.joined(separator: "\n"), stats)
    }

    static func generateOutputs(for document: InvoiceDocument, in folder: URL) throws -> [URL] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = URL(fileURLWithPath: document.path).deletingPathExtension().lastPathComponent
        let spreadsheet = folder.appendingPathComponent("\(base) - Statement.xlsx")
        let letter = folder.appendingPathComponent("\(base) - Forwarding Letter.docx")
        var statementRows: [[Any]] = [
            ["Zhemgang PC \(document.month.isEmpty ? "Electricity Bill Statement" : "Electricity Bill Statement for \(document.month)")", "", "", "", "", ""],
            ["", "", "", "", "", ""],
            ["Sl. No.", "Consumer No.", "Name of Station", "BPC bill Amount", "GST 5%", "Total Amount"]
        ]
        for row in document.rows {
            statementRows.append([row.sl, row.consumerNo, row.station,
                                 row.bpcAmount.map { $0 as Any } ?? "-",
                                 row.gst.map { $0 as Any } ?? "-",
                                 row.total.map { $0 as Any } ?? "-"])
        }
        statementRows.append(["", "", "Total",
                              document.rows.reduce(0) { $0 + ($1.bpcAmount ?? 0) },
                              document.rows.reduce(0) { $0 + ($1.gst ?? 0) },
                              document.rows.reduce(0) { $0 + ($1.total ?? 0) }])
        try createWorkbook(url: spreadsheet, sheetName: "Statement", rows: statementRows)
        try createForwardingLetter(document, url: letter)
        return [spreadsheet, letter]
    }

    static func generateSettlementStatement(for document: InvoiceDocument, receipts: [ReceiptRecord],
                                            sourceName: String, in folder: URL) throws -> URL {
        guard !document.rows.isEmpty else {
            throw BPCError.export("No invoice-statement rows were found for this receipt PDF.")
        }
        let receiptsByConsumer = Dictionary(grouping: receipts.compactMap { receipt -> (String, ReceiptRecord)? in
            guard let consumerNo = receipt.consumerNo, !consumerNo.isEmpty else { return nil }
            return (consumerNo, receipt)
        }, by: \.0)
        var statement = document
        for index in statement.rows.indices where statement.rows[index].docNo?.isEmpty != false {
            let candidates = receiptsByConsumer[statement.rows[index].consumerNo, default: []].map(\.1)
            let matching = candidates.first {
                guard let receiptAmount = $0.amount, let invoiceAmount = statement.rows[index].total else { return false }
                return abs(receiptAmount - invoiceAmount) <= 0.01
            }
            statement.rows[index].docNo = matching?.docNo.isEmpty == false ? matching?.docNo : candidates.first?.docNo
        }
        let missing = statement.rows.filter { $0.docNo?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false }
        guard missing.isEmpty else {
            let numbers = missing.prefix(3).map(\.consumerNo).joined(separator: ", ")
            throw BPCError.export("Receipt document numbers are missing for \(numbers). Add the matching receipt PDF or a settlement PDF with its summary table.")
        }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let baseName = URL(fileURLWithPath: sourceName).deletingPathExtension().lastPathComponent
        var output = folder.appendingPathComponent("\(baseName) - Settlement Statement.docx")
        var suffix = 2
        while FileManager.default.fileExists(atPath: output.path) {
            output = folder.appendingPathComponent("\(baseName) - Settlement Statement (\(suffix)).docx")
            suffix += 1
        }
        try createSettlementStatementDocx(statement, url: output)
        return output
    }

    static func exportTally(_ report: String, to url: URL) throws {
        do { try report.write(to: url, atomically: true, encoding: .utf8) }
        catch { throw BPCError.export(error.localizedDescription) }
    }

    static func exportLogs(_ text: String, to url: URL) throws {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "txt":
            try text.write(to: url, atomically: true, encoding: .utf8)
        case "docx":
            try createDocx(paragraphs: text.components(separatedBy: .newlines), url: url)
        case "xlsx":
            try createWorkbook(url: url, sheetName: "Logs", rows: text.components(separatedBy: .newlines).map { [$0] })
        case "pdf":
            try createPDF(text: text, url: url)
        default:
            throw BPCError.export("Choose a .txt, .docx, .xlsx, or .pdf file.")
        }
    }

    static func exportStations(_ stations: [String: String], to url: URL) throws {
        let rows: [[Any]] = [["Consumer No.", "Name of Station"]] + stations.keys.sorted().map { [$0, stations[$0] ?? ""] }
        try createWorkbook(url: url, sheetName: "Stations", rows: rows)
    }

    static func importStations(from url: URL) throws -> (added: Int, updated: Int, skipped: Int, total: Int, stations: [String: String]) {
        let shared = (try? unzipText(url, "xl/sharedStrings.xml")).map(parseSharedStrings) ?? []
        let sheet = try unzipText(url, "xl/worksheets/sheet1.xml")
        let rows = parseSheetRows(sheet, sharedStrings: shared)
        guard let header = rows.first else { throw BPCError.export("The workbook is empty.") }
        let headers = header.map { $0.lowercased() }
        guard let consumer = headers.firstIndex(where: { $0.contains("consum") }) else {
            throw BPCError.export("No 'Consumer No.' column found in the Excel file.")
        }
        var station = headers.firstIndex(where: { $0.contains("station") && $0 != headers[consumer] })
        if station == nil { station = headers.firstIndex(where: { $0.contains("name") && $0 != headers[consumer] }) }
        if station == nil, headers.count > 1 { station = consumer == 0 ? 1 : 0 }
        guard let station else { throw BPCError.export("No station-name column found in the Excel file.") }
        var result = savedStations()
        var added = 0, updated = 0, skipped = 0
        for row in rows.dropFirst() {
            guard consumer < row.count, station < row.count else { skipped += 1; continue }
            let number = row[consumer].filter(\.isNumber)
            let name = row[station].trimmingCharacters(in: .whitespacesAndNewlines)
            if number.isEmpty && name.isEmpty { continue }
            guard !number.isEmpty && !name.isEmpty else { skipped += 1; continue }
            if result[number] == name { continue }
            if result[number] == nil { added += 1 } else { updated += 1 }
            result[number] = name
        }
        try saveStations(result)
        return (added, updated, skipped, result.count, result)
    }

    private static func createForwardingLetter(_ doc: InvoiceDocument, url: URL) throws {
        let amount = doc.totalAmount ?? doc.rows.reduce(0) { $0 + ($1.total ?? 0) }
        let words = doc.totalWords.isEmpty ? amountWords(amount) : doc.totalWords
        let paragraphs = [
            "Ref: \(doc.reference)\tDate: \(doc.date)",
            "To,\nRegional Director\nCentral Region, BTL\nGelephu",
            "",
            "Subject: Forwarding of Electricity bills",
            "Dear Sir,",
            "",
            "Please find enclosed herewith the following Electricity Bills amounting to Nu.\(amount.moneyString) (\(words)) only for the month of \(doc.month) which needs immediate payment to be made to BPC.",
            "Therefore, may I request the Regional Director, Central Region to kindly arrange to make the payment in favor of the Zhemgang exchange at the earliest.",
            "Yours Sincerely",
            "Namgay Tshering\t\t\t\t\tRegional Director\nManager\t\t\t\t\tCentral Region\nZhemgang\t\t\t\t\tGelephu",
            "",
            "",
            "Registered Office: Drophen Lam 2/28 (975)-2-343434 Post",
            "Box 134, Thimphu 11001, Bhutan.  www.bt.bt"
        ]
        try createDocx(paragraphs: paragraphs, url: url)
    }

    private static func createSettlementStatementDocx(_ document: InvoiceDocument, url: URL) throws {
        let total = document.totalAmount ?? document.rows.reduce(0) { $0 + ($1.total ?? 0) }
        let month = document.month.isEmpty ? "the billing period" : document.month
        let cycle = document.cycle.isEmpty ? "" : " (Cycle \(document.cycle))"
        let widths = [560, 1370, 3400, 1450, 900, 1440, 1346]

        func run(_ text: String, bold: Bool = false, underline: Bool = false, size: Int = 20) -> String {
            "<w:r><w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\"/>\(bold ? "<w:b/>" : "")<w:sz w:val=\"\(size)\"/>\(underline ? "<w:u w:val=\"single\"/>" : "")</w:rPr><w:t xml:space=\"preserve\">\(xmlEscape(text))</w:t></w:r>"
        }

        func paragraph(_ text: String, alignment: String = "left", bold: Bool = false,
                       underline: Bool = false, size: Int = 22, before: Int = 0,
                       after: Int = 110, keepNext: Bool = false) -> String {
            let lines = text.components(separatedBy: "\n")
            let runs = lines.enumerated().map { index, line in
                (index > 0 ? "<w:r><w:br/></w:r>" : "") + run(line, bold: bold, underline: underline, size: size)
            }.joined()
            return "<w:p><w:pPr>\(keepNext ? "<w:keepNext/>" : "")<w:spacing w:before=\"\(before)\" w:after=\"\(after)\"/><w:jc w:val=\"\(alignment)\"/></w:pPr>\(runs)</w:p>"
        }

        func cell(_ text: String, width: Int, header: Bool = false,
                  alignment: String = "left", bold: Bool = false,
                  span: Int = 1) -> String {
            let cellWidth = span == 1 ? width : width
            let shade = header ? "<w:shd w:fill=\"DDE7F0\"/>" : ""
            let gridSpan = span > 1 ? "<w:gridSpan w:val=\"\(span)\"/>" : ""
            let cellText = text.components(separatedBy: "\n").enumerated().map { index, line in
                (index > 0 ? "<w:r><w:br/></w:r>" : "") + run(line, bold: bold || header, size: header ? 18 : 20)
            }.joined()
            return "<w:tc><w:tcPr><w:tcW w:w=\"\(cellWidth)\" w:type=\"dxa\"/>\(gridSpan)\(shade)<w:tcMar><w:top w:w=\"70\" w:type=\"dxa\"/><w:left w:w=\"75\" w:type=\"dxa\"/><w:bottom w:w=\"70\" w:type=\"dxa\"/><w:right w:w=\"75\" w:type=\"dxa\"/></w:tcMar><w:vAlign w:val=\"center\"/></w:tcPr><w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/><w:jc w:val=\"\(alignment)\"/></w:pPr>\(cellText)</w:p></w:tc>"
        }

        let borders = """
        <w:tblBorders><w:top w:val="single" w:sz="6" w:color="1F2937"/><w:left w:val="single" w:sz="4" w:color="1F2937"/><w:bottom w:val="single" w:sz="4" w:color="1F2937"/><w:right w:val="single" w:sz="4" w:color="1F2937"/><w:insideH w:val="single" w:sz="4" w:color="7B8794"/><w:insideV w:val="single" w:sz="4" w:color="7B8794"/></w:tblBorders>
        """
        let grid = widths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined()
        let headers = ["Sl.\nNo.", "Consumer\nNo.", "Name of Station", "BPC bill\nAmount (Nu.)",
                       "GST 5%\n(Nu.)", "Total Amount\n(Nu.)", "Doc No."]
        let headerCells = zip(headers, widths).map { cell($0.0, width: $0.1, header: true, alignment: "center") }.joined()
        let headerRow = "<w:tr><w:trPr><w:tblHeader w:val=\"true\"/></w:trPr>\(headerCells)</w:tr>"
        let dataRows = document.rows.map { row in
            let values = [
                (String(row.sl), widths[0], "center"),
                (row.consumerNo, widths[1], "left"),
                (row.station, widths[2], "left"),
                (row.bpcAmount.map(\.moneyString) ?? "-", widths[3], "right"),
                (row.gst.map(\.moneyString) ?? "-", widths[4], "right"),
                (row.total.map(\.moneyString) ?? "-", widths[5], "right"),
                (row.docNo ?? "", widths[6], "left")
            ]
            return "<w:tr>\(values.map { cell($0.0, width: $0.1, alignment: $0.2) }.joined())</w:tr>"
        }.joined()
        let bpcTotal = document.rows.reduce(0) { $0 + ($1.bpcAmount ?? 0) }
        let gstTotal = document.rows.reduce(0) { $0 + ($1.gst ?? 0) }
        let tableTotal = document.rows.reduce(0) { $0 + ($1.total ?? 0) }
        let totalRow = "<w:tr><w:trPr><w:cantSplit/></w:trPr>" +
            cell("Total", width: widths.prefix(3).reduce(0, +), alignment: "right", bold: true, span: 3) +
            cell(bpcTotal.moneyString, width: widths[3], alignment: "right", bold: true) +
            cell(gstTotal.moneyString, width: widths[4], alignment: "right", bold: true) +
            cell(tableTotal.moneyString, width: widths[5], alignment: "right", bold: true) +
            cell("", width: widths[6]) + "</w:tr>"
        let table = """
        <w:tbl><w:tblPr><w:tblW w:w="10466" w:type="dxa"/>\(borders)<w:tblLayout w:type="fixed"/><w:tblCellMar><w:top w:w="70" w:type="dxa"/><w:left w:w="75" w:type="dxa"/><w:bottom w:w="70" w:type="dxa"/><w:right w:w="75" w:type="dxa"/></w:tblCellMar></w:tblPr><w:tblGrid>\(grid)</w:tblGrid>\(headerRow)\(dataRows)\(totalRow)</w:tbl>
        """
        let refDate = "<w:p><w:pPr><w:tabs><w:tab w:val=\"right\" w:pos=\"9000\"/></w:tabs><w:spacing w:after=\"260\"/></w:pPr>\(run("Ref: \(document.reference)"))<w:r><w:tab/></w:r>\(run("Date: \(document.date)"))</w:p>"
        let title = paragraph("Electricity Bill Payment Settlement", alignment: "center", bold: true,
                              underline: true, size: 24, before: 80, after: 220, keepNext: true)
        let intro = paragraph("We are forwarding herewith the electricity bills payment money receipts amounting to Nu. (\(total.moneyString)) only for the month of \(month), the details of money receipt numbers and their copies are attached for your reference and settlement please.")
        let statementTitle = paragraph("Zhemgang PC Electricity Bill Statement for \(month)", alignment: "center",
                                       bold: true, size: 23, before: 180, after: 180, keepNext: true)
        let signoff = paragraph("Namgay Tshering     Regional Director\nManager               Central Region\nZhemgang              Gelephu",
                                alignment: "right", size: 20, before: 180, after: 120)
        let footer = paragraph("Registered Office: Drophen Lam 2/28 Post Box 134, Thimphu 11001, Bhutan.  (975)-2-343434  www.bt.bt",
                               alignment: "center", size: 16, before: 220, after: 0)
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(refDate)\(paragraph("The Accountant,\nFinance & Accounts BTL,\nThimphu", after: 180))\(paragraph("Sub: Electricity Bill payment settlement for Zhemgang PC for \(month)\(cycle)", bold: true, underline: true, after: 180))\(paragraph("Sir,", after: 70))\(intro)\(title)\(statementTitle)\(table)\(signoff)\(footer)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="700" w:right="720" w:bottom="700" w:left="720"/></w:sectPr></w:body></w:document>
        """
        try makeZip(url: url, files: [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
            """,
            "word/document.xml": documentXML
        ])
    }

    private static func createDocx(paragraphs: [String], url: URL) throws {
        let body = paragraphs.map { paragraph in
            "<w:p><w:r><w:t xml:space=\"preserve\">\(xmlEscape(paragraph))</w:t></w:r></w:p>"
        }.joined()
        let document = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1134" w:right="1417" w:bottom="1134" w:left="1417"/></w:sectPr></w:body></w:document>
        """
        try makeZip(url: url, files: [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
            """,
            "word/document.xml": document
        ])
    }

    private static func createWorkbook(url: URL, sheetName: String, rows: [[Any]]) throws {
        let maxColumns = max(1, rows.map(\.count).max() ?? 1)
        var sheetRows = ""
        for (rowIndex, row) in rows.enumerated() {
            let cells = row.enumerated().map { colIndex, value -> String in
                let reference = "\(columnName(colIndex + 1))\(rowIndex + 1)"
                let style = sheetName == "Statement" && rowIndex == 0 ? 3
                    : sheetName == "Statement" && rowIndex == 2 ? 1
                    : rowIndex > 0 && rowIndex < rows.count - 1 && colIndex >= 3 ? 2 : 0
                if let number = value as? Int { return "<c r=\"\(reference)\"><v>\(number)</v></c>" }
                if let number = value as? Double, number.isFinite {
                    return "<c r=\"\(reference)\" s=\"\(style)\"><v>\(number)</v></c>"
                }
                let text = String(describing: value)
                return "<c r=\"\(reference)\" s=\"\(style)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(text))</t></is></c>"
            }.joined()
            sheetRows += "<row r=\"\(rowIndex + 1)\">\(cells)</row>"
        }
        let lastColumn = columnName(maxColumns)
        let merges = sheetName == "Statement" ? "<mergeCells count=\"1\"><mergeCell ref=\"A1:G1\"/></mergeCells>" : ""
        let widths = sheetName == "Statement" ? [8, 14, 34, 14, 11, 14, 14] : [18, 34]
        let columns = widths.enumerated().map { idx, width in
            "<col min=\"\(idx + 1)\" max=\"\(idx + 1)\" width=\"\(width)\" customWidth=\"1\"/>"
        }.joined()
        let sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><dimension ref="A1:\(lastColumn)\(max(1, rows.count))"/><sheetViews><sheetView workbookViewId="0"/></sheetViews><sheetFormatPr defaultRowHeight="18"/><cols>\(columns)</cols><sheetData>\(sheetRows)</sheetData>\(merges)<pageMargins left="0.25" right="0.25" top="0.5" bottom="0.5" header="0.2" footer="0.2"/></worksheet>
        """
        let safeSheet = xmlEscape(sheetName)
        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="1"><numFmt numFmtId="164" formatCode="#,##0.00"/></numFmts><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FFDDE7F0"/><bgColor indexed="64"/></patternFill></fill></fills><borders count="2"><border/><border><left style="thin"><color rgb="FF000000"/></left><right style="thin"><color rgb="FF000000"/></right><top style="thin"><color rgb="FF000000"/></top><bottom style="thin"><color rgb="FF000000"/></bottom></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="4"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="1" applyAlignment="1" xfId="0"><alignment horizontal="center" vertical="center" wrapText="1"/></xf><xf numFmtId="164" fontId="0" fillId="0" borderId="1" xfId="0" applyNumberFormat="1"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" applyAlignment="1" xfId="0"><alignment horizontal="center" vertical="center"/></xf></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """
        try makeZip(url: url, files: [
            "[Content_Types].xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
            """,
            "_rels/.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
            """,
            "xl/workbook.xml": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="\(safeSheet)" sheetId="1" r:id="rId1"/></sheets></workbook>
            """,
            "xl/_rels/workbook.xml.rels": """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
            """,
            "xl/styles.xml": styles,
            "xl/worksheets/sheet1.xml": sheet
        ])
    }

    private static func createPDF(text: String, url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw BPCError.export("Could not create the PDF output file.")
        }
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.black
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var location = 0
        while location < attributed.length {
            context.beginPDFPage(nil)
            let path = CGMutablePath()
            path.addRect(CGRect(x: 48, y: 48, width: 516, height: 696))
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else { context.endPDFPage(); break }
            location += visible.length
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func makeZip(url: URL, files: [String: String]) throws {
        let manager = FileManager.default
        let temp = manager.temporaryDirectory.appendingPathComponent("bpc-export-\(UUID().uuidString)", isDirectory: true)
        do {
            try manager.createDirectory(at: temp, withIntermediateDirectories: true)
            for (path, contents) in files {
                let target = temp.appendingPathComponent(path)
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try contents.write(to: target, atomically: true, encoding: .utf8)
            }
            try? manager.removeItem(at: url)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            process.currentDirectoryURL = temp
            process.arguments = ["-q", "-r", url.path] + files.keys.sorted()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw BPCError.export("The document archive could not be packaged.") }
        } catch {
            try? manager.removeItem(at: url)
            throw error
        }
        try? manager.removeItem(at: temp)
    }

    private static func unzipText(_ url: URL, _ entry: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, entry]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw BPCError.export("The workbook could not be read as .xlsx.") }
        return String(decoding: data, as: UTF8.self)
    }

    private final class XMLRows: NSObject, XMLParserDelegate {
        var shared: [String]
        var rows: [[String]] = []
        private var row: [String] = []
        private var cellType = ""
        private var cellRef = ""
        private var value = ""
        private var cellValue = ""
        init(shared: [String]) { self.shared = shared }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
            if name == "row" { row = [] }
            if name == "c" {
                cellType = attributes["t"] ?? ""
                cellRef = attributes["r"] ?? ""
                cellValue = ""
            } else if name == "v" || name == "t" {
                value = ""
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { value += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            if name == "v" || name == "t" {
                if name == "t" && cellType == "inlineStr" { cellValue += value }
                else if name == "v" { cellValue = value }
            } else if name == "c" {
                let letters = cellRef.utf8.prefix { (65...90).contains($0) || (97...122).contains($0) }
                let column = letters.reduce(0) { partial, byte in
                    let uppercase = byte >= 97 ? byte - 32 : byte
                    return partial * 26 + Int(uppercase - 64)
                } - 1
                guard column >= 0 else { return }
                while row.count <= column { row.append("") }
                let decoded = cellType == "s"
                    ? (Int(cellValue).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? cellValue)
                    : cellValue
                row[column] = decoded
            } else if name == "row" {
                rows.append(row)
            }
        }
    }

    private static func parseSharedStrings(_ xml: String) -> [String] {
        let parser = XMLParser(data: Data(xml.utf8))
        let collector = SharedStringCollector()
        parser.delegate = collector
        parser.parse()
        return collector.values
    }

    private final class SharedStringCollector: NSObject, XMLParserDelegate {
        var values: [String] = []
        private var current = ""
        private var inString = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
            if name == "si" { inString = true; current = "" }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inString { current += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            if name == "si" { values.append(current); inString = false }
        }
    }

    private static func parseSheetRows(_ xml: String, sharedStrings: [String]) -> [[String]] {
        let parser = XMLParser(data: Data(xml.utf8))
        let collector = XMLRows(shared: sharedStrings)
        parser.delegate = collector
        parser.parse()
        return collector.rows
    }

    private static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\n", with: "</w:t></w:r><w:r><w:br/><w:t xml:space=\"preserve\">")
    }

    private static func columnName(_ number: Int) -> String {
        var n = number
        var result = ""
        while n > 0 {
            n -= 1
            result = String(UnicodeScalar(65 + n % 26)!) + result
            n /= 26
        }
        return result
    }

    private static func capture(_ text: String, _ pattern: String, group: Int = 1) -> String? {
        guard let match = matches(pattern, in: text).first else { return nil }
        return self.group(match, group, in: text)
    }

    private static func captures(_ text: String, _ pattern: String) -> [String]? {
        guard let match = matches(pattern, in: text).first else { return nil }
        return (1..<match.numberOfRanges).map { group(match, $0, in: text) ?? "" }
    }

    private static func group(_ match: NSTextCheckingResult, _ idx: Int, in text: String) -> String? {
        guard idx < match.numberOfRanges, match.range(at: idx).location != NSNotFound else { return nil }
        return (text as NSString).substring(with: match.range(at: idx))
    }

    private static func matches(_ pattern: String, in text: String, range: NSRange? = nil) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: range ?? NSRange(location: 0, length: (text as NSString).length))
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        matches(pattern, in: text).compactMap { group($0, 1, in: text) }
    }

    private static func replacing(_ text: String, pattern: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: replacement)
    }

    private static func money(_ text: String?) -> Double? {
        guard let text else { return nil }
        let normalized = text.filter { $0 != "," && !$0.isWhitespace }
        return Double(normalized)
    }

    private static func receiptMoney(_ raw: String) -> Double? {
        let digits = digitsOnly(raw)
        guard let value = Double(digits) else { return nil }
        return digits.count >= 3 ? value / 100 : value
    }

    private static func digitsOnly(_ text: String) -> String { text.filter(\.isNumber) }

    private static func nearestMatch(_ pattern: String, in text: String, target: Int, limit: Int) -> NSTextCheckingResult? {
        matches(pattern, in: text).filter { abs($0.range.location - target) <= limit }
            .min { abs($0.range.location - target) < abs($1.range.location - target) }
    }

    private static func mostCommon(_ values: [String]) -> String {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.max { $0.value < $1.value }?.key ?? ""
    }

    private static func billingMonth(_ dates: [String]) -> String {
        let most = mostCommon(dates.filter { !$0.isEmpty })
        let parts = most.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return "" }
        let months = Calendar.current.monthSymbols
        let month = parts[1], year = parts[2]
        guard (1...12).contains(month), months.count >= 12 else { return "" }
        if month == 1 { return "December \(year - 1)" }
        return "\(months[month - 2]) \(year)"
    }

    private static func cycleFromMonth(_ month: String) -> String {
        guard let first = month.split(separator: " ").first,
              let index = Calendar.current.monthSymbols.firstIndex(where: { $0.caseInsensitiveCompare(String(first)) == .orderedSame }) else { return "" }
        return String((index + 1) % 12 + 1)
    }

    private static func cycleFromReceipt(_ text: String) -> String {
        guard let groups = captures(text, #"(?i)for\s+the\s+month\s+of\s+([A-Za-z]+)\s*,?\s*(\d{4})"#),
              let month = Calendar.current.monthSymbols.firstIndex(where: { $0.caseInsensitiveCompare(groups[0]) == .orderedSame }) else { return "" }
        return String((month + 1) % 12 + 1)
    }

    private static func wordsNumber(_ text: String) -> Double? {
        let units = ["zero":0,"one":1,"two":2,"three":3,"four":4,"five":5,"six":6,"seven":7,"eight":8,"nine":9,"ten":10,
                     "eleven":11,"twelve":12,"thirteen":13,"fourteen":14,"fifteen":15,"sixteen":16,"seventeen":17,"eighteen":18,"nineteen":19]
        let tens = ["twenty":20,"thirty":30,"forty":40,"fifty":50,"sixty":60,"seventy":70,"eighty":80,"ninety":90]
        var current = 0.0, total = 0.0, found = false
        for token in text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter({ !$0.isEmpty }) {
            if let value = units[token] { current += Double(value); found = true }
            else if let value = tens[token] { current += Double(value); found = true }
            else if token == "hundred" { current *= 100 }
            else if token == "thousand" { total += current * 1000; current = 0 }
            else if token == "million" { total += current * 1_000_000; current = 0 }
            else if ["and", "only", "ch", "nu"].contains(token) { continue }
            else { return nil }
        }
        return found ? total + current : nil
    }

    private static func amountWords(_ amount: Double) -> String {
        let ones = ["Zero","One","Two","Three","Four","Five","Six","Seven","Eight","Nine","Ten","Eleven","Twelve","Thirteen","Fourteen","Fifteen","Sixteen","Seventeen","Eighteen","Nineteen"]
        let tens = ["","","Twenty","Thirty","Forty","Fifty","Sixty","Seventy","Eighty","Ninety"]
        func underThousand(_ number: Int) -> String {
            var n = number
            var parts: [String] = []
            if n >= 100 { parts += [ones[n / 100], "Hundred"]; n %= 100 }
            if n >= 20 { parts.append(tens[n / 10]); if n % 10 > 0 { parts.append(ones[n % 10]) } }
            else if n > 0 { parts.append(ones[n]) }
            return parts.joined(separator: " ")
        }
        var n = Int(amount.rounded())
        if n == 0 { return "Zero" }
        var parts: [String] = []
        if n >= 1_000_000 { parts += [underThousand(n / 1_000_000), "Million"]; n %= 1_000_000 }
        if n >= 1_000 { parts += [underThousand(n / 1_000), "Thousand"]; n %= 1_000 }
        if n > 0 { parts.append(underThousand(n)) }
        return parts.joined(separator: " ")
    }
}

private extension Double {
    var rounded2: Double { (self * 100).rounded() / 100 }
    var moneyString: String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: self)) ?? String(format: "%.2f", self)
    }
}
