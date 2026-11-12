import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct FolioApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    #else
    /// SwiftUI's documents save themselves as they change, with no switch to stop it. Folio's wait for ⌘S, so closing or
    /// quitting with changes asks whether to save them.
    /// shortcut: this replaces the answer of SwiftUI's document class, found by its name; were it renamed, Folio would save as
    /// it goes again. Give Folio an NSDocument of its own if that happens.
    init() {
        guard let documents = NSClassFromString("SwiftUI.PlatformDocument") else { return }
        let never: @convention(block) (AnyClass) -> Bool = { _ in false }
        class_replaceMethod(object_getClass(documents), #selector(getter: NSDocument.autosavesInPlace), imp_implementationWithBlock(never), "B@:")
    }
    #endif

    var body: some Scene {
        DocumentGroup(newDocument: {
            #if os(iOS)
            if #available(iOS 27, *) { Self.noteWhichButton() }
            #else
            if let combined = Combine.take() { return combined }
            #endif
            return FolioDocument()
        }) { DocumentView(doc: $0.document, url: $0.fileURL) }
            .commands { FolioCommands() }
            #if os(macOS)
            .defaultSize(width: 1280, height: 880)
            #endif
            #if os(macOS)
            // The home window opens at launch, not the Open panel.
            .defaultLaunchBehavior(.suppressed)
            #endif
        #if os(macOS)
        Window("Home", id: "home") { Home() }
            .defaultLaunchBehavior(.presented)
            .restorationBehavior(.disabled)
            .windowStyle(.hiddenTitleBar)
            .defaultSize(width: 760, height: 520)
        // Opened from File › Batch Process… only, never at launch.
        Window("Batch Process", id: "batch") { BatchSheet() }
            .windowResizability(.contentSize)
            .restorationBehavior(.disabled)
            .defaultLaunchBehavior(.suppressed)
        #else
        DocumentGroupLaunchScene("Folio", backgroundStyle: LinearGradient(colors: [Color(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255),
                                                                                    Color(red: 0x9E / 255, green: 0x1B / 255, blue: 0x25 / 255)],
                                                                           startPoint: .top, endPoint: .bottom)) {
            // Two buttons show, and any more fold into More…, so where there's a camera, Scan Document takes the place of
            // Create Document, which the Create Document tile among the files still does. The simulator has no camera.
            if Scanner.isAvailable {
                if #available(iOS 27, *) {
                    // iOS 27 runs no button's closure, and tells this button from Create from Photos by its content type: see
                    // noteWhichButton.
                    NewDocumentButton("Scan Document", contentType: .pdf)
                } else {
                    // The pages scanned, their words read; Cancel makes no document.
                    NewDocumentButton("Scan Document", for: FolioDocument.self) { try Self.document(of: await Scanner.scan()) }
                }
            } else {
                NewDocumentButton()
            }
            // A page for each photo, in the order chosen; Cancel makes no document. iOS 27 never runs this, making a blank
            // document instead: see noteWhichButton.
            NewDocumentButton("Create from Photos", for: FolioDocument.self) { try Self.document(of: await FolioDocument.pagesOfChosenPhotos()) }
        }
        #endif
    }
}

#if os(iOS)
extension FolioApp {
    /// A new document of these pages, or none for Cancel, which gave none.
    private static func document(of pages: [PDFPage]) throws -> FolioDocument {
        guard !pages.isEmpty else { throw CancellationError() }
        let pdf = PDFDocument()
        for page in pages { pdf.insert(page, at: pdf.pageCount) }
        return FolioDocument(pdf: pdf)
    }

