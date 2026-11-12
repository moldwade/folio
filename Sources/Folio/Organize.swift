import PDFKit
import SwiftUI

/// The pages as a grid, over the page view while organizing. A click selects a page, and ⌘ and ⇧ clicks select more; on
/// iOS a tap selects or deselects one. Dragged pages move in front of the page they're dropped on, or to the end.
struct Organizer: View {
    let viewer: Viewer

    var body: some View {
        let pages = viewer.doc.pages, revision = viewer.doc.revision
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 172), spacing: 12)], spacing: 16) {
                ForEach(Array(pages.enumerated()), id: \.element) { index, page in
                    PageCell(page: page, number: index + 1, selected: viewer.selection.contains(page), revision: revision)
                        .onTapGesture {
                            #if os(macOS)
                            viewer.click(page, modifiers: NSEvent.modifierFlags)
                            #else
                            viewer.selection.formSymmetricDifference([page])
                            #endif
                        }
                        .draggable(viewer.dragged(page))
                        .dropDestination(for: String.self) { items, _ in
                            guard let item = items.first else { return false }
                            return viewer.drop(item, before: page)
                        }
                }
            }
            .padding()
        }
        .dropDestination(for: String.self) { items, _ in
            guard let item = items.first else { return false }
            return viewer.drop(item, before: nil)
        }
        .background(.background)
    }
}

/// A page in the organizer, as it shows, with its number under it, and tinted when selected.
private struct PageCell: View {
    let page: PDFPage
    let number: Int
    let selected: Bool
    /// The document's revision, to draw the page again when it changes.
    let revision: Int
    @ViewState private var image: CGImage?

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image { Image(decorative: image, scale: 2).resizable().scaledToFit().shadow(radius: 2) } else { Color.clear }
            }
            .frame(width: 160, height: 160)
            .padding(6)
            .background(selected ? Color.accentColor.opacity(0.25) : .clear, in: .rect(cornerRadius: 8))
            Text("\(number)").monospacedDigit().foregroundStyle(selected ? Color.accentColor : Color.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(number)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .task(id: revision) {
            let size = page.bounds(for: .cropBox).size
            image = shown(page, dpi: 72 * 320 / max(size.width, size.height, 1))
        }
    }
}

/// What acts on pages: the selected ones while organizing, otherwise the one in view. They make the Pages menu, and the bar
/// across the pages while organizing.
struct PageActions: View {
    let viewer: Viewer?

    var body: some View {
        let _ = viewer?.doc.revision
        let idle = viewer?.isIdle ?? false, chosen = idle && viewer?.targetPages.isEmpty == false
        Button("Rotate Left", systemImage: "rotate.left") { if let viewer { viewer.doc.rotate(viewer.targetPages, by: -90) } }
            .keyboardShortcut("l")
            .help("Rotate Left")
            .disabled(!chosen)
        Button("Rotate Right", systemImage: "rotate.right") { if let viewer { viewer.doc.rotate(viewer.targetPages, by: 90) } }
            .keyboardShortcut("r")
            .help("Rotate Right")
            .disabled(!chosen)
        #if os(iOS)
        // One tile at the foot of the pages, where one for each way to insert would not fit across an iPhone.
        Menu("Insert Pages", systemImage: "plus") { inserts(idle) }
            .menuStyle(.button)
            .buttonStyle(Tile())
            .disabled(!idle)
        #else
        inserts(idle)
        #endif
        Button("Extract Pages…", systemImage: "square.and.arrow.up") { viewer?.extract() }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .help("Extract Pages… (⇧⌘E)")
            .disabled(!chosen || viewer?.doc.pdf.hasFullRights != true)
        Button("Split…", systemImage: "scissors") {
            viewer?.settle()
            viewer?.sheet = .split
        }
        .help("Split…")
        .disabled(!idle || viewer?.doc.pdf.hasFullRights != true || (viewer?.doc.pdf.pageCount ?? 0) < 2)
        Button("Delete Pages", systemImage: "trash", role: .destructive) { viewer?.deletePages() }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .help("Delete Pages (⇧⌘⌫)")
            .disabled(!idle || viewer?.canDelete != true)
    }

