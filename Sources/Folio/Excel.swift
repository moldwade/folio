#if os(macOS)
import PDFKit

// MARK: - Tables from pages

/// The words of each page as a table, for a spreadsheet: a row for each line, and the pieces of a line that sit apart, as a
/// table's columns do, in columns where they sit, lined up from page to page by where the page's columns are.
enum Tables {
    /// A piece of a line: its words and where it spans across the page.
    struct Cell {
        var text: String
        var minX: CGFloat, maxX: CGFloat
    }

    /// A sheet for each page: its rows, each its cells by column.
    static func sheets(of pdf: PDFDocument) -> [[[String]]] {
        // From a fresh copy: PDFKit gives the characters of the page in view no bounds.
        let source = pdf.dataRepresentation().flatMap(PDFDocument.init(data:)) ?? pdf
        return (0..<source.pageCount).map { source.page(at: $0).map(table) ?? [] }
    }

    /// The page's lines, top to bottom, each split into cells where its words sit far apart.
    static func lines(of page: PDFPage) -> [[Cell]] {
        // Each character by a selection of its own, whose words and bounds PDFKit counts alike: the page's string and its
        // character bounds don't line up.
        var glyphs: [(char: String, box: CGRect)] = []
        for i in 0..<page.numberOfCharacters {
            guard let one = page.selection(for: NSRange(location: i, length: 1)), let char = one.string,
                  !char.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let box = one.bounds(for: page)
            // A line's end gives its last character again.
            guard box.width.isFinite, box.height > 0, glyphs.last?.box != box else { continue }
            glyphs.append((char, box))
        }
        // Lines: characters whose middles are within half a character's height of each other, top first.
        var rows: [[(char: String, box: CGRect)]] = []
        for glyph in glyphs.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let last = rows.last?.first, abs(last.box.midY - glyph.box.midY) < min(last.box.height, glyph.box.height) / 2 {
                rows[rows.count - 1].append(glyph)
            } else {
                rows.append([glyph])
            }
        }
        // Within a line, a gap of more than a character's height starts a new cell, and a smaller one is a space.
        return rows.map { row in
            var cells: [Cell] = []
            var previous: CGRect?
            for glyph in row.sorted(by: { $0.box.minX < $1.box.minX }) {
                let gap = previous.map { glyph.box.minX - $0.maxX } ?? .infinity, height = glyph.box.height
                if gap > height * 0.9 || cells.isEmpty {
                    cells.append(Cell(text: glyph.char, minX: glyph.box.minX, maxX: glyph.box.maxX))
                } else {
                    if gap > height * 0.12 { cells[cells.count - 1].text += " " }
                    cells[cells.count - 1].text += glyph.char
                    cells[cells.count - 1].maxX = max(cells[cells.count - 1].maxX, glyph.box.maxX)
                }
                previous = glyph.box
            }
            return cells
        }
    }

    /// The page as rows of columns. The columns are the stretches across the page that the cells of lines of more than one
    /// cell cover, apart from the gaps none of them covers; each cell goes in the column its middle is in.
    static func table(_ page: PDFPage) -> [[String]] {
        let lines = lines(of: page)
        var spans = lines.filter { $0.count > 1 }.flatMap { $0 }.map { ($0.minX, $0.maxX) }.sorted { $0.0 < $1.0 }
        var columns: [(minX: CGFloat, maxX: CGFloat)] = []
        for span in spans {
            if let last = columns.last, span.0 <= last.maxX + 2 { columns[columns.count - 1].maxX = max(last.maxX, span.1) } else { columns.append(span) }
        }
        spans = []
        if columns.isEmpty { return lines.map { [$0.map(\.text).joined(separator: " ")] } }
        return lines.map { line in
            var row: [String] = []
            for cell in line {
                let middle = (cell.minX + cell.maxX) / 2
                // The column its middle is in, or the nearest; a line's only cell, such as a title, the one it starts in.
                let byMiddle = line.count > 1 ? columns.firstIndex { $0.minX - 2 <= middle && middle <= $0.maxX + 2 } : nil
                let column = byMiddle
                    ?? columns.firstIndex { $0.minX - 2 <= cell.minX && cell.minX <= $0.maxX + 2 }
                    ?? columns.indices.min { abs(columns[$0].minX - cell.minX) < abs(columns[$1].minX - cell.minX) }!
                while row.count <= column { row.append("") }
                row[column] = row[column].isEmpty ? cell.text : row[column] + " " + cell.text
            }
            return row
        }
    }
}