    /// Notes whether the document being made is for Create from Photos or Scan Document, for its view to show Photos' picker
    /// or the scanner. iOS 27 makes it as for Create Document, never running the closure given to either button, but the
    /// document browser knows which button it was. SwiftUI makes it off the main thread, where UIKit can't be asked, and
    /// makes another as it opens the file, with no button being made then. iOS 26 runs the closures instead, and gives every
    /// button a name made up as it launches.
    private static func noteWhichButton() {
        let note = {
            MainActor.assumeIsolated {
                for scene in UIApplication.shared.connectedScenes {
                    var controllers = (scene as? UIWindowScene)?.windows.compactMap(\.rootViewController) ?? []
                    while let controller = controllers.popLast() {
                        if let intent = (controller as? UIDocumentBrowserViewController)?.activeDocumentCreationIntent {
                            // Such as "SwiftUIcom.adobe.pdf-0" for Scan Document and "SwiftUIFolio.FolioDocument-1" for Create from
                            // Photos, numbered by their place.
                            return DocumentView.making = intent == .default ? nil : intent.rawValue.contains(UTType.pdf.identifier) ? .scan : .photos
                        }
                        controllers += controller.children + [controller.presentedViewController].compactMap { $0 }
                    }
                }
            }
        }
        Thread.isMainThread ? note() : DispatchQueue.main.sync(execute: note)
    }
}
#endif

#if os(macOS)
// Written out by hand: the @Entry macro's plugin ships only with Xcode, not the Command Line Tools.
private struct ViewerKey: FocusedValueKey { typealias Value = Viewer }
private struct SearchFocusKey: FocusedValueKey { typealias Value = FocusState<Bool>.Binding }

extension FocusedValues {
    var viewer: Viewer? {
        get { self[ViewerKey.self] }
        set { self[ViewerKey.self] = newValue }
    }
    var searchFocus: FocusState<Bool>.Binding? {
        get { self[SearchFocusKey.self] }
        set { self[SearchFocusKey.self] = newValue }
    }
}
#else
/// The document in the key window, for the menu bar: iPad's commands don't see a document's focused values.
@Observable final class Front {
    static let shared = Front()
    var document: (viewer: Viewer, searchFocus: FocusState<Bool>.Binding)?
}

/// The end of the responder chain, where iPad's own Edit › Find lands, from the menu or its keys, with or without a first
/// responder. It takes Find, Find Next and Find Previous before Folio's commands can. Find ends Markup and Organize Pages, whose
/// tools take the find field's place, and shows the field, which takes the keys as it shows, or at once if it shows already.
final class AppDelegate: UIResponder, UIApplicationDelegate {
    override func find(_ sender: Any?) {
        Front.shared.document?.viewer.backToReading()
        Front.shared.document?.viewer.finding = true
        Front.shared.document?.searchFocus.wrappedValue = true
    }
    override func findNext(_ sender: Any?) { Front.shared.document?.viewer.step(1) }
    override func findPrevious(_ sender: Any?) { Front.shared.document?.viewer.step(-1) }
}
#endif

#if os(macOS)
/// Combine Files: one new document of the pages of several PDFs and pictures, in the order of their names, to reorder in
/// Organize Pages and save where you like.
enum Combine {
    /// The document File › New makes next, in place of a blank one. SwiftUI makes documents away from the main thread too,
    /// as it opens files, so it's behind a lock.
    nonisolated(unsafe) private static var pending: FolioDocument?
    private static let lock = NSLock()

    /// The document waiting for File › New, taken so the next one is blank again.
    static func take() -> FolioDocument? {
        lock.withLock {
            defer { pending = nil }
            return pending
        }
    }

    @MainActor static func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, .image]
        panel.message = String(localized: "Choose the files to combine, in any order: they go in by name.")
        panel.prompt = String(localized: "Combine")
        guard panel.runModal() == .OK else { return }
        combine(panel.urls)
    }

    @MainActor static func combine(_ urls: [URL]) {
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let pages = FolioDocument.pages(from: sorted)
        guard !pages.isEmpty else {
            let alert = NSAlert()
            alert.messageText = String(localized: "Found no pages to insert: a PDF with a password or restrictions gives none")
            alert.runModal()
            return
        }
        let pdf = PDFDocument()
        for page in pages { pdf.insert(page, at: pdf.pageCount) }
        let made = FolioDocument(pdf: pdf)
        lock.withLock { pending = made }
        NSDocumentController.shared.newDocument(nil)
    }
}

/// File › Batch Process…, which opens its window.
struct BatchButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("Batch Process…") { openWindow(id: "batch") } }
}

/// The language of Folio's words, chosen in the Folio menu: it overrides the Mac's language for Folio alone, for a Mac whose
/// first language isn't the one its user wants Folio in.
enum AppLanguage {
    static let choices: [(code: String?, name: String)] = [(nil, ""), ("en", "English"), ("tr", "Türkçe"), ("bs", "Bosanski"),
                                                           ("fr", "Français"), ("zh-Hans", "简体中文")]

