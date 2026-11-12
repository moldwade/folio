#if os(macOS)
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Text stamps

/// Ready-made rubber stamps of words, as Foxit's: the word in a frame, in the stamp's colour, with today's date under it.
/// Each goes in as a text box with a border, so every app shows it, and it stays selected to drag into place.
enum TextStamp: String, CaseIterable, Identifiable {
    case paid, approved, received, copy, confidential, draft, rejected

    var id: Self { self }

    /// The stamp's words, in Bosnian: the language of the papers they go on, whatever Folio's own language.
    var words: String {
        switch self {
        case .paid: "PLAĆENO"
        case .approved: "ODOBRENO"
        case .received: "PRIMLJENO"
        case .copy: "KOPIJA"
        case .confidential: "POVJERLJIVO"
        case .draft: "NACRT"
        case .rejected: "ODBIJENO"
        }
    }

    var color: NSColor {
        switch self {
        case .paid, .approved, .received: NSColor(red: 0.05, green: 0.5, blue: 0.2, alpha: 1)
        case .copy, .draft: NSColor(red: 0.1, green: 0.3, blue: 0.75, alpha: 1)
        case .confidential, .rejected: NSColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        }
    }

    /// The stamp, centred on `point`.
    func annotation(at point: CGPoint, dated: Bool = true) -> PDFAnnotation {
        let font = NSFont.boldSystemFont(ofSize: 20)
        let width = max(words.size(withAttributes: [.font: font]).width + 30, 130), height: CGFloat = dated ? 56 : 36
        let stamp = TextStampAnnotation(bounds: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height),
                                        forType: .stamp, withProperties: nil)
        stamp.words = words
        stamp.date = dated ? Date.now.formatted(date: .numeric, time: .omitted) : nil
        stamp.color = color
        stamp.contents = [words, stamp.date].compactMap { $0 }.joined(separator: " ")
        return stamp
    }
}

/// A word stamp as it's drawn: a double frame with rounded corners, the word in bold capitals, and the date under it, all in
/// the stamp's colour and a little see-through, like ink. PDFKit writes this drawing into the file as the stamp's
/// appearance, so other apps show it the same.
final class TextStampAnnotation: PDFAnnotation {
    var words = ""
    var date: String?

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let ink = color.withAlphaComponent(0.85)
        context.saveGState()
        let frame = bounds.insetBy(dx: 2, dy: 2)
        context.setStrokeColor(ink.cgColor)
        context.setLineWidth(2.5)
        context.addPath(CGPath(roundedRect: frame, cornerWidth: 6, cornerHeight: 6, transform: nil))
        context.strokePath()
        context.setLineWidth(0.8)
        context.addPath(CGPath(roundedRect: frame.insetBy(dx: 3.5, dy: 3.5), cornerWidth: 4, cornerHeight: 4, transform: nil))
        context.strokePath()
        let big = NSFont.boldSystemFont(ofSize: 20), small = NSFont.boldSystemFont(ofSize: 10)
        let mid = CGPoint(x: bounds.midX, y: bounds.midY)
        PageMarks.drawText(words, in: context, center: CGPoint(x: mid.x, y: date == nil ? mid.y : mid.y + 7),
                           attributes: [.font: big, .foregroundColor: ink])
        if let date {
            PageMarks.drawText(date, in: context, center: CGPoint(x: mid.x, y: mid.y - 14), attributes: [.font: small, .foregroundColor: ink])
        }
        context.restoreGState()
    }

    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! TextStampAnnotation
        copy.words = words
        copy.date = date
        return copy
    }
}

extension Viewer {
    /// Puts the stamp in the middle of the page in view, selected, ready to drag.
    func place(_ stamp: TextStamp) {
        settle()
        guard let page = doc.pdf.page(at: pageIndex) else { return }
        let box = page.bounds(for: .cropBox)
        let mark = stamp.annotation(at: CGPoint(x: box.midX, y: box.midY))
        doc.add(mark, to: page, name: "Stamp")
        tool = .select
        canvas.selected = mark
    }
}

// MARK: - Pictures

extension Viewer {
    /// Draws the marks into the pages for good, saying so, or that it couldn't.
    func flatten() {
        settle()
        message = doc.flatten() ? String(localized: "Marks are now part of the pages") : String(localized: "Couldn't change these pages")
    }