// MARK: - Excel files

/// A spreadsheet in Excel's format, a sheet for each page: words as text, and numbers, written as Bosnian and Croatian
/// papers write them, 1.234,56, or plainly, 1234.56, as numbers to count with.
enum Xlsx {
    static func data(_ sheets: [[[String]]]) throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("folio-xlsx-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("x")
        for dir in ["_rels", "xl/_rels", "xl/worksheets"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let head = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        let indices = sheets.indices
        var files: [String: String] = [:]
        files["[Content_Types].xml"] = head + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>"#
            + indices.map { #"<Override PartName="/xl/worksheets/sheet\#($0 + 1).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"# }.joined() + "</Types>"
        files["_rels/.rels"] = head + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="\#(rel)/officeDocument" Target="xl/workbook.xml"/></Relationships>"#
        files["xl/workbook.xml"] = head + #"<workbook xmlns="\#(main)" xmlns:r="\#(rel)"><sheets>"#
            + indices.map { i in
                let name = escaped(String(localized: "Page \(i + 1)"))
                return #"<sheet name="\#(name)" sheetId="\#(i + 1)" r:id="rId\#(i + 1)"/>"#
            }.joined() + "</sheets></workbook>"
        files["xl/_rels/workbook.xml.rels"] = head + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + indices.map { #"<Relationship Id="rId\#($0 + 1)" Type="\#(rel)/worksheet" Target="worksheets/sheet\#($0 + 1).xml"/>"# }.joined() + "</Relationships>"
        for (n, rows) in sheets.enumerated() {
            let width = rows.map(\.count).max() ?? 0
            let cols = width == 0 ? "" : "<cols>" + (0..<width).map { c in
                // By the rows of a table, not a title on a line of its own, which spills over the cells beside it.
                let table = rows.filter { $0.filter { !$0.isEmpty }.count > 1 }
                let longest = (table.isEmpty ? rows : table).map { c < $0.count ? $0[c].count : 0 }.max() ?? 0
                return #"<col min="\#(c + 1)" max="\#(c + 1)" width="\#(min(max(longest + 2, 8), 60))" customWidth="1"/>"#
            }.joined() + "</cols>"
            let data = rows.enumerated().map { r, row in
                #"<row r="\#(r + 1)">"# + row.enumerated().compactMap { c, value in
                    guard !value.isEmpty else { return nil }
                    let ref = column(c) + "\(r + 1)"
                    if let number = number(value) { return #"<c r="\#(ref)"><v>\#(number)</v></c>"# }
                    return #"<c r="\#(ref)" t="inlineStr"><is><t xml:space="preserve">\#(escaped(value))</t></is></c>"#
                }.joined() + "</row>"
            }.joined()
            files["xl/worksheets/sheet\(n + 1).xml"] = head + #"<worksheet xmlns="\#(main)">\#(cols)<sheetData>\#(data)</sheetData></worksheet>"#
        }
        for (path, text) in files { try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        let out = folder.appendingPathComponent("out.xlsx")
        try Docx.run("/usr/bin/zip", ["-q", "-X", "-r", out.path, "."], in: root)
        return try Data(contentsOf: out)
    }

    /// The column's letters: A to Z, then AA and on.
    static func column(_ index: Int) -> String {
        var index = index + 1, name = ""
        while index > 0 {
            let rest = (index - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + rest))) + name
            index = (index - 1) / 26
        }
        return name
    }

    /// The value as a number, when it's one: 1.234,56 and 12,5 as Bosnian writes them, or 1234.56; never a date, a phone
    /// number or a code that only looks like one, such as 007.
    static func number(_ value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespaces)
        // A bank account, JMBG or tax number is a code: as a number, Excel would round it or show it as 4,2E+12.
        guard v.filter(\.isNumber).count <= 11 else { return nil }
        if v.range(of: #"^-?(0|[1-9]\d{0,2}(\.\d{3})+|[1-9]\d*)(,\d+)?$"#, options: .regularExpression) != nil {
            return v.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        }
        if v.range(of: #"^-?(0|[1-9]\d*)\.\d{1,2}$"#, options: .regularExpression) != nil { return v }
        return nil
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .filter { $0 == "\t" || $0 == "\n" || $0.unicodeScalars.allSatisfy { $0.value >= 0x20 } }
    }
}
#endif
