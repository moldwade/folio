#if os(macOS)
import PDFKit
import SwiftUI

/// Words put on pages for good, as Foxit does: a watermark across each page, and a header and footer with the page number,
/// the date or the file's name. They're drawn into the page's own content, so every app shows and prints them, and the
/// page's text stays text. Each is one change, so Undo takes it off again.
enum PageMarks {
    /// A watermark: words across the middle of the page, faint, at an angle, over or under what's on it.
    struct Watermark: Equatable {
        var text = "KOPIJA"
        var size: CGFloat = 72
        var color = NSColor.systemRed
        var opacity: CGFloat = 0.25
        var angle: CGFloat = 45
        var behind = false
    }

    /// A header and footer: words at the top and foot of the page, at its left, middle and right. In them, <<page>> is the
    /// page's number, <<pages>> how many there are, <<date>> today's date and <<file>> the file's name.
    struct HeaderFooter: Equatable {
        var headerLeft = "", headerCenter = "", headerRight = ""
        var footerLeft = "", footerCenter = "", footerRight = ""
        var size: CGFloat = 10
        var color = NSColor.black
        /// From the page's edge, in points.
        var margin: CGFloat = 24
        /// The number the first page shows.
        var firstNumber = 1

        var isEmpty: Bool { [headerLeft, headerCenter, headerRight, footerLeft, footerCenter, footerRight].allSatisfy { $0.isEmpty } }

        /// Page numbers alone, in the middle of the foot: "Page 3 of 12" in Folio's language.
        static var pageNumbers: HeaderFooter {
            var hf = HeaderFooter()
            hf.footerCenter = String(localized: "Page <<page>> of <<pages>>")
            return hf
        }

        func filled(_ text: String, page: Int, of pages: Int, file: String) -> String {
            text.replacingOccurrences(of: "<<page>>", with: "\(page + firstNumber)")
                .replacingOccurrences(of: "<<pages>>", with: "\(pages + firstNumber - 1)")
                .replacingOccurrences(of: "<<date>>", with: Date.now.formatted(date: .numeric, time: .omitted))
                .replacingOccurrences(of: "<<file>>", with: file)
        }
    }

