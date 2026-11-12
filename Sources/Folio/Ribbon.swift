#if os(macOS)
import PDFKit
import SwiftUI

/// The tabs of tools over the pages, as Foxit and Office have them: a row of tab names, and under it the chosen tab's buttons,
/// big ones with their names under them, in groups named at their foot.
struct Ribbon: View {
    @Bindable var viewer: Viewer
    let name: String
    let find: () -> Void
    /// Each window opens on Home, whatever tab the last one was left on.
    @ViewState private var tab = RibbonTab.home
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let _ = viewer.doc.revision
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(RibbonTab.allCases) { t in
                    Button { tab = t } label: {
                        Text(t.name)
                            .font(.system(size: 12, weight: tab == t ? .semibold : .regular))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .foregroundStyle(tab == t ? Color.accentColor : Color.primary)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(tab == t ? Color.accentColor : .clear).frame(height: 2.5)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) { content }
                    .padding(.horizontal, 6).padding(.vertical, 4)
            }
            .frame(height: 92)
            .disabled(viewer.busy != nil)
            Divider()
        }
        .background(.bar)
        .onChange(of: viewer.organizing) { if viewer.organizing { tab = .pages } }
    }

    @ViewBuilder private var content: some View {
        let idle = viewer.isIdle, locked = viewer.doc.pdf.isLocked, full = viewer.doc.pdf.hasFullRights
        switch tab {
        case .home:
            RibbonGroup("Tools", tint: .blue) {
                tool(.hand)
                tool(.select)
                tool(.highlight)
                tool(.text)
                tool(.note)
            }
            RibbonGroup("Pages", tint: .indigo) {
                big("Insert Blank Page", "doc.badge.plus") { viewer.insert([FolioDocument.blankPage(like: viewer.targetPages.last)]) }
                    .help("Insert Blank Page (⇧⌘N)")
                    .disabled(!idle)
            }
            RibbonGroup("Zoom", tint: .teal) {
                big("Zoom In", "plus.magnifyingglass") { viewer.canvas.zoomIn(nil) }
                big("Zoom Out", "minus.magnifyingglass") { viewer.canvas.zoomOut(nil) }
                big("Zoom to Fit", "arrow.up.left.and.arrow.down.right") { viewer.canvas.autoScales = true }
                big("Actual Size", "1.magnifyingglass") { viewer.canvas.scaleFactor = 1 }
            }
            RibbonGroup("View", tint: .indigo) {
                big("Single Page", "doc") { viewer.canvas.displayMode = .singlePage }
                big("Continuous", "doc.text") { viewer.canvas.displayMode = .singlePageContinuous }
                big("Two Pages", "book") { viewer.canvas.displayMode = .twoUpContinuous }
                big("Read Mode", "eyeglasses") { viewer.readMode = true }
            }
            RibbonGroup("Find", tint: .gray) {
                big("Find…", "magnifyingglass", action: find)
                big("Print…", "printer") { viewer.canvas.print(with: .shared, autoRotate: true, pageScaling: .pageScaleToFit) }.disabled(locked)
            }
            RibbonGroup("Sign", tint: .purple) {
                SignatureButton(viewer: viewer, tool: .sign)
                SignatureButton(viewer: viewer, tool: .stamp)
                stampMenu
            }
        case .comment:
            RibbonGroup("Text Markup", tint: .orange) {
                tool(.highlight)
                tool(.underline)
                tool(.strike)
            }
            RibbonGroup("Comments", tint: .yellow) {
                tool(.note)
                tool(.text)
                tool(.date)
            }
            RibbonGroup("Drawing", tint: .pink) {
                tool(.rect)
                tool(.oval)
                tool(.line)
                tool(.arrow)
                tool(.pen)
            }
            RibbonGroup("Mark", tint: .red) {
                VStack(spacing: 4) {
                    ColorPicker("Colour", selection: Binding(get: { viewer.color.cgColor }, set: { viewer.color = NSColor(cgColor: $0) ?? .black }))
                        .labelsHidden()
                    Text("Colour").font(.system(size: 10.5))
                }
                .frame(width: 58)
                big("Add to Every Page", "rectangle.portrait.on.rectangle.portrait") { viewer.addToEveryPage() }.disabled(!viewer.canAddToEveryPage)
                big("Delete", "trash") { viewer.canvas.deleteMark() }.disabled(viewer.mark == nil)
            }
            RibbonGroup("Stamps", tint: .green) { stampMenu }
        case .edit:
            RibbonGroup("Text", tint: .blue) {
                tool(.editText)
                tool(.text)
                tool(.date)
            }
            RibbonGroup("Insert", tint: .green) {
                big("Picture…", "photo.badge.plus") { viewer.addPicture() }.disabled(!idle)
                stampMenu
            }
            RibbonGroup("Page Marks", tint: .teal) {
                big("Watermark", "drop.halffull") { viewer.sheet = .watermark }.disabled(!idle)
                big("Header & Footer", "rectangle.topthird.inset.filled") { viewer.sheet = .headerFooter(pageNumbers: false) }.disabled(!idle)
                big("Page Numbers", "number") { viewer.sheet = .headerFooter(pageNumbers: true) }.disabled(!idle)
            }
            RibbonGroup("Redact", tint: .red) {
                tool(.redact)
                big("Find & Redact…", "text.magnifyingglass") { viewer.sheet = .findRedact }.disabled(!idle)
                big("Apply Redactions", "checkmark.rectangle") { viewer.applyRedactions() }.disabled(!idle || !viewer.doc.hasRedactions)
            }
        case .pages:
            RibbonGroup("Organize", tint: .blue) {
                big(viewer.organizing ? "Stop Organizing" : "Organize Pages", viewer.organizing ? "square.grid.2x2.fill" : "square.grid.2x2") { viewer.organize() }
                    .disabled(locked)
            }
            RibbonGroup("Pages", tint: .indigo) {
                PageActions(viewer: viewer)
            }
            RibbonGroup("Bookmarks", tint: .red) {
                big("Add Bookmark", "bookmark") { viewer.addBookmark() }.disabled(!idle)
            }
            RibbonGroup("Page Size", tint: .orange) {
                big("Crop Pages…", "crop") { viewer.sheet = .crop }.disabled(!idle)
            }
            RibbonGroup("Files", tint: .green) {
                big("Combine Files…", "doc.on.doc") { viewer.combineFiles() }.disabled(!idle)
            }
        case .convert:
            RibbonGroup("Export", tint: .blue) {
                big("To Word", "doc.richtext") { Export.run(.word, viewer: viewer, name: name) }.disabled(locked)
                big("To Excel", "tablecells") { Export.run(.excel, viewer: viewer, name: name) }.disabled(locked)
                big("To Text", "doc.plaintext") { Export.run(.text, viewer: viewer, name: name) }.disabled(locked)
                big("To Pictures", "photo.on.rectangle") { Export.run(.images, viewer: viewer, name: name) }.disabled(locked)
            }
            RibbonGroup("Create", tint: .green) {
                big("Combine Files…", "doc.on.doc") { viewer.combineFiles() }.disabled(!idle)
                big("Insert from File…", "folder.badge.plus") { viewer.choosingPages = true }.disabled(!idle)
            }
            RibbonGroup("Share", tint: .orange) {
                big("Reduce File Size", "arrow.down.right.and.arrow.up.left") { viewer.reduceFileSize() }.disabled(!idle)
                if !locked, viewer.doc.pdf.permissionsStatus == .owner || viewer.doc.pdf.allowsCopying {
                    ShareLink(item: PagePicture(viewer: viewer), preview: SharePreview("Page \(viewer.pageIndex + 1)")) {
                        Label("Send Page as Picture", systemImage: "photo")
                    }
                    .buttonStyle(RibbonButtonStyle())
                }
            }
        case .sign:
            RibbonGroup("Sign", tint: .purple) {
                SignatureButton(viewer: viewer, tool: .sign)
                SignatureButton(viewer: viewer, tool: .initial)
                tool(.date)
            }
            RibbonGroup("Stamp", tint: .green) {
                SignatureButton(viewer: viewer, tool: .stamp)
                stampMenu
            }
            RibbonGroup("Fill", tint: .blue) {
                tool(.select, title: "Fill Form")
                tool(.text)
            }
            RibbonGroup("Form", tint: .indigo) {
                tool(.textField)
                tool(.checkBox)
            }
            RibbonGroup("Certificate", tint: .red) {
                big("Sign with Certificate…", "checkmark.seal.text.page") { viewer.sheet = .digitalSignature }.disabled(!idle || !full)
            }
            RibbonGroup("Manage", tint: .gray) {
                big("New Signature…", "signature") { viewer.sheet = .signature(.sign) }
                big("New Initials…", "character.cursor.ibeam") { viewer.sheet = .signature(.initial) }
                big("New Stamp…", "seal") { viewer.sheet = .signature(.stamp) }
            }
        case .protect:
            RibbonGroup("Secure", tint: .red) {
                big("Sign with Certificate…", "checkmark.seal.text.page") { viewer.sheet = .digitalSignature }.disabled(!idle || !full)
                big("Password…", "lock") { viewer.sheet = .protect }.disabled(!idle || !full)
                big("Properties…", "info.circle") { viewer.sheet = .properties }.disabled(!idle)
            }
            RibbonGroup("Redact", tint: .red) {
                tool(.redact)
                big("Find & Redact…", "text.magnifyingglass") { viewer.sheet = .findRedact }.disabled(!idle)
                big("Apply Redactions", "checkmark.rectangle") { viewer.applyRedactions() }.disabled(!idle || !viewer.doc.hasRedactions)
            }
            RibbonGroup("Mark", tint: .red) {
                big("Watermark", "drop.halffull") { viewer.sheet = .watermark }.disabled(!idle)
                big("Flatten", "square.3.layers.3d.down.right") { viewer.flatten() }.disabled(!idle)
            }
        case .tools:
            RibbonGroup("Scan", tint: .teal) {
                big("Recognize Text", "text.viewfinder") { viewer.recognizeText() }.disabled(!idle)
            }
            RibbonGroup("Optimize", tint: .green) {
                big("Reduce File Size", "arrow.down.right.and.arrow.up.left") { viewer.reduceFileSize() }.disabled(!idle)
            }
            RibbonGroup("Compare", tint: .orange) {
                big("Compare Documents", "rectangle.split.2x1") { viewer.sheet = .compare }.disabled(locked)
            }
            RibbonGroup("Automate", tint: .purple) {
                big("Batch Process…", "square.stack.3d.down.right") { openWindow(id: "batch") }
            }
        }
    }

    /// A tool's button: picks it, and shows it picked while it's in use.
    private func tool(_ t: Tool, title: LocalizedStringKey? = nil) -> some View {
        Button { viewer.pick(t) } label: {
            if let title { Label(title, systemImage: t.symbol) } else { Label(t.name, systemImage: t.symbol) }
        }
        .buttonStyle(RibbonButtonStyle(picked: viewer.tool == t))
        .help("\(t.name) (\(t.key.uppercased()))")
        .disabled(!viewer.isIdle && t != .select)
    }

    private func big(_ title: LocalizedStringKey, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: symbol) }
            .buttonStyle(RibbonButtonStyle())
            .help(Text(title))
    }

    /// The ready-made word stamps.
    private var stampMenu: some View {
        Menu {
            ForEach(TextStamp.allCases) { stamp in
                Button(stamp.words) { viewer.place(stamp) }
            }
        } label: {
            Label("Text Stamps", systemImage: "checkmark.seal")
        }
        .menuStyle(.button)
        .buttonStyle(RibbonButtonStyle())
        .menuIndicator(.hidden)
        .disabled(!viewer.isIdle)
    }
}

