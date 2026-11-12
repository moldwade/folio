import PDFKit
import SwiftUI

/// Adding, renaming and deleting bookmarks, as Foxit does. Each is one change, so Undo takes it back.
extension FolioDocument {
    /// The document to write: itself, or, once its bookmarks were edited, a fresh one with copies of its pages and the
    /// bookmarks pointing at them, which PDFKit writes as they are.
    var writable: PDFDocument {
        guard bookmarksEdited, let root = pdf.outlineRoot else { return pdf }
        let fresh = PDFDocument()
        var copies: [PDFPage: PDFPage] = [:]
        for page in pages {
            guard let copy = page.copy() as? PDFPage else { return pdf }
            copies[page] = copy
            fresh.insert(copy, at: fresh.pageCount)
        }
        fresh.outlineRoot = Self.outline(root) { copies[$0] }
        fresh.documentAttributes = pdf.documentAttributes
        return fresh
    }

    /// A copy of `outline`, each bookmark to `page(of:)` its page.
    static func outline(_ outline: PDFOutline, page: (PDFPage) -> PDFPage?) -> PDFOutline {
        let copy = PDFOutline()
        (copy.label, copy.isOpen) = (outline.label, outline.isOpen)
        if let to = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination, let from = to.page, let target = page(from) {
            copy.destination = PDFDestination(page: target, at: to.point)
        } else {
            copy.action = outline.action
        }
        for i in 0..<outline.numberOfChildren {
            if let child = outline.child(at: i) { copy.insertChild(Self.outline(child, page: page), at: copy.numberOfChildren) }
        }
        return copy
    }

    /// A bookmark named `label` to the top of `page`, after the others.
    func addBookmark(_ label: String, to page: PDFPage) {
        let root = pdf.outlineRoot ?? PDFOutline()
        let item = PDFOutline()
        item.label = label
        let box = page.bounds(for: .cropBox)
        item.destination = PDFDestination(page: page, at: CGPoint(x: box.minX, y: box.maxY))
        let hadRoot = pdf.outlineRoot != nil
        change("Add Bookmark", do: {
            if !hadRoot { self.pdf.outlineRoot = root }
            root.insertChild(item, at: root.numberOfChildren)
            self.bookmarksEdited = true
        }, undo: {
            item.removeFromParent()
            if !hadRoot { self.pdf.outlineRoot = nil }
        })
    }

    func rename(_ item: PDFOutline, to label: String) {
        let old = item.label
        change("Rename Bookmark", do: { item.label = label; self.bookmarksEdited = true }, undo: { item.label = old })
    }

    func delete(_ item: PDFOutline) {
        guard let parent = item.parent else { return }
        let index = item.index
        change("Delete Bookmark", do: { item.removeFromParent(); self.bookmarksEdited = true },
               undo: { parent.insertChild(item, at: index) })
    }
}

extension Viewer {
    /// A bookmark to the page in view, named after it.
    func addBookmark() {
        settle()
        guard let page = canvas.currentPage else { return }
        doc.addBookmark(String(localized: "Page \(doc.pdf.index(for: page) + 1)"), to: page)
        show(.bookmarks)
    }
}

/// A form field dragged from `start` to `end`, as Foxit's Form tools make: a text field anyone can type in, or a check box,
/// each named "Field 1", "Field 2" and so on, which other apps fill in too. A click without a drag gives the usual size.
func formField(_ tool: Tool, from start: CGPoint, to end: CGPoint, on page: PDFPage) -> PDFAnnotation {
    var box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    if tool == .checkBox {
        let side = max(min(box.width, box.height), 14)
        box = CGRect(x: box.minX, y: box.minY, width: side, height: side)
        if hypot(end.x - start.x, end.y - start.y) < 6 { box.origin = CGPoint(x: start.x - 7, y: start.y - 7) }
    } else if box.width < 20 || box.height < 10 {
        box = CGRect(x: start.x, y: start.y - 11, width: 180, height: 22)
    }
    let field = PDFAnnotation(bounds: box, forType: .widget, withProperties: nil)
    if tool == .checkBox {
        field.widgetFieldType = .button
        field.widgetControlType = .checkBoxControl
    } else {
        field.widgetFieldType = .text
        field.font = NSFont.systemFont(ofSize: min(max(box.height * 0.6, 8), 14))
    }
    let taken = Set((page.document.map { d in (0..<d.pageCount).flatMap { d.page(at: $0)?.annotations ?? [] } } ?? []).compactMap(\.fieldName))
    let number = (1...).first { !taken.contains(String(localized: "Field \($0)")) }!
    field.fieldName = String(localized: "Field \(number)")
    field.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.08)
    let border = PDFBorder()
    border.lineWidth = 1
    field.border = border
    field.color = NSColor.systemBlue.withAlphaComponent(0.6)
    return field
}
