import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum Tool: String, CaseIterable, Identifiable {
    case hand, select, highlight, underline, strike, note, text, rect, oval, line, arrow, pen, sign, initial, stamp, date, editText, redact
    case textField, checkBox

    var id: Self { self }

    /// In the language Folio shows.
    var name: String {
        let english = switch self {
        case .hand: "Hand"
        case .select: "Select"
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strike: "Strike Through"
        case .note: "Note"
        case .text: "Text Box"
        case .rect: "Rectangle"
        case .oval: "Oval"
        case .line: "Line"
        case .arrow: "Arrow"
        case .pen: "Pen"
        case .sign: "Sign"
        case .initial: "Initial"
        case .stamp: "Stamp"
        case .date: "Date"
        case .editText: "Edit Text"
        case .redact: "Redact"
        case .textField: "Text Field"
        case .checkBox: "Check Box"
        }
        return NSLocalizedString(english, comment: "")
    }

    var symbol: String {
        switch self {
        case .hand: "hand.raised"
        case .select: "cursorarrow"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strike: "strikethrough"
        case .note: "note.text"
        case .text: "textformat"
        case .rect: "rectangle"
        case .oval: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .pen: "pencil.tip"
        case .sign: "signature"
        case .initial: "pencil.and.scribble"
        case .stamp: "seal"
        case .date: "calendar"
        case .editText: "character.cursor.ibeam"
        case .redact: "rectangle.fill"
        case .textField: "character.textbox"
        case .checkBox: "checkmark.square"
        }
    }

    /// The key that picks the tool while the page has the keyboard.
    var key: String {
        switch self {
        case .hand: "m"
        case .select: "v"
        case .highlight: "h"
        case .underline: "u"
        case .strike: "k"
        case .note: "n"
        case .text: "t"
        case .rect: "r"
        case .oval: "o"
        case .line: "l"
        case .arrow: "a"
        case .pen: "p"
        case .sign: "s"
        case .initial: "i"
        case .stamp: "c"
        case .date: "d"
        case .editText: "e"
        case .redact: "x"
        case .textField: "f"
        case .checkBox: "b"
        }
    }

    /// The tool a document opens with, and goes back to once a mark is placed: on the Mac the hand, which scrolls the page
    /// by dragging and picks, moves and sizes marks, as Foxit's does; on iOS, where a finger scrolls anyway, Select.
    static var browsing: Tool {
        #if os(macOS)
        .hand
        #else
        .select
        #endif
    }

    /// Whether the tool picks marks rather than making them.
    var picks: Bool { self == .select || self == .hand }

    init?(key: String) {
        guard let tool = Self.allCases.first(where: { $0.key == key }) else { return nil }
        self = tool
    }
}

/// One highlight, underline or strike-through for each line of the selection.
func markups(_ selection: PDFSelection, type: PDFAnnotationSubtype, color: NSColor) -> [(page: PDFPage, annotation: PDFAnnotation)] {
    selection.selectionsByLine().flatMap { line in
        line.pages.compactMap { page -> (page: PDFPage, annotation: PDFAnnotation)? in
            let bounds = line.bounds(for: page)
            guard !bounds.isEmpty else { return nil }
            let mark = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
            mark.color = color
            // Other apps draw text markup from its quadrilateral, top left, top right, bottom left, bottom right.
            mark.quadrilateralPoints = [CGPoint(x: 0, y: bounds.height), CGPoint(x: bounds.width, y: bounds.height),
                                        .zero, CGPoint(x: bounds.width, y: 0)].map { $0 as NSValue }
            return (page, mark)
        }
    }
}

/// A rectangle, oval, line or arrow, or a redaction mark, dragged from `start` to `end` in page space.
func shape(_ tool: Tool, from start: CGPoint, to end: CGPoint, color: NSColor) -> PDFAnnotation {
    let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    let type: PDFAnnotationSubtype = tool == .oval ? .circle : tool == .line || tool == .arrow ? .line : .square
    let a = PDFAnnotation(bounds: type == .line ? box.insetBy(dx: -10, dy: -10) : box, forType: type, withProperties: nil)
    a.border = PDFBorder()
    a.border?.lineWidth = 2
    a.color = color
    if type == .line {
        a.startPoint = CGPoint(x: start.x - a.bounds.minX, y: start.y - a.bounds.minY)
        a.endPoint = CGPoint(x: end.x - a.bounds.minX, y: end.y - a.bounds.minY)
        if tool == .arrow { a.endLineStyle = .openArrow }
    }
    if tool == .redact {
        a.color = .systemRed
        a.interiorColor = NSColor.systemRed.withAlphaComponent(0.25)
        a.setValue("folio-redaction", forAnnotationKey: .name)
    }
    return a
}