    static var current: String? {
        guard UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] != nil
        else { return nil }
        return UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first
    }

    @MainActor static func set(_ code: String?) {
        guard code != current else { return }
        if let code { UserDefaults.standard.set([code], forKey: "AppleLanguages") } else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        let alert = NSAlert()
        alert.messageText = String(localized: "Restart Folio to use the new language.")
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
#endif

struct FolioCommands: Commands {
    #if os(macOS)
    @FocusedValue(\.viewer) private var viewer
    @FocusedValue(\.searchFocus) private var searchFocus
    #else
    private var viewer: Viewer? { Front.shared.document?.viewer }
    #endif

    var body: some Commands {
        #if os(macOS)
        CommandGroup(after: .appInfo) {
            Menu("Language") {
                ForEach(AppLanguage.choices, id: \.name) { lang in
                    Toggle(isOn: Binding(get: { AppLanguage.current == lang.code }, set: { _ in AppLanguage.set(lang.code) })) {
                        if lang.code == nil { Text("System default") } else { Text(verbatim: lang.name) }
                    }
                }
            }
        }
        CommandGroup(after: .newItem) {
            Button("Combine Files…") { Combine.choose() }.keyboardShortcut("n", modifiers: [.command, .option])
            BatchButton()
        }
        // SwiftUI shows Save As only while Option is held, in Duplicate's place.
        CommandGroup(after: .saveItem) {
            Button("Save As…") { NSApp.sendAction(#selector(NSDocument.saveAs(_:)), to: nil, from: nil) }
                .keyboardShortcut("s", modifiers: [.command, .shift, .option])
                .disabled(viewer == nil)
        }
        // iPad's Edit menu has these: see AppDelegate.
        CommandGroup(after: .textEditing) {
            Button("Find…") { searchFocus?.wrappedValue = true }.keyboardShortcut("f")
            Button("Find Next") { viewer?.step(1) }.keyboardShortcut("g")
            Button("Find Previous") { viewer?.step(-1) }.keyboardShortcut("g", modifiers: [.command, .shift])
        }
        #endif
        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                #if os(macOS)
                viewer?.canvas.print(with: .shared, autoRotate: true, pageScaling: .pageScaleToFit)
                #else
                guard let viewer else { return }
                viewer.settle()
                UIPrintInteractionController.shared.printingItem = try? viewer.doc.snapshot(contentType: .pdf)
                UIPrintInteractionController.shared.present(animated: true)
                #endif
            }
            .keyboardShortcut("p")
            .disabled(viewer?.doc.pdf.isLocked ?? true)
        }
        CommandGroup(after: .toolbar) {
            Button("Single Page") { viewer?.canvas.displayMode = .singlePage }
            Button("Continuous") { viewer?.canvas.displayMode = .singlePageContinuous }
            Button("Two Pages") { viewer?.canvas.displayMode = .twoUpContinuous }
            Divider()
            Button("Zoom In") { viewer?.canvas.zoomIn(nil) }.keyboardShortcut("+")
            Button("Zoom Out") { viewer?.canvas.zoomOut(nil) }.keyboardShortcut("-")
            Button("Actual Size") { viewer?.canvas.scaleFactor = 1 }.keyboardShortcut("0")
            Button("Zoom to Fit") { viewer?.canvas.autoScales = true }.keyboardShortcut("9")
            Divider()
            Button("Thumbnails") { viewer?.show(.thumbnails) }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Bookmarks") { viewer?.show(.bookmarks) }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("Comments") { viewer?.show(.comments) }.keyboardShortcut("3", modifiers: [.command, .option])
            #if os(macOS)
            Button(viewer?.readMode == true ? "Leave Read Mode" : "Read Mode") { viewer?.readMode.toggle() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            #endif
            Divider()
        }
        CommandMenu("Pages") {
            Button(viewer?.organizing == true ? "Stop Organizing" : "Organize Pages") { viewer?.organize() }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(viewer?.doc.pdf.isLocked ?? true)
            Divider()
            PageActions(viewer: viewer)
            #if os(macOS)
            Button("Crop Pages…") { viewer?.sheet = .crop }.disabled(!(viewer?.isIdle ?? false))
            #endif
        }
        CommandMenu("Tools") { ToolsMenu(viewer: viewer) }
        #if os(macOS)
        ImportFromDevicesCommands()
        #endif
    }
}

/// The page in view, the words being typed included, as a picture named after its number, for the share sheet.
struct PagePicture: Transferable {
    let viewer: Viewer

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .jpeg) { shared in
            try await MainActor.run {
                shared.viewer.settle()
                guard let page = shared.viewer.doc.pdf.page(at: shared.viewer.pageIndex), let data = picture(of: page) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                return data
            }
        }
        .suggestedFileName { String(localized: "Page \($0.viewer.pageIndex + 1)") }
    }
}