    /// A copy of `page` with `draw` drawn on it, under its content when `behind`: in the page's upright space, the crop box
    /// as it's seen, whatever its rotation. The marks and form fields `keeps` keeps come along as they were. Nil for a page
    /// PDFKit can't draw.
    static func overlaid(_ page: PDFPage, behind: Bool = false, keeps: (PDFAnnotation) -> Bool = { _ in true },
                         inPageSpace: ((CGContext) -> Void)? = nil, draw: (CGContext, CGSize) -> Void = { _, _ in }) -> PDFPage? {
        guard let ref = page.pageRef else { return nil }
        var media = page.bounds(for: .mediaBox)
        let crop = page.bounds(for: .cropBox)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &media, nil) else { return nil }
        context.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &media, count: MemoryLayout<CGRect>.size)] as CFDictionary)
        func overlay() {
            context.saveGState()
            // Into the crop box as seen: turned with the page, so words read upright however the page is rotated.
            let rotation = ((page.rotation % 360) + 360) % 360
            let seen = rotation % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
            context.translateBy(x: crop.minX, y: crop.minY)
            switch rotation {
            case 90: context.translateBy(x: 0, y: crop.height); context.rotate(by: -.pi / 2)
            case 180: context.translateBy(x: crop.width, y: crop.height); context.rotate(by: .pi)
            case 270: context.translateBy(x: crop.width, y: 0); context.rotate(by: .pi / 2)
            default: break
            }
            draw(context, seen)
            context.restoreGState()
        }
        if behind { overlay() }
        context.drawPDFPage(ref)
        inPageSpace?(context)
        if !behind { overlay() }
        context.endPDFPage()
        context.closePDF()
        guard let made = PDFDocument(data: data as Data)?.page(at: 0) else { return nil }
        made.setBounds(crop, for: .cropBox)
        made.rotation = page.rotation
        for mark in page.annotations where keeps(mark) {
            if let copy = mark.copy() as? PDFAnnotation { made.addAnnotation(copy) }
        }
        return made
    }

    /// `text` drawn with its middle at `center`, turned by `angle` degrees.
    static func drawText(_ text: String, in context: CGContext, center: CGPoint, attributes: [NSAttributedString.Key: Any], angle: CGFloat = 0) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: angle * .pi / 180)
        context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    static func watermark(_ page: PDFPage, _ w: Watermark) -> PDFPage? {
        overlaid(page, behind: w.behind, draw: { context, size in
            context.setAlpha(w.opacity)
            let lines = w.text.components(separatedBy: .newlines)
            let font = NSFont.boldSystemFont(ofSize: w.size)
            for (i, line) in lines.enumerated() {
                let offset = (CGFloat(lines.count - 1) / 2 - CGFloat(i)) * w.size * 1.15
                let angle = w.angle * .pi / 180
                let center = CGPoint(x: size.width / 2 - sin(angle) * offset, y: size.height / 2 + cos(angle) * offset)
                drawText(line, in: context, center: center, attributes: [.font: font, .foregroundColor: w.color], angle: w.angle)
            }
        })
    }

    static func headerFooter(_ page: PDFPage, _ hf: HeaderFooter, index: Int, of count: Int, file: String) -> PDFPage? {
        overlaid(page, draw: { context, size in
            let font = NSFont.systemFont(ofSize: hf.size)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: hf.color]
            let top = size.height - hf.margin - hf.size / 2, foot = hf.margin + hf.size / 2
            let slots: [(String, CGFloat, CGFloat, Int)] = [
                (hf.headerLeft, top, hf.margin, -1), (hf.headerCenter, top, size.width / 2, 0), (hf.headerRight, top, size.width - hf.margin, 1),
                (hf.footerLeft, foot, hf.margin, -1), (hf.footerCenter, foot, size.width / 2, 0), (hf.footerRight, foot, size.width - hf.margin, 1),
            ]
            for (text, y, x, side) in slots where !text.isEmpty {
                let words = hf.filled(text, page: index, of: count, file: file)
                let width = CTLineGetBoundsWithOptions(CTLineCreateWithAttributedString(NSAttributedString(string: words, attributes: attributes)), .useOpticalBounds).width
                let centerX = side < 0 ? x + width / 2 : side > 0 ? x - width / 2 : x
                drawText(words, in: context, center: CGPoint(x: centerX, y: y), attributes: attributes)
            }
        })
    }

    /// Each page of `pdf` passed through `mark`, in a new document's order, or nil when one can't be drawn.
    static func apply(to pages: [PDFPage], _ mark: (PDFPage, Int) -> PDFPage?) -> [PDFPage: PDFPage]? {
        var new: [PDFPage: PDFPage] = [:]
        for (i, page) in pages.enumerated() {
            guard let made = mark(page, i) else { return nil }
            new[page] = made
        }
        return new
    }
}

extension FolioDocument {
    /// Draws the marks, stamps, signatures and filled-in form fields into the pages' content, as Foxit's Flatten does, so
    /// nobody can move or change them. Links and marks for redaction stay as they are. One change, so Undo takes it back.
    func flatten() -> Bool {
        let flattens = { (a: PDFAnnotation) in a.type != "Link" && !a.isRedaction && a.type != "Popup" }
        let chosen = pages.filter { $0.annotations.contains(where: flattens) }
        guard !chosen.isEmpty else { return true }
        guard let new = PageMarks.apply(to: chosen, { page, _ in
            PageMarks.overlaid(page, keeps: { !flattens($0) }, inPageSpace: { context in
                for mark in page.annotations where flattens(mark) && mark.shouldDisplay {
                    context.saveGState()
                    mark.draw(with: .mediaBox, in: context)
                    context.restoreGState()
                }
            })
        }) else { return false }
        setPages(pages.map { new[$0] ?? $0 }, name: "Flatten", replacing: new)
        return true
    }