/// Strokes in page space, as one ink annotation. Its paths are relative to its bounds.
func ink(_ strokes: [[CGPoint]], color: NSColor, width: CGFloat) -> PDFAnnotation {
    let bounds = extent(strokes).insetBy(dx: -width, dy: -width)
    let a = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
    a.color = color
    a.border = PDFBorder()
    a.border?.lineWidth = width
    for stroke in strokes {
        let line = CGMutablePath()
        line.addLines(between: stroke.map { CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY) })
        let path = NSBezierPath(cgPath: line)
        path.lineWidth = width
        a.add(path)
    }
    return a
}

/// The box around every point of the strokes.
private func extent(_ strokes: [[CGPoint]]) -> CGRect {
    strokes.joined().reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
}

/// A white text box over the line of text at `point`, holding the same words in the same font and size, to be edited.
func coverLine(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
    guard let line = page.selectionForLine(at: point), let words = line.string?.trimmingCharacters(in: .whitespacesAndNewlines),
          !words.isEmpty else { return nil }
    let bounds = line.bounds(for: page).insetBy(dx: -2, dy: -2)
    guard bounds.contains(point) else { return nil }
    let a = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
    a.contents = words
    a.font = line.attributedString?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: bounds.height * 0.75)
    a.fontColor = .black
    a.color = .white
    a.border = PDFBorder()
    a.border?.lineWidth = 0
    return a
}

/// An empty text box at `point` in the chosen style, or with none chosen, in the font, size and colour of the nearest text on
/// the page, so what is typed matches it. At the height of a line it puts the words on that line's baseline; elsewhere it
/// is centred on the point. A page with no text gets Helvetica 12 in black, a font every PDF app has.
func textBox(at point: CGPoint, on page: PDFPage, style: TextStyle? = nil) -> PDFAnnotation {
    // Each run of one font and colour on the page, with its line's bounds.
    var runs: [(bounds: CGRect, line: CGRect, style: [NSAttributedString.Key: Any])] = []
    for line in page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? [] {
        guard let text = line.attributedString else { continue }
        let start = line.range(at: 0, on: page).location, bounds = line.bounds(for: page)
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { style, range, _ in
            let run = page.selection(for: NSRange(location: start + range.location, length: range.length))?.bounds(for: page) ?? .zero
            if !run.isEmpty { runs.append((run, bounds, style)) }
        }
    }
    let distance = { (r: CGRect) in hypot(max(r.minX - point.x, 0, point.x - r.maxX), max(r.minY - point.y, 0, point.y - r.maxY)) }
    let beside = runs.filter { $0.line.minY...$0.line.maxY ~= point.y }
    let near = (beside.isEmpty ? runs : beside).min { distance($0.bounds) < distance($1.bounds) }
    // PDFKit draws a text box's words 2 pt in from its left and about 3.5 pt down from its top, so a box 2 pt under the line's
    // descent and 3.5 pt over its ascent puts them on the line's baseline.
    let font = style?.font ?? near?.style[.font] as? NSFont ?? NSFont(name: "Helvetica", size: 12)!, height = font.ascender - font.descender + 5.5
    let y = beside.isEmpty ? point.y - height / 2 : near!.line.minY - 2
    let box = PDFAnnotation(bounds: CGRect(x: point.x - 2, y: y, width: font.pointSize, height: height), forType: .freeText, withProperties: nil)
    box.font = font
    box.fontColor = style?.color ?? near?.style[.foregroundColor] as? NSColor ?? .black
    box.color = style?.fill ?? .clear
    box.border = PDFBorder()
    box.border?.lineWidth = 0
    return box
}