    @ViewBuilder private func inserts(_ idle: Bool) -> some View {
        Button("Insert Blank Page", systemImage: "doc.badge.plus") { viewer?.insert([FolioDocument.blankPage(like: viewer?.targetPages.last)]) }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .help("Insert Blank Page (⇧⌘N)")
            .disabled(!idle)
        Button("Insert from File…", systemImage: "folder.badge.plus") { viewer?.choosingPages = true }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .help("Insert from File… (⇧⌘I)")
            .disabled(!idle)
        #if os(iOS)
        Button("Insert from Photos…", systemImage: "photo.badge.plus") { Task { await viewer?.insert(FolioDocument.pagesOfChosenPhotos()) } }
            .disabled(!idle)
        if Scanner.isAvailable {
            Button("Scan Pages…", systemImage: "doc.viewfinder") { Task { await viewer?.insertScanned(Scanner.scan()) } }
                .disabled(!idle)
        }
        #endif
    }
}

#if os(macOS)
/// The sidebar's pages: a picture of each with its number, the one in view marked. A click goes to a page, a drag moves
/// it, and a right click has what can be done to it.
struct PageList: View {
    let viewer: Viewer

    var body: some View {
        let pages = viewer.doc.pages, revision = viewer.doc.revision
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(pages.enumerated()), id: \.element) { index, page in
                        SidePage(page: page, number: index + 1, current: index == viewer.pageIndex, revision: revision)
                            .id(index)
                            .onTapGesture { viewer.canvas.go(to: page) }
                            .contextMenu { PageMenu(viewer: viewer, page: page) }
                            .draggable(viewer.dragged(page))
                            .dropDestination(for: String.self) { items, _ in
                                guard let item = items.first else { return false }
                                return viewer.drop(item, before: page)
                            }
                    }
                }
                .padding(10)
            }
            .contextMenu {
                Button("Insert Blank Page at End") { viewer.doc.insert([FolioDocument.blankPage(like: pages.last)], at: pages.count) }
                    .disabled(!viewer.isIdle)
            }
            .onChange(of: viewer.pageIndex) { proxy.scrollTo(viewer.pageIndex) }
        }
    }
}

/// What a right click on a page in the sidebar does to that page.
struct PageMenu: View {
    let viewer: Viewer
    let page: PDFPage

    var body: some View {
        let idle = viewer.isIdle, index = viewer.doc.pages.firstIndex(of: page) ?? 0
        Group {
            Button("Insert Blank Page After") { viewer.doc.insert([FolioDocument.blankPage(like: page)], at: index + 1) }
            Button("Insert Blank Page Before") { viewer.doc.insert([FolioDocument.blankPage(like: page)], at: index) }
            Button("Insert from File…") {
                viewer.canvas.go(to: page)
                viewer.choosingPages = true
            }
            Button("Duplicate Page") { viewer.doc.insert([page.copy() as! PDFPage], at: index + 1) }
            Divider()
            Button("Rotate Left") { viewer.doc.rotate([page], by: -90) }
            Button("Rotate Right") { viewer.doc.rotate([page], by: 90) }
            Divider()
            Button("Extract Page…") { viewer.extract([page]) }.disabled(!viewer.doc.pdf.hasFullRights)
            Button("Delete Page", role: .destructive) { viewer.doc.delete([page]) }.disabled(viewer.doc.pdf.pageCount < 2)
        }
        .disabled(!idle)
    }
}

/// A page in the sidebar, with its number under it, framed while it's the one in view.
private struct SidePage: View {
    let page: PDFPage
    let number: Int
    let current: Bool
    let revision: Int
    @ViewState private var image: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image { Image(decorative: image, scale: 2).resizable().scaledToFit().shadow(radius: 1.5) } else { Color.white.opacity(0.6) }
            }
            .frame(width: 130, height: 150)
            .padding(5)
            .background(current ? Color.accentColor.opacity(0.22) : .clear, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(current ? Color.accentColor : .clear, lineWidth: 2))
            Text("\(number)").font(.caption).monospacedDigit().foregroundStyle(current ? Color.accentColor : Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .task(id: revision) {
            // Once the changes stop for a moment: drawn on each step of a drag, the pages would stutter.
            if image != nil { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            let size = page.bounds(for: .cropBox).size
            image = shown(page, dpi: 72 * 300 / max(size.width, size.height, 1))
        }
    }
}
#endif
