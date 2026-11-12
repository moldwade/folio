#if os(macOS)
import PDFKit
import SwiftUI

/// A ribbon button for the signature, initials or stamp tool: it opens the list of those saved, to choose the one to place
/// and the size it goes on at, or to add another.
struct SignatureButton: View {
    @Bindable var viewer: Viewer
    let tool: Tool
    @ViewState private var showing = false

    var body: some View {
        Button { showing = true } label: { Label(tool.name, systemImage: tool.symbol) }
            .buttonStyle(RibbonButtonStyle(picked: viewer.tool == tool))
            .help("\(tool.name) (\(tool.key.uppercased()))")
            .disabled(!viewer.isIdle)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                SignatureList(viewer: viewer, tool: tool) { showing = false }
            }
    }
}

/// The signatures, initials or stamps saved for a tool, as pictures: a click chooses one and picks the tool, to place it
/// with a click on the page; each can be deleted. Under them, the size a click places it at, and New… to add another.
struct SignatureList: View {
    let viewer: Viewer
    let tool: Tool
    let close: () -> Void
    @ViewState private var list: [Signature] = []
    @ViewState private var chosen = 0
    @ViewState private var size = MarkSize.current

    var body: some View {
        let tile = CGSize(width: 140, height: tool == .stamp ? 100 : 56)
        VStack(alignment: .leading, spacing: 12) {
            Text(tool == .sign ? "Signatures" : tool == .initial ? "Initials" : "Stamps").font(.headline)
            if list.isEmpty {
                Text("None saved yet. Add one with New….").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.fixed(tile.width + 8)), GridItem(.fixed(tile.width + 8))], spacing: 8) {
                        ForEach(Array(list.enumerated()), id: \.offset) { index, signature in
                            Button { choose(index) } label: {
                                Image(nsImage: signature.image(fitting: tile))
                                    .frame(width: tile.width, height: tile.height)
                                    .background(.white, in: .rect(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6)
                                        .stroke(index == chosen ? Color.accentColor : Color.gray.opacity(0.4), lineWidth: index == chosen ? 2.5 : 1))
                            }
                            .buttonStyle(.plain)
                            .overlay(alignment: .topTrailing) {
                                Button { forget(index) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .gray)
                                }
                                .buttonStyle(.plain)
                                .help("Delete")
                                .padding(3)
                            }
                            .contextMenu { Button("Delete", role: .destructive) { forget(index) } }
                        }
                    }
                }
                // A scroll view has no height of its own in a popover: as tall as its rows, up to three.
                .frame(height: CGFloat(min((list.count + 1) / 2, 3)) * (tile.height + 8))
            }
            HStack {
                Text("Size")
                Picker("Size", selection: $size) {
                    ForEach(MarkSize.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack {
                Button("New…", systemImage: "plus") {
                    close()
                    viewer.sheet = .signature(tool)
                }
                Spacer()
                if !list.isEmpty { Text("Choose one, then click on the page").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(16)
        .frame(width: 340)
        .onAppear(perform: reload)
        .onChange(of: size) { MarkSize.current = size }
    }

    private func reload() {
        list = Signature.saved(tool)
        chosen = min(Signature.chosen(tool), max(list.count - 1, 0))
    }

    private func choose(_ index: Int) {
        Signature.choose(index, for: tool)
        close()
        viewer.pick(tool)
    }

    private func forget(_ index: Int) {
        Signature.forget(index, for: tool)
        reload()
        if list.isEmpty, viewer.tool == tool { viewer.tool = Tool.browsing }
    }
}
#endif