/// `bounds` grown to hold `text` in `font`, from the same top left corner. Never shrunk: an Edit Text cover that shrank would
/// uncover the line beneath it.
func fit(_ bounds: CGRect, around text: String, in font: NSFont) -> CGRect {
    let size = (text as NSString).size(withAttributes: [.font: font])
    let width = max(bounds.width, size.width + 8), height = max(bounds.height, size.height + 4)
    return CGRect(x: bounds.minX, y: bounds.maxY - height, width: width, height: height)
}

extension PDFAnnotation {
    var isRedaction: Bool { value(forAnnotationKey: .name) as? String == "folio-redaction" }

    /// What the Select tool picks: any annotation but a form field, a link or a note's popup.
    var isMark: Bool { !["Widget", "Link", "Popup"].contains(type ?? "") }

    /// Whether its corner handle sizes it: a text box, a box or oval, or a signature, stamp or picture. A stroke, line or
    /// highlight would only be clipped.
    var resizes: Bool { keepsProportions || ["FreeText", "Square", "Circle"].contains(type ?? "") }

    /// Whether sizing it keeps its shape: a signature, stamp or picture, which would look squashed otherwise.
    var keepsProportions: Bool {
        #if os(macOS)
        self is SignatureAnnotation || self is TextStampAnnotation || type == "Stamp"
        #else
        self is SignatureAnnotation || type == "Stamp"
        #endif
    }

    var isComment: Bool {
        !isRedaction && ["Text", "FreeText", "Highlight", "Underline", "StrikeOut", "Square", "Circle", "Line", "Ink"].contains(type ?? "")
    }
}

/// The user's signature, initials or stamp: strokes drawn on the pad, y up; typed and shown in a script font; or a picture,
/// such as a photo of the company's stamp, kept as a PNG of its ink alone.
enum Signature: Codable, Equatable {
    case drawn([[CGPoint]])
    case typed(String)
    case image(Data)

    /// The signature the sign tool places, the initials for the initial tool, or the stamp for the stamp tool: the one chosen
    /// of those saved for it. Setting one saves it beside the others, if it's new, and chooses it; setting nil forgets the
    /// chosen one. It's read on every step of a drag, so the list last decoded is kept for as long as it's the one saved.
    static subscript(tool: Tool) -> Signature? {
        get {
            let all = saved(tool)
            guard !all.isEmpty else { return nil }
            return all[min(max(chosen(tool), 0), all.count - 1)]
        }
        set {
            var all = saved(tool)
            if let newValue {
                if let at = all.firstIndex(of: newValue) { choose(at, for: tool) } else {
                    all.append(newValue)
                    save(all, for: tool)
                    choose(all.count - 1, for: tool)
                }
            } else if !all.isEmpty {
                all.remove(at: min(max(chosen(tool), 0), all.count - 1))
                save(all, for: tool)
                choose(max(all.count - 1, 0), for: tool)
            }
        }
    }