enum RibbonTab: String, CaseIterable, Identifiable {
    case home, comment, edit, pages, convert, sign, protect, tools
    var id: Self { self }
    var name: LocalizedStringKey {
        switch self {
        case .home: "Home"
        case .comment: "Comment"
        case .edit: "Edit"
        case .pages: "Pages"
        case .convert: "Convert"
        case .sign: "Fill & Sign"
        case .protect: "Protect"
        case .tools: "Tools"
        }
    }
}

/// A group of the ribbon's buttons, its name under them and a line after it.
struct RibbonGroup<Content: View>: View {
    let title: LocalizedStringKey
    let tint: Color
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, tint: Color = .accentColor, @ViewBuilder content: () -> Content) {
        self.title = title
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 2) {
                HStack(alignment: .top, spacing: 2) { content }
                    .buttonStyle(RibbonButtonStyle())
                    .labelStyle(RibbonLabelStyle())
                    .environment(\.ribbonTint, tint)
                Spacer(minLength: 0)
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 4)
            Divider().padding(.vertical, 6)
        }
    }
}

/// An icon in its group's colour over its name, as on a ribbon.
struct RibbonLabelStyle: LabelStyle {
    @Environment(\.ribbonTint) private var tint

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 3) {
            configuration.icon.font(.system(size: 19)).frame(height: 24).foregroundStyle(tint)
            configuration.title.font(.system(size: 10.5)).lineLimit(2).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 80)
    }
}