    /// Marks every place `text` is found for redaction, as one change, and says how many. It finds them in a fresh copy of
    /// the document and marks the same places here: PDFKit gives the matches on the page in view no bounds.
    func markForRedaction(_ text: String) -> Int {
        guard let data = pdf.dataRepresentation(), let copy = PDFDocument(data: data),
              !copy.isLocked || password.map(copy.unlock(withPassword:)) == true else { return 0 }
        var marks: [(PDFAnnotation, PDFPage)] = []
        for found in copy.findString(text, withOptions: [.caseInsensitive, .diacriticInsensitive]) {
            for line in found.selectionsByLine() {
                for shown in line.pages {
                    let box = line.bounds(for: shown)
                    guard box.width > 0, box.width.isFinite, let page = pdf.page(at: copy.index(for: shown)) else { continue }
                    let padded = box.insetBy(dx: -1.5, dy: -1.5)
                    marks.append((shape(.redact, from: padded.origin, to: CGPoint(x: padded.maxX, y: padded.maxY), color: .systemRed), page))
                }
            }
        }
        guard !marks.isEmpty else { return 0 }
        change("Mark for Redaction", do: { for (a, page) in marks { page.addAnnotation(a) } },
               undo: { for (a, page) in marks { page.removeAnnotation(a) } })
        return marks.count
    }

    /// Puts the watermark on these pages, as one change.
    func addWatermark(_ w: PageMarks.Watermark, to chosen: [PDFPage]) -> Bool {
        guard let new = PageMarks.apply(to: chosen, { page, _ in PageMarks.watermark(page, w) }) else { return false }
        setPages(pages.map { new[$0] ?? $0 }, name: "Add Watermark", replacing: new)
        return true
    }

    /// Puts the header and footer on every page, numbered through the whole document, as one change.
    func addHeaderFooter(_ hf: PageMarks.HeaderFooter, file: String) -> Bool {
        let all = pages
        guard let new = PageMarks.apply(to: all, { page, i in PageMarks.headerFooter(page, hf, index: i, of: all.count, file: file) }) else { return false }
        setPages(all.map { new[$0] ?? $0 }, name: "Add Header & Footer", replacing: new)
        return true
    }
}

// MARK: - Sheets