    /// Every signature, set of initials or stamp saved for the tool, oldest first. One saved before there could be several
    /// is the first.
    static func saved(_ tool: Tool) -> [Signature] {
        let key = tool.rawValue + ".all"
        if let old = UserDefaults.standard.data(forKey: tool.rawValue) {
            UserDefaults.standard.removeObject(forKey: tool.rawValue)
            // Added to any list there is, never in place of it: an older Folio may have saved one since.
            if let one = try? JSONDecoder().decode(Signature.self, from: old) {
                var list = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([Signature].self, from: $0) } ?? []
                if !list.contains(one) { list.append(one) }
                UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: key)
            }
        }
        let data = UserDefaults.standard.data(forKey: key)
        if let read = read[tool], read.data == data { return read.list }
        let list = data.flatMap { try? JSONDecoder().decode([Signature].self, from: $0) } ?? []
        read[tool] = (data, list)
        return list
    }
    nonisolated(unsafe) private static var read: [Tool: (data: Data?, list: [Signature])] = [:]

    static func save(_ list: [Signature], for tool: Tool) {
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: tool.rawValue + ".all")
    }

    /// Which of the saved ones the tool places.
    static func chosen(_ tool: Tool) -> Int { UserDefaults.standard.integer(forKey: tool.rawValue + ".chosen") }
    static func choose(_ index: Int, for tool: Tool) { UserDefaults.standard.set(index, forKey: tool.rawValue + ".chosen") }

    /// Forgets one of the saved ones, keeping the chosen one chosen when it's another.
    static func forget(_ index: Int, for tool: Tool) {
        var all = saved(tool)
        guard all.indices.contains(index) else { return }
        all.remove(at: index)
        save(all, for: tool)
        let was = chosen(tool)
        choose(was > index ? was - 1 : min(was, max(all.count - 1, 0)), for: tool)
    }

    #if os(macOS)
    /// A picture of it in black ink, or its own picture's colours, fitted in `size`, for the list to choose from.
    func image(fitting size: CGSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let inner = rect.insetBy(dx: 4, dy: 4)
            if case .image(let png) = self, let picture = Signature.picture(png) {
                let scale = min(inner.width / CGFloat(picture.width), inner.height / CGFloat(picture.height))
                let w = CGFloat(picture.width) * scale, h = CGFloat(picture.height) * scale
                context.interpolationQuality = .high
                context.draw(picture, in: CGRect(x: inner.midX - w / 2, y: inner.midY - h / 2, width: w, height: h))
            } else {
                context.addPath(path(in: inner))
                context.setFillColor(NSColor.black.cgColor)
                context.fillPath()
            }
            return true
        }
    }
    #endif

    /// Its outline, to fill, y up: the strokes in ink, or the name's letters with no line finer than a pen's. A picture has
    /// none.
    var path: CGPath {
        switch self {
        case .image:
            return CGMutablePath()
        case .drawn(let strokes):
            let path = CGMutablePath()
            strokes.forEach { path.addPath(inked($0)) }
            return path
        case .typed(let name):
            let letters = CGMutablePath()
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: name, attributes: [.font: NSFont(name: "SnellRoundhand", size: 100)!]))
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont, count = CTRunGetGlyphCount(run)
                var glyphs = [CGGlyph](repeating: 0, count: count), positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(), &glyphs)
                CTRunGetPositions(run, CFRange(), &positions)
                for (glyph, position) in zip(glyphs, positions) {
                    var at = CGAffineTransform(translationX: position.x, y: position.y)
                    // The script's hairlines are finer than any pen's, and vanish when the name is small. Letter by letter
                    // is seven times quicker than the whole name, which matters while a drag redraws it.
                    CTFontCreatePathForGlyph(font, glyph, &at).map {
                        letters.addPath($0.union($0.copy(strokingWithWidth: 1.5, lineCap: .round, lineJoin: .round, miterLimit: 1)))
                    }
                }
            }
            return letters
        }
    }

    /// Its outline fitted into `rect`, keeping its shape, in the middle.
    func path(in rect: CGRect) -> CGPath {
        let path = path
        guard !path.isEmpty else { return path }   // a name not typed yet, or only spaces: nothing to fit
        let box = path.boundingBoxOfPath, scale = min(rect.width / box.width, rect.height / box.height)
        var fit = CGAffineTransform(translationX: rect.midX - box.width * scale / 2, y: rect.midY - box.height * scale / 2)
            .scaledBy(x: scale, y: scale).translatedBy(x: -box.minX, y: -box.minY)
        return path.copy(using: &fit)!
    }

    /// The signature fitted into `rect`, keeping its shape.
    func annotation(in rect: CGRect, type: PDFAnnotationSubtype = .stamp) -> PDFAnnotation {
        if case .image(let png) = self, let picture = Self.picture(png) {
            let scale = min(rect.width / CGFloat(picture.width), rect.height / CGFloat(picture.height))
            let size = CGSize(width: CGFloat(picture.width) * scale, height: CGFloat(picture.height) * scale)
            let a = SignatureAnnotation(bounds: CGRect(origin: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), size: size),
                                        forType: type, withProperties: nil)
            a.picture = picture
            return a
        }
        let path = path(in: rect)
        let a = SignatureAnnotation(bounds: path.boundingBoxOfPath, forType: type, withProperties: nil)
        var origin = CGAffineTransform(translationX: -a.bounds.minX, y: -a.bounds.minY)
        a.outline = path.copy(using: &origin)!
        a.natural = a.bounds.size
        a.color = .black
        return a
    }

    /// The picture in a PNG, decoded now rather than each time it's drawn. Asked for on every step of a drag, so the last
    /// one is kept for its PNG.
    static func picture(_ png: Data) -> CGImage? {
        if let decoded, decoded.png == png { return decoded.picture }
        let now = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        let picture = CGImageSourceCreateWithData(png as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, now) }
        decoded = (png, picture)
        return picture
    }
    private static var decoded: (png: Data, picture: CGImage?)?

    /// A photo or scan of a signature or stamp on paper, as a PNG of its ink alone: the paper made clear, the ink in its own
    /// colour, turned upright, at most 1,000 pixels a side and cropped to the ink. Nil for a file that isn't a picture, or
    /// a picture with no ink.
    static func lifted(from data: Data) -> Data? {
        let upright = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: 1000] as CFDictionary
        let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), let photo = CGImageSourceCreateThumbnailAtIndex(source, 0, upright)
        else { return nil }
        let (width, height) = (photo.width, photo.height), all = CGRect(x: 0, y: 0, width: width, height: height)
        // The photo on white, so a clear background counts as paper.
        guard let read = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let write = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        read.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        read.fill(all)
        read.draw(photo, in: all)
        write.clear(all)
        let (from, to) = (read.data!.assumingMemoryBound(to: UInt8.self), write.data!.assumingMemoryBound(to: UInt8.self))
        // How dark each pixel is, by the darkest of its red, green and blue. The paper is the level 90% of the pixels are
        // no lighter than, and the ink the level 2% are no lighter than.
        var counts = [Int](repeating: 0, count: 256)
        for y in 0..<height {
            for x in 0..<width { let p = from + y * read.bytesPerRow + x * 4; counts[Int(min(p[0], p[1], p[2]))] += 1 }
        }
        let level = { (share: Double) in Double(counts.indices.first { counts[...$0].reduce(0, +) >= Int(share * Double(width * height)) } ?? 255) }
        let paper = max(level(0.9), 1), ink = level(0.02) / paper
        // Clear within 15% of the paper; solid 60% of the way to the ink, or darker; partly clear between.
        let clear = 0.15, solid = max(clear + 0.1, 0.6 * (1 - ink))
        var inked = (minX: width, minY: height, maxX: -1, maxY: -1)
        for y in 0..<height {
            for x in 0..<width {
                let p = from + y * read.bytesPerRow + x * 4, q = to + y * write.bytesPerRow + x * 4
                let r = min(Double(p[0]) / paper, 1), g = min(Double(p[1]) / paper, 1), b = min(Double(p[2]) / paper, 1)
                let alpha = min(max((1 - min(r, g, b) - clear) / (solid - clear), 0), 1)
                guard alpha > 0 else { continue }
                // Premultiplied by the ink's share, with the white it lets through taken out.
                let channel = { (c: Double) in UInt8(min(max(c - 1 + alpha, 0), alpha) * 255) }
                (q[0], q[1], q[2], q[3]) = (channel(r), channel(g), channel(b), UInt8(alpha * 255))
                if alpha >= 0.5 { inked = (min(inked.minX, x), min(inked.minY, y), max(inked.maxX, x), max(inked.maxY, y)) }
            }
        }
        let crop = CGRect(x: inked.minX - 2, y: inked.minY - 2, width: inked.maxX - inked.minX + 5, height: inked.maxY - inked.minY + 5)
        let png = NSMutableData()
        guard inked.maxX >= 0, let cropped = write.makeImage()?.cropping(to: crop.intersection(all)),
              let file = CGImageDestinationCreateWithData(png as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(file, cropped, nil)
        return CGImageDestinationFinalize(file) ? png as Data : nil
    }
}