private struct RibbonTintKey: EnvironmentKey { static let defaultValue = Color.accentColor }

extension EnvironmentValues {
    /// The colour of the icons in a ribbon group. Written out by hand: @Entry needs Xcode.
    var ribbonTint: Color {
        get { self[RibbonTintKey.self] }
        set { self[RibbonTintKey.self] = newValue }
    }
}

/// A ribbon button: flat, tinted while hovered and while it's the tool in use, faint while it's off.
struct RibbonButtonStyle: ButtonStyle {
    var picked = false
    @Environment(\.isEnabled) private var isEnabled
    @ViewState private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(RibbonLabelStyle())
            .padding(.horizontal, 3).padding(.vertical, 4)
            .foregroundStyle(picked ? Color.accentColor : configuration.role == .destructive ? Color.red : Color.primary)
            .background(RoundedRectangle(cornerRadius: 5).fill(picked ? Color.accentColor.opacity(0.18)
                : configuration.isPressed ? Color.primary.opacity(0.14) : hovering ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.35)
            .onHover { hovering = $0 }
    }
}

/// The bar at the foot of the window, as Foxit's: going through the pages, the zoom, and the way pages are laid out.
struct StatusBar: View {
    @Bindable var viewer: Viewer
    @ViewState private var zoom: CGFloat = 1

