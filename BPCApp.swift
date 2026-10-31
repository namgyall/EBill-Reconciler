import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct BPCReconcilerApp: App {
    @NSApplicationDelegateAdaptor(BPCApplicationDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .frame(minWidth: 1180, minHeight: 780)
                .preferredColorScheme(.light)
                .background(WindowGlassConfigurator())
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1480, height: 940)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
private final class BPCApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

enum FileKind: Equatable {
    case invoice, receipt
}

struct StationRow: Identifiable, Hashable {
    var id: String
    var station: String
    var consumerNo: String
}

@MainActor
final class ReconcilerModel: ObservableObject {
    @Published var invoiceFiles: [URL] = []
    @Published var receiptFiles: [URL] = []
    @Published var invoiceDocuments: [String: InvoiceDocument] = [:]
    @Published var receiptRecords: [String: [ReceiptRecord]] = [:]
    @Published var selectedInvoiceIDs: Set<UUID> = []
    @Published var selectedReceiptIDs: Set<UUID> = []
    @Published var selectedStationIDs: Set<String> = []
    @Published var search = ""
    @Published var logs = ""
    @Published var status = "Ready"
    @Published var outputFolder = BPCServices.outputFolder()
    @Published var busy = false
    @Published var lastTally: Bool?
    @Published var alertText: String?
    @Published var errorText: String?
    @Published var showAddStation = false
    @Published var stationRows: [StationRow] = []
    @Published var importKind: FileKind = .invoice

    private var invoiceLoading: Set<String> = []
    private var receiptLoading: Set<String> = []
    private var invoicePlaceholders: [String: InvoiceRow] = [:]
    private var receiptPlaceholders: [String: ReceiptRecord] = [:]
    private var activeFileAccess: [String: URL] = [:]
    private var activeOutputAccess: URL?

    init() {
        refreshStations()
        log("BPC E-bill Reconciler ready.")
        log("PDFKit and built-in Vision OCR ready (scanned PDFs supported).")
    }

    var visibleInvoiceRows: [InvoiceRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [InvoiceRow] = []
        for url in invoiceFiles {
            if let document = invoiceDocuments[url.path] {
                result.append(contentsOf: document.rows.filter { row in
                    query.isEmpty || [row.station, row.consumerNo, row.cycle].contains { $0.localizedCaseInsensitiveContains(query) }
                })
            } else if query.isEmpty, var placeholder = invoicePlaceholders[url.path] {
                placeholder.sl = result.count + 1
                result.append(placeholder)
            }
        }
        return result
    }

    var visibleReceipts: [ReceiptRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return receiptFiles.flatMap { url -> [ReceiptRecord] in
            if let records = receiptRecords[url.path], !records.isEmpty { return records }
            return receiptPlaceholders[url.path].map { [$0] } ?? []
        }.filter { record in
            query.isEmpty || [record.station, record.consumerNo ?? "", record.docNo, record.cycle].contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var invoiceCountText: String { "Invoices (\(visibleInvoiceRows.count == 0 ? invoiceFiles.count : visibleInvoiceRows.count))" }
    var receiptCountText: String { "Receipts (\(visibleReceipts.count == 0 ? receiptFiles.count : visibleReceipts.count))" }

    func log(_ text: String) {
        let time = Date.now.formatted(date: .omitted, time: .shortened)
        logs += "[\(time)] \(text)\n"
    }

    func addFiles(_ urls: [URL], kind: FileKind) {
        var newURLs: [URL] = []
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            let store = kind == .invoice ? invoiceFiles : receiptFiles
            if store.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) { continue }
            if url.startAccessingSecurityScopedResource() {
                activeFileAccess[url.path] = url
            }
            newURLs.append(url)
        }
        guard !newURLs.isEmpty else { return }
        if kind == .invoice {
            invoiceFiles.append(contentsOf: newURLs)
        } else {
            receiptFiles.append(contentsOf: newURLs)
        }
        for url in newURLs {
            if kind == .invoice {
                invoicePlaceholders[url.path] = InvoiceRow(sourcePath: url.path, sl: invoiceFiles.count, consumerNo: "Reading…",
                    station: url.lastPathComponent, bpcAmount: nil, gst: nil, total: nil,
                    outstanding: nil, otherOutstanding: nil, cycle: "")
            } else {
                receiptPlaceholders[url.path] = ReceiptRecord(sourcePath: url.path, docNo: url.lastPathComponent,
                    consumerNo: nil, bpNo: nil, amount: nil, amountWords: "",
                    date: "", station: "Reading…", cycle: "")
            }
            log("Added \(kind == .invoice ? "invoice" : "receipt"): \(url.lastPathComponent)")
            Task { await parse(url, kind: kind) }
        }
    }

    private func parse(_ url: URL, kind: FileKind) async {
        if kind == .invoice { invoiceLoading.insert(url.path) } else { receiptLoading.insert(url.path) }
        do {
            if kind == .invoice {
                let document = try await Task.detached(priority: .userInitiated) {
                    try BPCServices.parseInvoice(url)
                }.value
                invoiceDocuments[url.path] = document
                invoicePlaceholders.removeValue(forKey: url.path)
                log("Invoice \(url.lastPathComponent): \(document.rows.count) bill(s) — Nu.\(document.rows.reduce(0) { $0 + ($1.total ?? 0) }.moneyString)")
            } else {
                var records = try await Task.detached(priority: .userInitiated) {
                    try BPCServices.parseReceipts(url)
                }.value
                for idx in records.indices { records[idx].sourcePath = url.path }
                receiptRecords[url.path] = records
                if !records.isEmpty {
                    receiptPlaceholders.removeValue(forKey: url.path)
                } else if var row = receiptPlaceholders[url.path] {
                    row.station = "No receipts found"
                    receiptPlaceholders[url.path] = row
                }
                log("Receipt file \(url.lastPathComponent): \(records.count) receipt(s) — Nu.\(records.reduce(0) { $0 + ($1.amount ?? 0) }.moneyString)")
            }
        } catch {
            log("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
            errorText = error.localizedDescription
            if kind == .invoice, var row = invoicePlaceholders[url.path] {
                row.consumerNo = "Not read"
                invoicePlaceholders[url.path] = row
            } else if kind == .receipt, var row = receiptPlaceholders[url.path] {
                row.station = "Not read"
                receiptPlaceholders[url.path] = row
            }
        }
        invoiceLoading.remove(url.path)
        receiptLoading.remove(url.path)
    }

    func removeSelectedInvoices() {
        let paths = Set(visibleInvoiceRows.filter { selectedInvoiceIDs.contains($0.id) }.compactMap(\.sourcePath))
        guard !paths.isEmpty else { errorText = "Select one or more invoice rows to remove."; return }
        invoiceFiles.removeAll { paths.contains($0.path) }
        for path in paths {
            invoiceDocuments.removeValue(forKey: path)
            invoicePlaceholders.removeValue(forKey: path)
            releaseFileAccess(path)
        }
        selectedInvoiceIDs.removeAll()
        log("Removed \(paths.count) invoice file(s).")
    }

    func removeSelectedReceipts() {
        let paths = Set(visibleReceipts.filter { selectedReceiptIDs.contains($0.id) }.compactMap(\.sourcePath))
        guard !paths.isEmpty else { errorText = "Select one or more receipt rows to remove."; return }
        receiptFiles.removeAll { paths.contains($0.path) }
        for path in paths {
            receiptRecords.removeValue(forKey: path)
            receiptPlaceholders.removeValue(forKey: path)
            releaseFileAccess(path)
        }
        selectedReceiptIDs.removeAll()
        log("Removed \(paths.count) receipt file(s).")
    }

    func clearInvoices() {
        guard !invoiceFiles.isEmpty else { return }
        let count = invoiceFiles.count
        invoiceFiles.forEach { releaseFileAccess($0.path) }
        invoiceFiles.removeAll()
        invoiceDocuments.removeAll()
        invoicePlaceholders.removeAll()
        selectedInvoiceIDs.removeAll()
        log("Removed all \(count) invoice file(s).")
    }

    func clearReceipts() {
        guard !receiptFiles.isEmpty else { return }
        let count = receiptFiles.count
        receiptFiles.forEach { releaseFileAccess($0.path) }
        receiptFiles.removeAll()
        receiptRecords.removeAll()
        receiptPlaceholders.removeAll()
        selectedReceiptIDs.removeAll()
        log("Removed all \(count) receipt file(s).")
    }

    func chooseOutputFolder(_ url: URL) {
        activeOutputAccess?.stopAccessingSecurityScopedResource()
        activeOutputAccess = url.startAccessingSecurityScopedResource() ? url : nil
        outputFolder = url
        do {
            try BPCServices.setOutputFolder(url)
            log("Output folder saved: \(url.path)")
        } catch {
            errorText = error.localizedDescription
        }
    }

    func openOutputFolder() {
        do {
            try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            guard NSWorkspace.shared.open(outputFolder) else {
                throw BPCError.export("The output folder could not be opened.")
            }
        } catch { errorText = error.localizedDescription }
    }

    func generate() {
        guard beginWork() else { return }
        guard !invoiceFiles.isEmpty else { fail("Add at least one invoice PDF first."); return }
        log("Generating statements and forwarding letters…")
        let destination = outputFolder
        Task {
            do {
                var documents: [InvoiceDocument] = []
                for url in invoiceFiles {
                    let doc = try await invoiceDocument(for: url)
                    let outputs = try await Task.detached(priority: .userInitiated) {
                        try BPCServices.generateOutputs(for: doc, in: destination)
                    }.value
                    documents.append(doc)
                    outputs.forEach { log("Created: \($0.lastPathComponent)") }
                }
                reportOutstanding(in: documents)
                log("Done. Generated \(documents.count) statement(s) and forwarding letter(s) in \(outputFolder.path)")
                status = "Ready"
                busy = false
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    func generateStatement() {
        guard beginWork() else { return }
        guard !receiptFiles.isEmpty else { fail("Add at least one settlement receipt PDF first."); return }
        log("Generating settlement statement documents…")
        let destination = outputFolder
        Task {
            do {
                let receipts = try await loadReceipts()
                let invoiceDocuments = invoiceFiles.isEmpty ? [] : try await loadInvoices()
                for receiptURL in receiptFiles {
                    let fileReceipts = receipts.filter { $0.sourcePath == receiptURL.path }
                    guard !fileReceipts.isEmpty else {
                        throw BPCError.export("No receipt records were found in \(receiptURL.lastPathComponent).")
                    }
                    let embeddedDocument = try await Task.detached(priority: .userInitiated) {
                        try BPCServices.parseInvoiceIfAvailable(receiptURL)
                    }.value
                    let consumerNumbers = Set(fileReceipts.compactMap(\.consumerNo))
                    let completeEmbeddedDocument = embeddedDocument.flatMap { document in
                        consumerNumbers.isSubset(of: Set(document.rows.map(\.consumerNo))) ? document : nil
                    }
                    let matchingInvoice = invoiceDocuments.first { document in
                        consumerNumbers.isSubset(of: Set(document.rows.map(\.consumerNo)))
                    }
                    guard let document = completeEmbeddedDocument ?? matchingInvoice else {
                        throw BPCError.export("Could not match \(receiptURL.lastPathComponent) to an invoice statement. Add the matching invoice PDF or use a receipt PDF that includes its settlement summary.")
                    }
                    let output = try await Task.detached(priority: .userInitiated) {
                        try BPCServices.generateSettlementStatement(for: document, receipts: fileReceipts,
                            sourceName: receiptURL.lastPathComponent, in: destination)
                    }.value
                    log("Created: \(output.lastPathComponent)")
                }
                log("Settlement statement DOCX file(s) saved in \(outputFolder.path)")
                status = "Ready"
                busy = false
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    func checkOutstanding() {
        guard beginWork() else { return }
        guard !invoiceFiles.isEmpty else { fail("Add at least one invoice PDF first."); return }
        log("Checking for outstanding amounts…")
        Task {
            do {
                let docs = try await loadInvoices()
                let items = BPCServices.outstanding(in: docs)
                if items.isEmpty {
                    log("No outstanding amounts found in \(docs.count) invoice file(s).")
                } else {
                    let text = BPCServices.outstandingText(items)
                    log("OUTSTANDING AMOUNTS:\n\(text)")
                    alertText = "Outstanding Amount Alert\n\n\(text)"
                }
                status = "Ready"
                busy = false
            } catch { fail(error.localizedDescription) }
        }
    }

    func runTally() {
        guard beginWork() else { return }
        guard !invoiceFiles.isEmpty else { fail("Add at least one invoice PDF first."); return }
        guard !receiptFiles.isEmpty else { fail("Add at least one settlement receipt PDF first."); return }
        log("Running tally…")
        Task {
            do {
                let docs = try await loadInvoices()
                let receipts = try await loadReceipts()
                let report = await Task.detached(priority: .userInitiated) {
                    BPCServices.tally(documents: docs, receipts: receipts)
                }.value
                report.text.components(separatedBy: .newlines).forEach { log($0) }
                try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
                let reportURL = outputFolder.appendingPathComponent("Tally Report.txt")
                try BPCServices.exportTally(report.text, to: reportURL)
                log("Report saved to: \(reportURL.path)")
                lastTally = report.confirmed
                status = report.confirmed ? "TALLY CONFIRMED" : "TALLY DOES NOT MATCH"
                if !BPCServices.outstanding(in: docs).isEmpty {
                    alertText = "Outstanding Amount Alert\n\n\(BPCServices.outstandingText(BPCServices.outstanding(in: docs)))"
                }
                log(status)
                busy = false
            } catch { fail(error.localizedDescription) }
        }
    }

    private func beginWork() -> Bool {
        guard !busy else { log("Already working…"); return false }
        busy = true
        status = "Working…"
        return true
    }

    private func releaseFileAccess(_ path: String) {
        activeFileAccess.removeValue(forKey: path)?.stopAccessingSecurityScopedResource()
    }

    private func fail(_ message: String) {
        busy = false
        status = "Ready"
        errorText = message
        log("ERROR: \(message)")
    }

    private func invoiceDocument(for url: URL) async throws -> InvoiceDocument {
        if let cached = invoiceDocuments[url.path] { return cached }
        log("Parsing invoice \(url.lastPathComponent)…")
        let doc = try await Task.detached(priority: .userInitiated) { try BPCServices.parseInvoice(url) }.value
        invoiceDocuments[url.path] = doc
        return doc
    }

    private func loadInvoices() async throws -> [InvoiceDocument] {
        var docs: [InvoiceDocument] = []
        for url in invoiceFiles { docs.append(try await invoiceDocument(for: url)) }
        return docs
    }

    private func loadReceipts() async throws -> [ReceiptRecord] {
        var result: [ReceiptRecord] = []
        for url in receiptFiles {
            var records: [ReceiptRecord]
            if let cached = receiptRecords[url.path] {
                records = cached
            } else {
                log("Parsing receipts \(url.lastPathComponent)…")
                records = try await Task.detached(priority: .userInitiated) {
                    try BPCServices.parseReceipts(url)
                }.value
            }
            for index in records.indices { records[index].sourcePath = url.path }
            receiptRecords[url.path] = records
            result.append(contentsOf: records)
        }
        return result
    }

    private func reportOutstanding(in documents: [InvoiceDocument]) {
        let items = BPCServices.outstanding(in: documents)
        guard !items.isEmpty else { return }
        let text = BPCServices.outstandingText(items)
        log("OUTSTANDING AMOUNTS:\n\(text)")
        alertText = "Outstanding Amount Alert\n\n\(text)"
    }

    func refreshStations() {
        stationRows = BPCServices.allStations().map { StationRow(id: $0.key, station: $0.value, consumerNo: $0.key) }
            .sorted { $0.station.localizedCaseInsensitiveCompare($1.station) == .orderedAscending }
    }

    func addStation(number: String, name: String) {
        do {
            let normalized = try BPCServices.addStation(number: number, name: name)
            refreshStations()
            log("Station added: \(normalized) — \(name.trimmingCharacters(in: .whitespacesAndNewlines)).")
        } catch { errorText = error.localizedDescription }
    }

    func removeStations() {
        guard !selectedStationIDs.isEmpty else { errorText = "Select a station row to remove."; return }
        do {
            for number in selectedStationIDs { try BPCServices.removeStation(number: number) }
            log("Removed \(selectedStationIDs.count) station(s).")
            selectedStationIDs.removeAll()
            refreshStations()
        } catch { errorText = error.localizedDescription }
    }

    func importStations() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.spreadsheet]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an .xlsx station list"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let result = try BPCServices.importStations(from: url)
            refreshStations()
            log("Stations saved: \(result.added) new, \(result.updated) updated (\(result.total) in store).")
        } catch { fail("Stations import failed: \(error.localizedDescription)") }
    }

    func exportStations() {
        let saved = BPCServices.savedStations()
        guard !saved.isEmpty else { errorText = "No saved stations to export."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.spreadsheet]
        panel.nameFieldStringValue = "BPC Stations.xlsx"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            try BPCServices.exportStations(saved, to: url)
            log("Exported \(saved.count) saved stations to \(url.path).")
        } catch { errorText = error.localizedDescription }
    }

    func exportLogs() {
        guard !logs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { errorText = "No logs to export."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText, .pdf, .spreadsheet, .init(filenameExtension: "docx")!]
        panel.nameFieldStringValue = "BPC Logs.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            try BPCServices.exportLogs(logs, to: url)
            log("Logs exported to: \(url.path)")
        } catch { errorText = error.localizedDescription }
    }
}

private struct DashboardView: View {
    @StateObject private var model = ReconcilerModel()
    @StateObject private var ui = DashboardUIState()

    var body: some View {
        VStack(spacing: 12) {
            header
            HStack(alignment: .top, spacing: 12) {
                leftColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                stationsCard
                    .frame(width: 360)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(16)
        .font(.menlo(size: 13))
        .background {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.34),
                        Color(red: 0.90, green: 0.97, blue: 0.93).opacity(0.23),
                        Color.white.opacity(0.29)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [Color.white.opacity(0.42), .clear],
                    center: .topLeading,
                    startRadius: 10,
                    endRadius: 620
                )
                RadialGradient(
                    colors: [Color(red: 0.67, green: 0.88, blue: 0.76).opacity(0.22), .clear],
                    center: .bottomTrailing,
                    startRadius: 12,
                    endRadius: 560
                )
            }
            .ignoresSafeArea()
        }
        .fileImporter(isPresented: $ui.isImporterPresented,
                      allowedContentTypes: model.importKind == .invoice ? [.pdf] : [.pdf],
                      allowsMultipleSelection: true, onCompletion: handleFileImport)
        .fileImporter(isPresented: $ui.isFolderImporterPresented, allowedContentTypes: [.folder],
                      allowsMultipleSelection: false, onCompletion: handleFolderImport)
        .sheet(isPresented: $model.showAddStation) {
            AddStationSheet { no, name in model.addStation(number: no, name: name) }
        }
        .alert("BPC E-bill Reconciler", isPresented: Binding(
            get: { model.errorText != nil },
            set: { if !$0 { model.errorText = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorText = nil }
        } message: {
            Text(model.errorText ?? "")
        }
        .alert("Outstanding Amount Alert", isPresented: Binding(
            get: { model.alertText != nil },
            set: { if !$0 { model.alertText = nil } }
        )) {
            Button("OK", role: .cancel) { model.alertText = nil }
        } message: {
            Text(model.alertText ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("BPC E-bill Reconciler")
                .font(.menlo(size: 25, weight: .bold))
                .foregroundStyle(Color(red: 0.1, green: 0.15, blue: 0.22))
            Spacer(minLength: 10)
            Text(Date.now.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()))
                .font(.menlo(size: 14, weight: .medium))
                .foregroundStyle(Color(red: 0.37, green: 0.41, blue: 0.49))
                .padding(.trailing, 10)
            CandyButton("Generate Statement", icon: "doc.text", action: model.generateStatement)
            CandyButton("Check Outstanding Amount", icon: "magnifyingglass", action: model.checkOutstanding)
            CandyButton("+ Generate", action: model.generate)
            CandyButton("▶ Run Tally", action: model.runTally)
        }
        .frame(height: 52)
    }

    private var leftColumn: some View {
        VStack(spacing: 12) {
            outputFolderCard
                .fixedSize(horizontal: false, vertical: true)
            recentFilesCard
                .frame(maxHeight: .infinity)
            resultCard
                .frame(height: 180)
        }
    }

    private var outputFolderCard: some View {
        GlassCard {
            HStack(spacing: 10) {
                Text("Output folder")
                    .font(.menlo(size: 13, weight: .bold))
                    .foregroundStyle(Color.ink)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(Color.white.opacity(0.54))
                TextField("Choose an output folder", text: Binding(
                    get: { model.outputFolder.path },
                    set: { _ in }
                ))
                .font(.menlo(size: 13, weight: .medium))
                .textFieldStyle(.plain)
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .background(Color.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.slate.opacity(0.22), lineWidth: 1))
                .lineLimit(1)
                .truncationMode(.middle)
                CandyButton("Browse…") { ui.isFolderImporterPresented = true }
                CandyButton("Open", action: model.openOutputFolder)
                Text("Last tally: \(model.lastTally.map { $0 ? "CONFIRMED" : "DOES NOT MATCH" } ?? "not run yet")")
                    .font(.menlo(size: 12, weight: .medium))
                    .foregroundStyle(model.lastTally == true ? Color.greenInk : Color.mutedInk)
                    .lineLimit(1)
                    .frame(minWidth: 160)
            }
        }
        .frame(height: 64)
    }

    private var recentFilesCard: some View {
        GlassCard {
            VStack(spacing: 10) {
                HStack {
                    Text("Recent Files")
                        .font(.menlo(size: 17, weight: .bold))
                        .foregroundStyle(Color.ink)
                    Spacer()
                    TextField("Search…", text: $model.search)
                        .font(.menlo(size: 13))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(width: 190)
                        .background(Color.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.slate.opacity(0.2), lineWidth: 1))
                }
                HStack(alignment: .top, spacing: 12) {
                    fileTable(title: model.invoiceCountText, kind: .invoice)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    fileTable(title: model.receiptCountText, kind: .receipt)
                        .frame(width: 360)
                        .frame(maxHeight: .infinity)
                }
            }
        }
    }

    private func fileTable(title: String, kind: FileKind) -> some View {
        VStack(spacing: 7) {
            HStack {
                Text(title)
                    .font(.menlo(size: 14, weight: .bold))
                    .foregroundStyle(Color.ink)
                Spacer()
            }
            if kind == .invoice {
                Table(model.visibleInvoiceRows, selection: $model.selectedInvoiceIDs) {
                    TableColumn("Station") { row in tableText(row.station, highlight: hasOutstanding(row)) }
                        .width(min: 125, ideal: 170)
                    TableColumn("Consumer No") { row in tableText(row.consumerNo, highlight: hasOutstanding(row)) }
                        .width(min: 92, ideal: 110)
                    TableColumn("Amount") { row in tableText(amount(row.total), highlight: hasOutstanding(row)) }
                        .width(min: 80, ideal: 100)
                    TableColumn("Cycle") { row in tableText(row.cycle, highlight: hasOutstanding(row)) }
                        .width(min: 52, ideal: 64)
                    TableColumn("Outstanding") { row in tableText(amount(row.outstanding), highlight: hasOutstanding(row)) }
                        .width(min: 95, ideal: 112)
                    TableColumn("Other Outstanding") { row in tableText(amount(row.otherOutstanding), highlight: hasOutstanding(row)) }
                        .width(min: 115, ideal: 135)
                }
                .font(.menlo(size: 12))
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.slate.opacity(0.2), lineWidth: 1))
                fileActions(kind: .invoice)
            } else {
                Table(model.visibleReceipts, selection: $model.selectedReceiptIDs) {
                    TableColumn("Station") { item in tableText(item.station.isEmpty ? "(unknown)" : item.station) }
                        .width(min: 120, ideal: 160)
                    TableColumn("Consumer No") { item in tableText(item.consumerNo ?? "?") }
                        .width(min: 92, ideal: 110)
                    TableColumn("Amount") { item in tableText(amount(item.amount)) }
                        .width(min: 80, ideal: 100)
                    TableColumn("Cycle") { item in tableText(item.cycle) }
                        .width(min: 52, ideal: 64)
                }
                .font(.menlo(size: 12))
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.slate.opacity(0.2), lineWidth: 1))
                fileActions(kind: .receipt)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            acceptDrop(providers, as: kind)
        }
    }

    private func fileActions(kind: FileKind) -> some View {
        HStack(spacing: 8) {
            CandyButton("+ Add") {
                model.importKind = kind
                ui.isImporterPresented = true
            }
            CandyButton("Remove") {
                if kind == .invoice { model.removeSelectedInvoices() }
                else { model.removeSelectedReceipts() }
            }
            CandyButton(kind == .invoice ? "Clear Invoices" : "Clear Receipts") {
                if kind == .invoice {
                    model.clearInvoices()
                    model.selectedInvoiceIDs.removeAll()
                } else {
                    model.clearReceipts()
                    model.selectedReceiptIDs.removeAll()
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var resultCard: some View {
        GlassCard {
            VStack(spacing: 8) {
                HStack {
                    Text("Progress / Result")
                        .font(.menlo(size: 15, weight: .bold))
                        .foregroundStyle(Color.ink)
                    Spacer()
                    Text(model.busy ? "Working…" : "\(model.status)  ·  Vision OCR ready")
                        .font(.menlo(size: 12, weight: .medium))
                        .foregroundStyle(model.lastTally == false ? Color.red : Color.mutedInk)
                        .lineLimit(1)
                    CandyButton("Export Logs", action: model.exportLogs)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.logs.isEmpty ? "Ready.\nPDFKit and Vision OCR are ready." : model.logs)
                            .font(.menlo(size: 12, weight: .medium))
                            .foregroundStyle(Color.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id("log-end")
                    }
                    .onChange(of: model.logs) { _, _ in proxy.scrollTo("log-end", anchor: .bottom) }
                    .padding(10)
                    .background(Color.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.slate.opacity(0.2), lineWidth: 1))
                }
            }
        }
    }

    private var stationsCard: some View {
        GlassCard {
            VStack(spacing: 10) {
                HStack {
                    Text("Stations")
                        .font(.menlo(size: 17, weight: .bold))
                        .foregroundStyle(Color.ink)
                    Spacer()
                    Text("\(model.stationRows.count) stations")
                        .font(.menlo(size: 12))
                        .foregroundStyle(Color.mutedInk)
                }
                Table(model.stationRows, selection: $model.selectedStationIDs) {
                    TableColumn("Station", value: \.station)
                        .width(min: 160, ideal: 205)
                    TableColumn("Consumer No", value: \.consumerNo)
                        .width(min: 105, ideal: 125)
                }
                .font(.menlo(size: 12))
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .scrollContentBackground(.hidden)
                .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.slate.opacity(0.2), lineWidth: 1))
                HStack(spacing: 8) {
                    CandyButton("+ Add Station") { model.showAddStation = true }
                    CandyButton("Remove", action: model.removeStations)
                }
                HStack(spacing: 8) {
                    CandyButton("Import", action: model.importStations)
                    CandyButton("Export", action: model.exportStations)
                }
            }
        }
    }

    private func tableText(_ value: String, highlight: Bool = false) -> some View {
        Text(value)
            .font(.menlo(size: 12, weight: .medium))
            .foregroundStyle(Color.ink)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
            .background(highlight ? Color(red: 1, green: 0.91, blue: 0.89) : .clear)
    }

    private func amount(_ value: Double?) -> String {
        value?.moneyString ?? "-"
    }

    private func hasOutstanding(_ row: InvoiceRow) -> Bool {
        (row.outstanding ?? 0) >= 0.005 || (row.otherOutstanding ?? 0) >= 0.005
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls): model.addFiles(urls, kind: model.importKind)
        case .failure(let error): model.errorText = error.localizedDescription
        }
    }

    private func handleFolderImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls): if let url = urls.first { model.chooseOutputFolder(url) }
        case .failure(let error): model.errorText = error.localizedDescription
        }
    }

    private func acceptDrop(_ providers: [NSItemProvider], as kind: FileKind) -> Bool {
        let providers = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !providers.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { item, _ in
                if let url = item {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
            guard !pdfs.isEmpty else { self.model.errorText = "Drop PDF files onto the window."; return }
            self.model.addFiles(pdfs, kind: kind)
        }
        return true
    }
}

private struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(16)
            .background(Color.white.opacity(0.58), in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.88), lineWidth: 1))
            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 3)
    }
}

private struct CandyButton: View {
    var title: String
    var icon: String?
    var action: () -> Void
    @StateObject private var state = CandyButtonState()

    init(_ title: String, icon: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                Text(title)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            .font(.menlo(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 15)
            .frame(minHeight: 42)
            .background {
                ZStack {
                    Capsule()
                        .fill(LinearGradient(colors: [
                            Color(red: 0.001, green: 0.018, blue: 0.008),
                            Color(red: 0.003, green: 0.075, blue: 0.027),
                            Color(red: 0.008, green: 0.14, blue: 0.048),
                            Color(red: 0.003, green: 0.055, blue: 0.020),
                            Color(red: 0.001, green: 0.025, blue: 0.010)
                        ], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Capsule()
                        .fill(LinearGradient(colors: [
                            Color(red: 0.78, green: 1, blue: 0.84).opacity(state.isHovered ? 0.64 : 0.54),
                            Color(red: 0.24, green: 0.82, blue: 0.40).opacity(0.22),
                            .clear
                        ], startPoint: .top, endPoint: .bottom))
                        .blendMode(.screen)
                    Capsule()
                        .fill(LinearGradient(colors: [
                            Color.white.opacity(state.isHovered ? 0.96 : 0.88),
                            Color(red: 0.90, green: 1, blue: 0.93).opacity(0.62),
                            Color.white.opacity(0.22),
                            .clear
                        ], startPoint: .top, endPoint: .bottom))
                        .frame(height: 18)
                        .padding(.horizontal, 3)
                        .padding(.top, 2)
                        .frame(maxHeight: .infinity, alignment: .top)
                    Capsule()
                        .fill(LinearGradient(colors: [
                            Color.white.opacity(0.78),
                            Color(red: 0.70, green: 1, blue: 0.78).opacity(0.70),
                            .clear
                        ], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 1)
                        .padding(.horizontal, 17)
                        .padding(.top, 2)
                        .frame(maxHeight: .infinity, alignment: .top)
                    Capsule()
                        .fill(LinearGradient(colors: [
                            .clear,
                            Color(red: 0.18, green: 0.82, blue: 0.34).opacity(0.44),
                            Color(red: 0.08, green: 0.42, blue: 0.18).opacity(0.12)
                        ], startPoint: .top, endPoint: .bottom))
                        .frame(height: 12)
                        .padding(.horizontal, 5)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.92), lineWidth: 1)
                        .padding(0.8)
                    Capsule()
                        .strokeBorder(Color(red: 0.006, green: 0.045, blue: 0.018).opacity(0.98), lineWidth: 1.5)
                        .padding(2.5)
                    HStack(spacing: 0) {
                        Circle().fill(Color.white.opacity(0.92)).frame(width: 3, height: 3)
                        Circle().fill(Color.white.opacity(0.56)).frame(width: 2, height: 2).padding(.leading, 2)
                        Spacer()
                        Circle().fill(Color.white.opacity(0.14)).frame(width: 5, height: 5)
                            .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 0.7))
                        Spacer()
                        Circle().fill(Color.white.opacity(0.10)).frame(width: 6, height: 6)
                            .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 0.7))
                    }
                    .padding(.horizontal, 13)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 7)
                }
                .clipShape(Capsule())
            }
            .overlay(Capsule().stroke(Color.white.opacity(0.94), lineWidth: 1))
            .shadow(color: Color(red: 0.002, green: 0.08, blue: 0.025).opacity(state.isHovered ? 0.86 : 0.72), radius: state.isHovered ? 11 : 7, x: 0, y: state.isHovered ? 5 : 3)
            .shadow(color: Color(red: 0.08, green: 0.58, blue: 0.20).opacity(state.isHovered ? 0.30 : 0.14), radius: state.isHovered ? 7 : 3, x: 0, y: 0)
            .scaleEffect(state.isHovered ? 1.025 : 1)
        }
        .buttonStyle(.plain)
        .onHover { state.isHovered = $0 }
        .animation(.easeOut(duration: 0.16), value: state.isHovered)
    }
}