/// How big a signature, initials or a stamp goes on the page when a click places it: small, medium or large, as chosen
/// in the list of saved ones, and the sizes a selected one can be set to.
enum MarkSize: Int, CaseIterable, Identifiable {
    case small, medium, large

    var id: Self { self }

    var name: String {
        switch self {
        case .small: String(localized: "Small")
        case .medium: String(localized: "Medium")
        case .large: String(localized: "Large")
        }
    }

    static var current: MarkSize {
        get { MarkSize(rawValue: UserDefaults.standard.object(forKey: "markSize") as? Int ?? 1) ?? .medium }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "markSize") }
    }

    /// The box it's fitted into: a stamp about the size of a company's rubber stamp at Medium, 120 points a side; a
    /// signature 180 by 45 points; initials half that.
    func box(for tool: Tool) -> CGSize {
        let scale: CGFloat = [0.65, 1, 1.45][rawValue]
        switch tool {
        case .stamp: return CGSize(width: 120 * scale, height: 120 * scale)
        case .initial: return CGSize(width: 90 * scale, height: 36 * scale)
        default: return CGSize(width: 180 * scale, height: 45 * scale)
        }
    }

    /// The box for a mark already on a page, by what it is: a picture or stamp is a stamp, a word stamp keeps its own
    /// proportions, anything else a signature.
    static func tool(for mark: PDFAnnotation) -> Tool {
        if let mark = mark as? SignatureAnnotation, mark.picture != nil { return .stamp }
        return mark is SignatureAnnotation ? .sign : .stamp
    }
}