    var body: some View {
        let count = viewer.doc.pdf.pageCount, at = viewer.pageIndex
        HStack(spacing: 6) {
            Group {
                Button("First Page", systemImage: "backward.end") { viewer.go(toPage: 1) }.disabled(at == 0)
                Button("Previous", systemImage: "chevron.left") { viewer.go(toPage: at) }.disabled(at == 0)
                TextField("Page", value: Binding(get: { at + 1 }, set: { viewer.go(toPage: $0) }), format: .number)
                    .frame(width: 42).multilineTextAlignment(.center).textFieldStyle(.roundedBorder)
                Text("/ \(count)").monospacedDigit().foregroundStyle(.secondary)
                Button("Next", systemImage: "chevron.right") { viewer.go(toPage: at + 2) }.disabled(at + 1 >= count)
                Button("Last Page", systemImage: "forward.end") { viewer.go(toPage: count) }.disabled(at + 1 >= count)
            }
            .disabled(viewer.doc.pdf.isLocked)
            Spacer()
            Button("Single Page", systemImage: "doc") { viewer.canvas.displayMode = .singlePage }
            Button("Continuous", systemImage: "doc.text") { viewer.canvas.displayMode = .singlePageContinuous }
            Button("Two Pages", systemImage: "book") { viewer.canvas.displayMode = .twoUpContinuous }
            Divider().frame(height: 14)
            Button("Zoom Out", systemImage: "minus") { viewer.canvas.zoomOut(nil) }
            Slider(value: Binding(get: { log2(max(zoom, 0.1)) }, set: { viewer.canvas.scaleFactor = pow(2, $0) }), in: -2...3)
                .frame(width: 110).controlSize(.mini)
            Button("Zoom In", systemImage: "plus") { viewer.canvas.zoomIn(nil) }
            Text("\(Int((zoom * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.system(size: 11.5))
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onReceive(NotificationCenter.default.publisher(for: .PDFViewScaleChanged, object: viewer.canvas)) { _ in zoom = viewer.canvas.scaleFactor }
        .onAppear { zoom = viewer.canvas.scaleFactor }
    }
}
#endif