@MainActor
private final class CandyButtonState: ObservableObject {
    @Published var isHovered = false
}

@MainActor
private final class DashboardUIState: ObservableObject {
    @Published var isImporterPresented = false
    @Published var isFolderImporterPresented = false
}

@MainActor
private final class AddStationForm: ObservableObject {
    @Published var consumerNo = ""
    @Published var stationName = ""
}

private struct AddStationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = AddStationForm()
    var onSave: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Station")
                .font(.menlo(size: 20, weight: .bold))
            TextField("Consumer No. (digits)", text: $form.consumerNo)
                .font(.menlo(size: 13))
                .textFieldStyle(.roundedBorder)
            TextField("Station name", text: $form.stationName)
                .font(.menlo(size: 13))
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .font(.menlo(size: 13))
                Button("Save") {
                    onSave(form.consumerNo, form.stationName)
                    dismiss()
                }
                .font(.menlo(size: 13, weight: .bold))
                .keyboardShortcut(.defaultAction)
                .disabled(form.consumerNo.filter(\.isNumber).isEmpty || form.stationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 360)
    }
}

private struct WindowGlassConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { configure(view.window) }
    }

    private func configure(_ window: NSWindow?) {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = NSColor.white.withAlphaComponent(0.28)
        window.titlebarAppearsTransparent = true
    }
}

private extension Color {
    static let ink = Color(red: 0.10, green: 0.15, blue: 0.22)
    static let mutedInk = Color(red: 0.38, green: 0.42, blue: 0.49)
    static let slate = Color(red: 0.35, green: 0.40, blue: 0.48)
    static let greenInk = Color(red: 0.06, green: 0.43, blue: 0.22)
}

private extension Font {
    static func menlo(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(weight == .bold ? "Menlo-Bold" : "Menlo-Regular", size: size)
    }
}

private extension Double {
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