/// The Tools menu: the menu bar's, and on iOS the navigation bar's too, as iPhone has no menu bar.
struct ToolsMenu: View {
    let viewer: Viewer?

    var body: some View {
        let idle = viewer?.isIdle ?? false
        Button("Recognize Text") { viewer?.recognizeText() }.disabled(!idle)
        #if os(macOS)
        Button("Find & Redact…") { viewer?.sheet = .findRedact }.disabled(!idle)
        #endif
        Button("Apply Redactions") { viewer?.applyRedactions() }.disabled(!idle || viewer?.doc.hasRedactions != true)
        #if os(macOS)
        Button("Reduce File Size") { viewer?.reduceFileSize() }.disabled(!idle)
        #endif
        #if os(macOS)
        Button("Sign with Certificate…") { viewer?.sheet = .digitalSignature }.disabled(!idle || viewer?.doc.pdf.hasFullRights != true)
        #endif
        Button("Password…") { viewer?.sheet = .protect }.disabled(!idle || viewer?.doc.pdf.hasFullRights != true)
        Button("Properties…") { viewer?.sheet = .properties }.disabled(!idle)
        Button("Add to Every Page") { viewer?.addToEveryPage() }.disabled(viewer?.canAddToEveryPage != true)
        #if os(macOS)
        Divider()
        Button("Add Picture…") { viewer?.addPicture() }.disabled(!idle)
        Button("Flatten") { viewer?.flatten() }.disabled(!idle)
        Button("Watermark…") { viewer?.sheet = .watermark }.disabled(!idle)
        Button("Header & Footer…") { viewer?.sheet = .headerFooter(pageNumbers: false) }.disabled(!idle)
        Button("Page Numbers…") { viewer?.sheet = .headerFooter(pageNumbers: true) }.disabled(!idle)
        Menu("Text Stamps") {
            ForEach(TextStamp.allCases) { stamp in Button(stamp.words) { viewer?.place(stamp) } }
        }
        .disabled(!idle)
        Button("Compare Documents…") { viewer?.sheet = .compare }.disabled(viewer?.doc.pdf.isLocked ?? true)
        Menu("Export") {
            Button("To Word…") { if let viewer { Export.run(.word, viewer: viewer, name: viewer.exportName) } }
            Button("To Text…") { if let viewer { Export.run(.text, viewer: viewer, name: viewer.exportName) } }
            Button("To Pictures…") { if let viewer { Export.run(.images, viewer: viewer, name: viewer.exportName) } }
        }
        .disabled(viewer?.doc.pdf.isLocked ?? true)
        #endif
        if let viewer, !viewer.doc.pdf.isLocked, viewer.doc.pdf.permissionsStatus == .owner || viewer.doc.pdf.allowsCopying {
            ShareLink("Send Page as Picture", item: PagePicture(viewer: viewer), preview: SharePreview("Page \(viewer.pageIndex + 1)"))
        } else {
            Button("Send Page as Picture") {}.disabled(true)
        }
        Divider()
        Button("Edit Signature…") { viewer?.sheet = .signature(.sign) }.disabled(viewer == nil)
        Button("Edit Initials…") { viewer?.sheet = .signature(.initial) }.disabled(viewer == nil)
        Button("Edit Stamp…") { viewer?.sheet = .signature(.stamp) }.disabled(viewer == nil)
        #if os(macOS)
        Divider()
        Button("Show Fonts") { NSFontManager.shared.orderFrontFontPanel(nil) }.keyboardShortcut("t").disabled(viewer == nil)
        #endif
    }
}