    /// Asks for a picture and puts it in the middle of the page in view, at most half the page across, selected to drag and
    /// size. It's drawn into the file, so other apps show it.
    func addPicture() {
        settle()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url),
              let picture = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let page = doc.pdf.page(at: pageIndex) else { return }
        let box = page.bounds(for: .cropBox)
        let scale = min(box.width / 2 / CGFloat(picture.width), box.height / 2 / CGFloat(picture.height), 72.0 / 150)
        let size = CGSize(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
        let mark = SignatureAnnotation(bounds: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height),
                                       forType: .stamp, withProperties: nil)
        mark.picture = picture
        doc.add(mark, to: page, name: "Add Picture")
        tool = .select
        canvas.selected = mark
    }
}

// MARK: - Export

/// Saving the document as something else: a Word file or plain text of its words, or a picture of each page.
enum Export {
    enum Kind { case word, text, images }

    /// The document's words, page after page, a page break between them.
    /// The document's words, page after page, laid out as on the page: each line indented to where it starts, the gaps
    /// between lines kept, and the pieces of a line that sit apart, a table's columns, at tab stops where they sit.
    static func words(of pdf: PDFDocument) -> NSAttributedString {
        var pictures: [NSImage] = []
        return words(of: pdf, pictures: &pictures)
    }