/// A placed signature: its outline, from the bounds' corner, filled in its colour, or its picture filling the bounds. PDFKit
/// writes this drawing into the file as the annotation's appearance, so it is the same picture at any size and zoom, here
/// and in other apps.
final class SignatureAnnotation: PDFAnnotation {
    var outline: CGPath = CGMutablePath()
    var picture: CGImage?
    /// The size the outline was made for: sized since, it's stretched to the bounds.
    var natural = CGSize.zero

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        if let picture {
            context.interpolationQuality = .high
            context.draw(picture, in: bounds)
        } else {
            context.translateBy(x: bounds.minX, y: bounds.minY)
            if natural.width > 0, natural.height > 0 { context.scaleBy(x: bounds.width / natural.width, y: bounds.height / natural.height) }
            context.addPath(outline)
            context.setFillColor(color.cgColor)
            context.fillPath()
        }
        context.restoreGState()
    }

    /// PDFKit copies a page's annotations this way, for Extract and Split, and would leave the outline and picture behind.
    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! SignatureAnnotation
        copy.outline = outline
        copy.picture = picture
        copy.natural = natural
        return copy
    }
}

/// A stroke of the pen as ink, an outline to fill: smoothed into curves between the midpoints of its points, and thinner
/// where the pen moved faster. The points come at a steady rate, so the gap between two is the speed.
private func inked(_ stroke: [CGPoint]) -> CGPath {
    var points: [SIMD3<Double>] = []   // x, y and the speed there, then the width
    for p in stroke where points.last.map({ hypot(p.x - $0.x, p.y - $0.y) >= 1 }) ?? true {
        let gap = points.last.map { hypot(p.x - $0.x, p.y - $0.y) } ?? 0, speed = 0.7 * gap + 0.3 * (points.last?.z ?? 0)
        points.append(SIMD3(p.x, p.y, speed))
    }
    points = points.map { SIMD3($0.x, $0.y, max(3.5 / (1 + $0.z / 10), 1)) }
    guard points.count > 1 else {
        return CGPath(ellipseIn: CGRect(x: stroke[0].x - 1.75, y: stroke[0].y - 1.75, width: 3.5, height: 3.5), transform: nil)
    }
    // Each point is the control of a quadratic curve from the midpoint before it to the one after; the ends are the ends.
    let ends = [points[0]] + zip(points, points.dropFirst()).map { ($0 + $1) / 2 } + [points[points.count - 1]]
    var samples = [points[0]]
    for (i, c) in points.enumerated() {
        let a = ends[i], b = ends[i + 1], steps = max(1, Int((hypot(c.x - a.x, c.y - a.y) + hypot(b.x - c.x, b.y - c.y)) / 4))
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            samples.append((1 - t) * (1 - t) * a + 2 * (1 - t) * t * c + t * t * b)
        }
    }
    // Half the width out to the left of each sample, round the end, back along the right and round the start.
    let normals = samples.indices.map { i in
        let d = samples[min(i + 1, samples.count - 1)] - samples[max(i - 1, 0)]
        return atan2(d.y, d.x) + .pi / 2
    }
    let edge = { (i: Int, angle: Double) in
        CGPoint(x: samples[i].x + samples[i].z / 2 * cos(angle), y: samples[i].y + samples[i].z / 2 * sin(angle))
    }
    let last = samples.count - 1, cap = (1..<8).map { Double.pi * Double($0) / 8 }
    let outline = samples.indices.map { edge($0, normals[$0]) } + cap.map { edge(last, normals[last] - $0) }
        + samples.indices.reversed().map { edge($0, normals[$0] + .pi) } + cap.map { edge(0, normals[0] + .pi - $0) }
    // Through the midpoints of the outline too, so it stays a curve however far it is zoomed.
    let path = CGMutablePath(), mid = { (i: Int) in
        let a = outline[i], b = outline[(i + 1) % outline.count]
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
    path.move(to: mid(outline.count - 1))
    for i in outline.indices { path.addQuadCurve(to: mid(i), control: outline[i]) }
    path.closeSubpath()
    return path
}