struct WatermarkSheet: View {
    let viewer: Viewer
    @ViewState private var mark = PageMarks.Watermark()
    @ViewState private var everyPage = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Watermark").font(.title2.bold())
            Form {
                TextField("Text", text: $mark.text, axis: .vertical).lineLimit(1...3)
                HStack {
                    ForEach(["KOPIJA", "POVJERLJIVO", "NACRT", "ORIGINAL"], id: \.self) { preset in
                        Button(preset) { mark.text = preset }.controlSize(.small)
                    }
                }
                Slider(value: $mark.size, in: 24...160) { Text("Size") }
                Slider(value: $mark.opacity, in: 0.05...1) { Text("Opacity") }
                Picker("Angle", selection: $mark.angle) {
                    Text("Horizontal").tag(CGFloat(0))
                    Text("Diagonal").tag(CGFloat(45))
                    Text("Vertical").tag(CGFloat(90))
                }
                .pickerStyle(.segmented)
                ColorPicker("Colour", selection: Binding(get: { Color(nsColor: mark.color) }, set: { mark.color = NSColor($0) }))
                Toggle("Behind the page's content", isOn: $mark.behind)
                Picker("Pages", selection: $everyPage) {
                    Text("All pages").tag(true)
                    Text("This page").tag(false)
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Watermark") {
                    viewer.settle()
                    let chosen = everyPage ? viewer.doc.pages : viewer.doc.pdf.page(at: viewer.pageIndex).map { [$0] } ?? []
                    if !viewer.doc.addWatermark(mark, to: chosen) { viewer.message = String(localized: "Couldn't change these pages") }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

struct HeaderFooterSheet: View {
    let viewer: Viewer
    let file: String
    @ViewState var marks: PageMarks.HeaderFooter
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Header & Footer").font(.title2.bold())
            Form {
                Section("Header") { row($marks.headerLeft, $marks.headerCenter, $marks.headerRight) }
                Section("Footer") { row($marks.footerLeft, $marks.footerCenter, $marks.footerRight) }
                Section {
                    HStack {
                        Button("Page Number") { marks.footerCenter = String(localized: "Page <<page>> of <<pages>>") }
                        Button("Date") { marks.headerRight = "<<date>>" }
                        Button("File Name") { marks.headerLeft = "<<file>>" }
                    }
                    .controlSize(.small)
                    Text("<<page>> is the page's number, <<pages>> how many there are, <<date>> today's date and <<file>> the file's name.")
                        .font(.caption).foregroundStyle(.secondary)
                    Stepper(value: $marks.size, in: 6...36) { Text("Size: \(Int(marks.size))") }
                    Stepper(value: $marks.firstNumber, in: 0...9999) { Text("First page number: \(marks.firstNumber)") }
                    ColorPicker("Colour", selection: Binding(get: { Color(nsColor: marks.color) }, set: { marks.color = NSColor($0) }))
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 430)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add to Every Page") {
                    viewer.settle()
                    if !viewer.doc.addHeaderFooter(marks, file: file) { viewer.message = String(localized: "Couldn't change these pages") }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(marks.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    /// The left, centre and right of a header or footer, side by side, each named by its placeholder.
    private func row(_ left: Binding<String>, _ centre: Binding<String>, _ right: Binding<String>) -> some View {
        HStack {
            TextField("Left", text: left, prompt: Text("Left"))
            TextField("Centre", text: centre, prompt: Text("Centre")).multilineTextAlignment(.center)
            TextField("Right", text: right, prompt: Text("Right")).multilineTextAlignment(.trailing)
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
    }
}
#endif

#if os(macOS)
// MARK: - Crop

extension FolioDocument {
    /// Trims each page's crop box by `insets`, in points, as one change: what's cut stays in the file, out of sight, so
    /// Undo, or another app's crop tool, gets it back.
    func crop(_ chosen: [PDFPage], by insets: NSEdgeInsets) {
        let old = chosen.map { $0.bounds(for: .cropBox) }
        let new = old.map { box in
            CGRect(x: box.minX + insets.left, y: box.minY + insets.bottom,
                   width: max(box.width - insets.left - insets.right, 36), height: max(box.height - insets.top - insets.bottom, 36))
        }
        let set = { (boxes: [CGRect]) in for (page, box) in zip(chosen, boxes) { page.setBounds(box, for: .cropBox) } }
        change("Crop Pages", do: { set(new) }, undo: { set(old) })
    }
}

struct FindRedactSheet: View {
    let viewer: Viewer
    @ViewState private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find & Redact").font(.title2.bold())
            Text("Every place these words are found is marked for redaction. Check the marks, then choose Apply Redactions to take the words out for good.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Words, a name, an account number…", text: $text).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Mark for Redaction") {
                    viewer.settle()
                    let count = viewer.doc.markForRedaction(text)
                    viewer.message = count == 0 ? String(localized: "No matches") : String(localized: "Marked \(count) places for redaction")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct CropSheet: View {
    let viewer: Viewer
    @ViewState private var top = 10.0
    @ViewState private var bottom = 10.0
    @ViewState private var left = 10.0
    @ViewState private var right = 10.0
    @ViewState private var everyPage = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Crop Pages").font(.title2.bold())
            Form {
                field("Top", $top)
                field("Bottom", $bottom)
                field("Left", $left)
                field("Right", $right)
                Picker("Pages", selection: $everyPage) {
                    Text("All pages").tag(true)
                    Text(viewer.organizing && !viewer.selection.isEmpty ? "Selected pages" : "This page").tag(false)
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Crop") {
                    viewer.settle()
                    let mm = 72 / 25.4
                    viewer.doc.crop(everyPage ? viewer.doc.pages : viewer.targetPages,
                                    by: NSEdgeInsets(top: top * mm, left: left * mm, bottom: bottom * mm, right: right * mm))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    /// A margin to cut, in millimetres.
    private func field(_ title: LocalizedStringKey, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number.precision(.fractionLength(0...1))).labelsHidden().frame(width: 70)
                .multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
            Text("mm").foregroundStyle(.secondary)
        }
    }
}
#endif
