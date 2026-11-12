import PDFKit
import SwiftUI

/// How the text box tool writes: the font, its size, bold and italic, the colour of the words, and a background or none.
/// The last one chosen is kept for the next text box, in every document.
struct TextStyle: Equatable {
    var family = "Helvetica"
    var size: CGFloat = 12
    var bold = false
    var italic = false
    var color: NSColor = .black
    var fill: NSColor?

    /// Fonts every Mac has and Word and other PDF apps know.
    static let families = ["Helvetica", "Arial", "Times New Roman", "Georgia", "Verdana", "Tahoma", "Courier New", "Trebuchet MS"]

    init() {}

    /// The style a text box already has.
    init(of box: PDFAnnotation) {
        if let font = box.font {
            family = font.familyName ?? family
            size = font.pointSize
            #if os(macOS)
            let traits = NSFontManager.shared.traits(of: font)
            (bold, italic) = (traits.contains(.boldFontMask), traits.contains(.italicFontMask))
            #else
            let traits = font.fontDescriptor.symbolicTraits
            (bold, italic) = (traits.contains(.traitBold), traits.contains(.traitItalic))
            #endif
        }
        color = box.fontColor ?? .black
        fill = box.color.alphaComponent > 0 ? box.color : nil
    }

    var font: NSFont {
        #if os(macOS)
        var font = NSFont(name: family, size: size) ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
            ?? NSFont(name: "Helvetica", size: size)!
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
        #else
        let font = UIFont(name: family, size: size) ?? .systemFont(ofSize: size)
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        return font.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: size) } ?? font
        #endif
    }

    static var saved: TextStyle {
        var style = TextStyle()
        let defaults = UserDefaults.standard
        guard let saved = defaults.dictionary(forKey: "textStyle") else { return style }
        style.family = saved["family"] as? String ?? style.family
        style.size = saved["size"] as? CGFloat ?? style.size
        style.bold = saved["bold"] as? Bool ?? false
        style.italic = saved["italic"] as? Bool ?? false
        style.color = (saved["color"] as? [CGFloat]).flatMap(color) ?? .black
        style.fill = (saved["fill"] as? [CGFloat]).flatMap(color)
        return style
    }

    func save() {
        var saved: [String: Any] = ["family": family, "size": size, "bold": bold, "italic": italic, "color": Self.components(color)]
        if let fill { saved["fill"] = Self.components(fill) }
        UserDefaults.standard.set(saved, forKey: "textStyle")
    }

    private static func components(_ color: NSColor) -> [CGFloat] {
        let c = color.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components ?? [0, 0, 0, 1]
        return c.count == 2 ? [c[0], c[0], c[0], c[1]] : Array(c.prefix(4))
    }

    private static func color(_ c: [CGFloat]) -> NSColor? {
        guard c.count == 4 else { return nil }
        return NSColor(red: c[0], green: c[1], blue: c[2], alpha: c[3])
    }
}

extension Viewer {
    /// Chooses the style for the next text box, and gives it to the selected one, as one change, grown to hold its words.
    func setTextStyle(_ style: TextStyle) {
        textStyle = style
        textStyle.save()
        guard let box = canvas.selected, box.type == "FreeText", doc.canEdit else { return }
        let old = (font: box.font, color: box.fontColor, fill: box.color, bounds: box.bounds)
        let font = style.font, bounds = fit(box.bounds, around: box.contents ?? "", in: font)
        doc.change("Change Text Style", do: {
            box.font = font
            box.fontColor = style.color
            box.color = style.fill ?? .clear
            box.bounds = bounds
        }, undo: {
            box.font = old.font
            box.fontColor = old.color
            box.color = old.fill
            box.bounds = old.bounds
        })
        canvas.outlineSelection()
    }
}

#if os(macOS)
/// Over the pages: the text style while the text box tool is in use or a text box is selected, and the sizes while a
/// signature, stamp or picture is.
struct FormatBar: View {
    @Bindable var viewer: Viewer

    var body: some View {
        let _ = viewer.doc.revision
        let mark = viewer.mark
        if viewer.tool == .text || mark?.type == "FreeText" {
            textBar
        } else if let mark, mark.keepsProportions {
            HStack(spacing: 10) {
                Text("Size").foregroundStyle(.secondary)
                ForEach(MarkSize.allCases) { size in
                    Button(size.name) { viewer.canvas.setSize(size) }
                }
                Divider().frame(height: 16)
                Text("or drag the corner").foregroundStyle(.secondary).font(.caption)
                Divider().frame(height: 16)
                Button("Add to Every Page", systemImage: "rectangle.portrait.on.rectangle.portrait") { viewer.addToEveryPage() }
                    .disabled(!viewer.canAddToEveryPage)
                Button("Delete", systemImage: "trash", role: .destructive) { viewer.canvas.deleteMark() }
            }
            .controlSize(.small)
            .disabled(!viewer.isIdle)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.regularMaterial, in: .capsule)
            .shadow(radius: 2)
        }
    }

    private var textBar: some View {
        let style = viewer.textStyle
        let set = { (change: (inout TextStyle) -> Void) in
            var new = viewer.textStyle
            change(&new)
            viewer.setTextStyle(new)
        }
        return HStack(spacing: 8) {
            Picker("Font", selection: Binding(get: { style.family }, set: { family in set { $0.family = family } })) {
                ForEach(TextStyle.families + (TextStyle.families.contains(style.family) ? [] : [style.family]), id: \.self) {
                    Text($0).font(.custom($0, size: 13)).tag($0)
                }
            }
            .labelsHidden()
            .frame(width: 150)
            HStack(spacing: 2) {
                TextField("Size", value: Binding(get: { Double(style.size) }, set: { size in set { $0.size = min(max(CGFloat(size), 4), 200) } }),
                          format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 38)
                    .multilineTextAlignment(.trailing)
                Stepper("Size", value: Binding(get: { Double(style.size) }, set: { size in set { $0.size = min(max(CGFloat(size), 4), 200) } }), in: 4...200)
                    .labelsHidden()
                Text(verbatim: "pt").foregroundStyle(.secondary)
            }
            Toggle(isOn: Binding(get: { style.bold }, set: { bold in set { $0.bold = bold } })) { Image(systemName: "bold") }
                .toggleStyle(.button)
                .help("Bold")
            Toggle(isOn: Binding(get: { style.italic }, set: { italic in set { $0.italic = italic } })) { Image(systemName: "italic") }
                .toggleStyle(.button)
                .help("Italic")
            Divider().frame(height: 16)
            ColorPicker("Text Colour", selection: Binding(get: { style.color.cgColor }, set: { color in set { $0.color = NSColor(cgColor: color) ?? .black } }))
            Divider().frame(height: 16)
            Toggle("Background", isOn: Binding(get: { style.fill != nil }, set: { on in set { $0.fill = on ? ($0.fill ?? .white) : nil } }))
            if style.fill != nil {
                ColorPicker("Background", selection: Binding(get: { (style.fill ?? .white).cgColor }, set: { color in set { $0.fill = NSColor(cgColor: color) } }))
                    .labelsHidden()
            }
        }
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .disabled(!viewer.isIdle)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.regularMaterial, in: .capsule)
        .shadow(radius: 2)
    }
}
#endif