extension PDFPage {
    /// Takes the annotation off the page. iOS's PDFKit leaves a stamp's picture on the screen once it's off, unless it was
    /// hidden as it went; it's shown again after, for when it comes back.
    func drop(_ a: PDFAnnotation) {
        let shown = a.shouldDisplay
        a.shouldDisplay = false
        removeAnnotation(a)
        a.shouldDisplay = shown
    }
}

extension FolioDocument {
    func add(_ a: PDFAnnotation, to page: PDFPage, name: String) {
        change(name, do: { page.addAnnotation(a) }, undo: { page.drop(a) })
    }

    func remove(_ a: PDFAnnotation) {
        guard let page = a.page else { return }
        change("Delete", do: { page.drop(a) }, undo: { page.addAnnotation(a) })
    }

    func set<V>(_ key: ReferenceWritableKeyPath<PDFAnnotation, V>, of a: PDFAnnotation, to value: V, name: String) {
        let old = a[keyPath: key]
        change(name, do: { a[keyPath: key] = value }, undo: { a[keyPath: key] = old })
    }

    /// Puts the text box in `font`, grown to hold its words in it.
    func setFont(_ font: NSFont, of box: PDFAnnotation) {
        let old = (font: box.font, bounds: box.bounds), bounds = fit(box.bounds, around: box.contents ?? "", in: font)
        change("Change Font", do: { box.font = font; box.bounds = bounds }, undo: { box.font = old.font; box.bounds = old.bounds })
    }

    /// Copies of the mark on every other page, at the same place on each, as one change: initials on each page of a
    /// contract, or a stamp. On a page of another size the copy keeps its size, and its middle sits as far across and up
    /// the page as the mark's does on its own. It returns how many pages got one.
    /// shortcut: a page turned another way than the mark's gets its copy unturned. Turn the copies with their pages if
    /// files that mix upright and turned pages ever need it.
    @discardableResult
    func addToEveryPage(_ mark: PDFAnnotation) -> Int {
        guard let home = mark.page, pdf.pageCount > 1 else { return 0 }
        let from = home.bounds(for: .cropBox), size = mark.bounds.size
        let copies = pages.filter { $0 != home }.map { page in
            let to = page.bounds(for: .cropBox), copy = mark.copy() as! PDFAnnotation
            let middle = CGPoint(x: to.minX + (mark.bounds.midX - from.minX) / from.width * to.width,
                                 y: to.minY + (mark.bounds.midY - from.minY) / from.height * to.height)
            copy.bounds = CGRect(origin: CGPoint(x: middle.x - size.width / 2, y: middle.y - size.height / 2), size: size)
            return (page: page, mark: copy)
        }
        change("Add to Every Page", do: { copies.forEach { $0.page.addAnnotation($0.mark) } }, undo: { copies.forEach { $0.page.drop($0.mark) } })
        return copies.count
    }

    /// Every comment, page by page.
    var comments: [(page: PDFPage, annotation: PDFAnnotation)] {
        pages.flatMap { page in page.annotations.filter(\.isComment).map { (page, $0) } }
    }

    var hasRedactions: Bool { pages.contains { $0.annotations.contains(where: \.isRedaction) } }
}