    /// The same, with each picture as a placeholder, `Docx.marker(n)`, and the pictures in `pictures`.
    static func words(of pdf: PDFDocument, pictures: inout [NSImage]) -> NSAttributedString {
        // From a fresh copy: PDFKit gives the lines of the page in view no bounds.
        let source = pdf.dataRepresentation().flatMap(PDFDocument.init(data:)) ?? pdf
        let all = NSMutableAttributedString()
        for i in 0..<source.pageCount {
            guard let page = source.page(at: i) else { continue }
            if i > 0 { all.append(NSAttributedString(string: "\u{000C}")) }
            all.append(laidOut(page, pictures: &pictures))
        }
        // A PDF's fonts are often embedded subsets Word doesn't have, which it shows as Times: Arial instead, at each run's
        // size, bold and italic kept.
        all.enumerateAttribute(.font, in: NSRange(location: 0, length: all.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            let name = font.fontName.lowercased(), traits = font.fontDescriptor.symbolicTraits
            let bold = traits.contains(.bold) || name.contains("bold") || name.contains("black") || name.contains("heavy")
            let italic = traits.contains(.italic) || name.contains("italic") || name.contains("oblique")
            var arial = NSFont(name: "Arial", size: font.pointSize) ?? .systemFont(ofSize: font.pointSize)
            if bold { arial = NSFontManager.shared.convert(arial, toHaveTrait: .boldFontMask) }
            if italic { arial = NSFontManager.shared.convert(arial, toHaveTrait: .italicFontMask) }
            all.addAttribute(.font, value: arial, range: range)
        }
        return all
    }

    /// One page's lines as paragraphs placed as they are on it, or its plain words when PDFKit finds no lines.
    static func laidOut(_ page: PDFPage, pictures found: inout [NSImage]) -> NSAttributedString {
        let box = page.bounds(for: .cropBox)
        let pieces = (page.selection(for: box)?.selectionsByLine() ?? []).compactMap { line -> (CGRect, NSAttributedString)? in
            let bounds = line.bounds(for: page)
            guard bounds.width.isFinite, bounds.width > 0, let text = line.attributedString,
                  !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (bounds, text)
        }
        // The pictures go in too, each as a picture of that part of the page, in its place among the lines.
        var pictures: [(CGRect, NSAttributedString)] = []
        for rect in page.rotation == 0 ? PagePictures.rects(on: page) : [] {
            guard let image = PagePictures.picture(of: page, in: rect) else { continue }
            pictures.append((rect, NSAttributedString(string: Docx.marker(found.count))))
            found.append(image)
        }
        guard !pieces.isEmpty || !pictures.isEmpty else { return page.attributedString ?? NSAttributedString(string: page.string ?? "") }
        // Pieces on one baseline make one row, left to right; a picture makes a row of its own.
        var rows: [[(CGRect, NSAttributedString)]] = []
        for piece in pieces.sorted(by: { $0.0.midY > $1.0.midY }) {
            if let last = rows.last?.first, abs(last.0.midY - piece.0.midY) < min(last.0.height, piece.0.height) / 2 {
                rows[rows.count - 1].append(piece)
            } else {
                rows.append([piece])
            }
        }
        for picture in pictures {
            let at = rows.firstIndex { ($0.first?.0.midY ?? 0) < picture.0.maxY } ?? rows.count
            rows.insert([picture], at: at)
        }
        let left = (pieces + pictures).map(\.0.minX).min() ?? box.minX
        // Word's page has 6.5 inches between its margins: wider lines are drawn in closer, keeping their proportions, with room
        // to spare for fonts a little wider than the PDF's.
        let right = (pieces + pictures).map(\.0.maxX).max() ?? box.maxX
        let fit = min(1, 430 / max(right - left, 1))
        let out = NSMutableAttributedString()
        var above = box.maxY
        for row in rows {
            let row = row.sorted { $0.0.minX < $1.0.minX }
            let top = row.map(\.0.maxY).max()!, bottom = row.map(\.0.minY).min()!
            let style = NSMutableParagraphStyle()
            style.firstLineHeadIndent = max(row[0].0.minX - left, 0) * fit
            style.headIndent = style.firstLineHeadIndent
            style.paragraphSpacingBefore = min(max(above - top - 2, 0), 200)
            style.tabStops = row.dropFirst().map { NSTextTab(textAlignment: .left, location: max($0.0.minX - left, 0) * fit) }
            let line = NSMutableAttributedString()
            for (i, piece) in row.enumerated() {
                if i > 0 { line.append(NSAttributedString(string: "\t")) }
                let text = NSMutableAttributedString(attributedString: piece.1)
                while text.string.hasSuffix("\n") || text.string.hasSuffix(" ") { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
                line.append(text)
            }
            line.append(NSAttributedString(string: "\n"))
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            out.append(line)
            above = bottom
        }
        return out
    }

    @MainActor static func run(_ kind: Kind, viewer: Viewer, name: String) {
        viewer.settle()
        let pdf = viewer.doc.pdf
        guard !pdf.isLocked else { return }
        if kind == .images {
            let panel = NSOpenPanel()
            (panel.canChooseDirectories, panel.canChooseFiles, panel.canCreateDirectories) = (true, false, true)
            panel.prompt = String(localized: "Choose Folder…")
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            viewer.busy = String(localized: "Saving pictures…")
            Task { @MainActor in
                var saved = 0
                for i in 0..<pdf.pageCount {
                    guard let page = pdf.page(at: i), let data = picture(of: page, dpi: 200) else { continue }
                    let file = folder.appendingPathComponent("\(name) \(i + 1).png")
                    if (try? data.write(to: file, options: .withoutOverwriting)) != nil { saved += 1 }
                    await Task.yield()
                }
                viewer.busy = nil
                viewer.message = String(localized: "Saved \(saved) pictures in \(folder.lastPathComponent)")
            }
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [kind == .word ? UTType(filenameExtension: "docx")! : .plainText]
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var pictures: [NSImage] = []
            let text = words(of: pdf, pictures: &pictures)
            if kind == .word {
                let data = try text.data(from: NSRange(location: 0, length: text.length),
                                         documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
                try Docx.withPictures(data, pictures).write(to: url)
            } else {
                try text.string.replacingOccurrences(of: "\u{000C}", with: "\n\n").write(to: url, atomically: true, encoding: .utf8)
            }
            viewer.message = String(localized: "Saved \(url.lastPathComponent)")
        } catch {
            NSApp.presentError(error)
        }
    }

    /// The page, marks and all, as a PNG at `dpi`.
    static func picture(of page: PDFPage, dpi: CGFloat) -> Data? {
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let size = CGSize(width: (turned ? box.height : box.width) * dpi / 72, height: (turned ? box.width : box.height) * dpi / 72)
        let image = page.thumbnail(of: size, for: .cropBox)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Compare

/// Two PDFs side by side in words: for each page, the words only the first has and the words only the second has. Words,
/// not lines, and in any order: PDFKit can read the same page's lines in another order once it's redrawn, as a watermark
/// or a header does, and a changed figure should show as itself, not as its whole line.
enum Compare {
    struct PageDifference: Identifiable {
        let id: Int
        let removed: [String], added: [String]
    }

    static func words(_ page: PDFPage?) -> [String] {
        (page?.string ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// The words of `a` that `b` lacks, as many times as it lacks them, in `a`'s order.
    static func missing(_ a: [String], from b: [String]) -> [String] {
        var left = Dictionary(b.map { ($0, 1) }, uniquingKeysWith: +)
        return a.filter { word in
            if let n = left[word], n > 0 { left[word] = n - 1; return false }
            return true
        }
    }

    static func differences(_ a: PDFDocument, _ b: PDFDocument) -> [PageDifference] {
        (0..<max(a.pageCount, b.pageCount)).compactMap { i in
            let old = words(i < a.pageCount ? a.page(at: i) : nil), new = words(i < b.pageCount ? b.page(at: i) : nil)
            let removed = missing(old, from: new), added = missing(new, from: old)
            return removed.isEmpty && added.isEmpty ? nil : PageDifference(id: i, removed: removed, added: added)
        }
    }
}

struct CompareSheet: View {
    let viewer: Viewer
    let name: String
    @State private var other: URL?
    @State private var result: [Compare.PageDifference]?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compare Documents").font(.title2.bold())
            HStack {
                Text(name).lineLimit(1)
                Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                Text(other?.lastPathComponent ?? "—").lineLimit(1)
                Spacer()
                Button("Choose a PDF…", action: choose)
            }
            if let result {
                if result.isEmpty {
                    ContentUnavailableView("No differences in the text", systemImage: "checkmark.circle")
                } else {
                    List(result) { page in
                        Section(String(localized: "Page \(page.id + 1)")) {
                            if !page.removed.isEmpty { Text("− " + page.removed.joined(separator: " ")).foregroundStyle(.red).textSelection(.enabled) }
                            if !page.added.isEmpty { Text("+ " + page.added.joined(separator: " ")).foregroundStyle(.green).textSelection(.enabled) }
                        }
                    }
                    .frame(minHeight: 320)
                }
            } else {
                Text("Choose the other version to see which words changed, page by page.").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url, let pdf = PDFDocument(url: url), !pdf.isLocked else { return }
        other = url
        result = Compare.differences(viewer.doc.pdf, pdf)
    }
}

// MARK: - Batch

/// One action on many files at once, each saved beside itself under a new name, as Foxit's Action Wizard does.
enum Batch {
    enum Action: String, CaseIterable, Identifiable {
        case reduce, pageNumbers, watermark, recognize
        var id: Self { self }
        var name: LocalizedStringKey {
            switch self {
            case .reduce: "Reduce File Size"
            case .pageNumbers: "Page Numbers"
            case .watermark: "Watermark"
            case .recognize: "Recognize Text"
            }
        }
    }

    /// Does `action` to each file, saving each beside its original as "<name> (Folio).pdf", never over a file. Files with a
    /// password or restrictions are left out. Returns how many were saved.
    @MainActor static func run(_ action: Action, on files: [URL], watermark: PageMarks.Watermark = .init(), progress: (Int, URL) -> Void = { _, _ in }) async -> Int {
        var saved = 0
        for (i, url) in files.enumerated() {
            progress(i, url)
            guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.hasFullRights else { continue }
            let doc = FolioDocument(pdf: pdf)
            switch action {
            case .reduce: _ = await doc.reduceFileSize()
            case .pageNumbers: _ = doc.addHeaderFooter(.pageNumbers, file: url.deletingPathExtension().lastPathComponent)
            case .watermark: _ = doc.addWatermark(watermark, to: doc.pages)
            case .recognize: _ = await doc.recognizeText { _, _ in }
            }
            let out = url.deletingLastPathComponent().appendingPathComponent(url.deletingPathExtension().lastPathComponent + " (Folio).pdf")
            if !FileManager.default.fileExists(atPath: out.path), doc.pdf.write(to: out) { saved += 1 }
        }
        return saved
    }
}

struct BatchSheet: View {
    @State private var files: [URL] = []
    @State private var action = Batch.Action.reduce
    @State private var watermark = PageMarks.Watermark()
    @State private var progress: String?
    @State private var done: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Batch Process").font(.title2.bold())
            HStack {
                Text(files.isEmpty ? String(localized: "No files chosen") : String(localized: "\(files.count) files chosen"))
                Spacer()
                Button("Choose Files…", action: choose)
            }
            Picker("Action", selection: $action) {
                ForEach(Batch.Action.allCases) { Text($0.name).tag($0) }
            }
            if action == .watermark { TextField("Text", text: $watermark.text) }
            Text("Each file is saved beside the original, with “ (Folio)” after its name. The originals stay as they are.")
                .font(.caption).foregroundStyle(.secondary)
            if let progress { ProgressView(progress) }
            if let done { Label(done, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Start") { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(files.isEmpty || progress != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK { files = panel.urls; done = nil }
    }

    @MainActor private func run() async {
        let saved = await Batch.run(action, on: files, watermark: watermark) { i, url in
            progress = String(localized: "\(i + 1) of \(files.count): \(url.lastPathComponent)")
        }
        progress = nil
        done = String(localized: "Saved \(saved) of \(files.count) files")
    }
}
#endif

#if os(macOS)
// MARK: - Pictures on a page

/// Where a page's pictures are drawn, read from its content: each image's unit square through the transformation in force
/// when it's drawn. Pictures inside forms count too.
enum PagePictures {
    private final class State {
        var stack: [CGAffineTransform] = [.identity]
        var rects: [CGRect] = []
        var resources: [CGPDFDictionaryRef] = []
        var streams: [CGPDFContentStreamRef] = []
    }

    static func rects(on page: PDFPage) -> [CGRect] {
        guard let ref = page.pageRef, let pageDictionary = ref.dictionary else { return [] }
        var resources: CGPDFDictionaryRef?
        CGPDFDictionaryGetDictionary(pageDictionary, "Resources", &resources)
        let state = State()
        if let resources { state.resources = [resources] }
        scan(CGPDFContentStreamCreateWithPage(ref), state)
        let box = page.bounds(for: .cropBox)
        return state.rects.map { $0.intersection(box) }.filter { $0.width > 8 && $0.height > 8 }
    }

    private static func scan(_ stream: CGPDFContentStreamRef, _ state: State) {
        state.streams.append(stream)
        defer { state.streams.removeLast() }
        let table = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let s = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            s.stack.append(s.stack.last!)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let s = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            if s.stack.count > 1 { s.stack.removeLast() }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let s = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            var v = [CGPDFReal](repeating: 0, count: 6)
            for i in (0..<6).reversed() { guard CGPDFScannerPopNumber(scanner, &v[i]) else { return } }
            let m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            s.stack[s.stack.count - 1] = m.concatenating(s.stack.last!)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            let s = Unmanaged<State>.fromOpaque(info!).takeUnretainedValue()
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name, let resources = s.resources.last else { return }
            var xobjects: CGPDFDictionaryRef?, object: CGPDFStreamRef?
            guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects,
                  CGPDFDictionaryGetStream(xobjects, name, &object), let object, let dictionary = CGPDFStreamGetDictionary(object) else { return }
            var subtype: UnsafePointer<CChar>?
            CGPDFDictionaryGetName(dictionary, "Subtype", &subtype)
            guard let subtype else { return }
            if strcmp(subtype, "Image") == 0 {
                s.rects.append(CGRect(x: 0, y: 0, width: 1, height: 1).applying(s.stack.last!))
            } else if strcmp(subtype, "Form") == 0, s.resources.count < 8 {
                // A form draws its own content, through its matrix, with its own resources.
                var matrix: CGPDFArrayRef?
                var m = CGAffineTransform.identity
                if CGPDFDictionaryGetArray(dictionary, "Matrix", &matrix), let matrix, CGPDFArrayGetCount(matrix) == 6 {
                    var v = [CGPDFReal](repeating: 0, count: 6)
                    for i in 0..<6 { CGPDFArrayGetNumber(matrix, i, &v[i]) }
                    m = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                }
                var inner: CGPDFDictionaryRef?
                CGPDFDictionaryGetDictionary(dictionary, "Resources", &inner)
                s.stack.append(m.concatenating(s.stack.last!))
                s.resources.append(inner ?? resources)
                guard let parent = s.streams.last else { return }
                let content = CGPDFContentStreamCreateWithStream(object, inner ?? resources, parent)
                PagePictures.scan(content, s)
                s.resources.removeLast()
                s.stack.removeLast()
            }
        }
        let scanner = CGPDFScannerCreate(stream, table, Unmanaged.passUnretained(state).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFOperatorTableRelease(table)
    }

    /// The part of the page under `rect`, as it shows, at `dpi`.
    static func picture(of page: PDFPage, in rect: CGRect, dpi: CGFloat = 150) -> NSImage? {
        let box = page.bounds(for: .cropBox), scale = dpi / 72
        let whole = page.thumbnail(of: CGSize(width: box.width * scale, height: box.height * scale), for: .cropBox)
        guard let cg = whole.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let px = CGFloat(cg.width) / box.width
        let crop = CGRect(x: (rect.minX - box.minX) * px, y: (box.maxY - rect.maxY) * px, width: rect.width * px, height: rect.height * px)
        guard let part = cg.cropping(to: crop.integral) else { return nil }
        return NSImage(cgImage: part, size: rect.size)
    }
}
#endif

#if os(macOS)
// MARK: - Pictures in Word files

/// Puts pictures into a Word file macOS wrote: its writer leaves pictures out, so the words carry a marker where each goes,
/// and this swaps each marker for the picture, added to the file's media.
enum Docx {
    static func marker(_ n: Int) -> String { "FOLIOPICTURE\(n)X" }

    static func withPictures(_ docx: Data, _ pictures: [NSImage]) throws -> Data {
        guard !pictures.isEmpty else { return docx }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("folio-docx-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let unpacked = folder.appendingPathComponent("x"), file = folder.appendingPathComponent("in.docx")
        try FileManager.default.createDirectory(at: unpacked.appendingPathComponent("word/media"), withIntermediateDirectories: true)
        try docx.write(to: file)
        try run("/usr/bin/unzip", ["-q", "-o", file.path, "-d", unpacked.path])
        let documentURL = unpacked.appendingPathComponent("word/document.xml")
        let relsURL = unpacked.appendingPathComponent("word/_rels/document.xml.rels")
        let typesURL = unpacked.appendingPathComponent("[Content_Types].xml")
        var document = try String(contentsOf: documentURL, encoding: .utf8)
        var rels = (try? String(contentsOf: relsURL, encoding: .utf8))
            ?? #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"></Relationships>"#
        var types = try String(contentsOf: typesURL, encoding: .utf8)
        if !types.contains(#"Extension="png""#) {
            types = types.replacingOccurrences(of: "<Types ", with: "<Types ").replacingOccurrences(of: "</Types>", with: #"<Default Extension="png" ContentType="image/png"/></Types>"#)
        }
        for (ns, uri) in [("r", "http://schemas.openxmlformats.org/officeDocument/2006/relationships"),
                          ("wp", "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing")]
        where !document.contains("xmlns:\(ns)=") {
            document = document.replacingOccurrences(of: "<w:document ", with: "<w:document xmlns:\(ns)=\"\(uri)\" ")
        }
        for (n, picture) in pictures.enumerated() {
            guard let tiff = picture.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: unpacked.appendingPathComponent("word/media/folio\(n).png"))
            let id = "rIdFolio\(n)"
            rels = rels.replacingOccurrences(of: "</Relationships>", with: #"<Relationship Id="\#(id)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/folio\#(n).png"/></Relationships>"#)
            let cx = Int(picture.size.width * 12700), cy = Int(picture.size.height * 12700)
            let drawing = #"</w:t></w:r><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\#(cx)" cy="\#(cy)"/><wp:docPr id="\#(1000 + n)" name="Picture \#(n + 1)"/><a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="\#(1000 + n)" name="folio\#(n).png"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\#(id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\#(cx)" cy="\#(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r><w:r><w:t xml:space="preserve">"#
            document = document.replacingOccurrences(of: marker(n), with: drawing)
        }
        try document.write(to: documentURL, atomically: true, encoding: .utf8)
        try rels.write(to: relsURL, atomically: true, encoding: .utf8)
        try types.write(to: typesURL, atomically: true, encoding: .utf8)
        let out = folder.appendingPathComponent("out.docx")
        try run("/usr/bin/zip", ["-q", "-X", "-r", out.path, "."], in: unpacked)
        return try Data(contentsOf: out)
    }

    private static func run(_ tool: String, _ arguments: [String], in directory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
#endif
