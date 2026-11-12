#if os(macOS)
import Foundation
import PDFKit
import Security

/// Signing a PDF with a certificate in the Keychain, a FINA or IDDEEA card's among them, as Foxit's Sign Document does: a
/// PKCS #7 signature (adbe.pkcs7.detached) over the whole file, added as an update after it, which Acrobat, Foxit and
/// Preview check. Any change saved after it breaks it, so it signs a copy, last.
enum DigitalSignature {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

    /// Room for the signature: the certificate chain makes most of it.
    static let room = 16384

    /// The identities, a certificate with its private key, the Keychain has, by their certificates' names.
    static func identities() -> [(name: String, identity: SecIdentity)] {
        let query: [String: Any] = [kSecClass as String: kSecClassIdentity, kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
        var found: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &found) == errSecSuccess, let list = found as? [SecIdentity] else { return [] }
        return list.compactMap { identity in
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
            return ((SecCertificateCopySubjectSummary(certificate) as String?) ?? "?", identity)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// `pdf`, as PDFKit writes it with an empty signature field, then signed by `identity`.
    static func sign(_ pdf: PDFDocument, identity: SecIdentity, reason: String, name: String) throws -> Data {
        guard let copy = pdf.dataRepresentation().flatMap(PDFDocument.init(data:)), let first = copy.page(at: 0) else {
            throw Failure(String(localized: "Couldn't read the document to sign it"))
        }
        let field = PDFAnnotation(bounds: .zero, forType: .widget, withProperties: nil)
        field.widgetFieldType = .signature
        field.fieldName = "Signature\(Int(Date().timeIntervalSince1970))"
        first.addAnnotation(field)
        guard let base = copy.dataRepresentation() else { throw Failure(String(localized: "Couldn't read the document to sign it")) }
        return try sign(base, fieldName: field.fieldName!, identity: identity, reason: reason, name: name)
    }

    /// Signs `base`, a PDF with an empty signature field named `fieldName` and a plain cross-reference table, by adding an
    /// update after it: the signature, and the field pointing at it.
    static func sign(_ base: Data, fieldName: String, identity: SecIdentity, reason: String, name: String) throws -> Data {
        guard let latin = String(data: base, encoding: .isoLatin1) else { throw Failure(String(localized: "Couldn't find where to put the signature")) }
        // The field's object, found by its name.
        guard let nameAt = latin.range(of: "/T (\(fieldName))") ?? latin.range(of: "/T(\(fieldName))"),
              let objectStart = latin.range(of: #"\d+ 0 obj"#, options: [.regularExpression, .backwards], range: latin.startIndex..<nameAt.lowerBound),
              let objectEnd = latin.range(of: "endobj", range: nameAt.upperBound..<latin.endIndex) else {
            throw Failure(String(localized: "Couldn't find where to put the signature"))
        }
        let header = String(latin[objectStart])
        let number = Int(header.split(separator: " ")[0])!
        var body = String(latin[objectStart.upperBound..<objectEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasSuffix(">>") else { throw Failure(String(localized: "Couldn't find where to put the signature")) }
        // The trailer of the last update, and where its cross-reference table starts.
        guard let trailerAt = latin.range(of: "trailer", options: .backwards),
              let startxref = latin.range(of: "startxref", options: .backwards),
              let previous = Int(latin[startxref.upperBound...].split(whereSeparator: \.isWhitespace).first ?? ""),
              let size = Self.value("/Size", in: String(latin[trailerAt.upperBound...])).flatMap({ Int($0) }),
              let root = Self.reference("/Root", in: String(latin[trailerAt.upperBound...])) else {
            throw Failure(String(localized: "This PDF is saved in a way Folio can't sign yet"))
        }
        let info = Self.reference("/Info", in: String(latin[trailerAt.upperBound...]))
        let signature = size
        body.removeLast(2)
        let field = "\(number) 0 obj\n\(body) /V \(signature) 0 R >>\nendobj\n"
        let date = Self.pdfDate(Date())
        let placeholder = String(repeating: "0", count: room * 2)
        let rangeSlot = "[0 0000000000 0000000000 0000000000]"
        let sig = "\(signature) 0 obj\n<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /Name \(Self.literal(name)) /Reason \(Self.literal(reason)) /M (\(date)) /ByteRange \(rangeSlot) /Contents <\(placeholder)> >>\nendobj\n"
        var update = Data(base)
        if update.last != 0x0A { update.append(0x0A) }
        let fieldOffset = update.count
        update.append(Data(field.utf8))
        let sigOffset = update.count
        update.append(Data(sig.utf8))
        let xrefOffset = update.count
        var xref = "xref\n\(number) 1\n\(String(format: "%010d", fieldOffset)) 00000 n \n\(signature) 1\n\(String(format: "%010d", sigOffset)) 00000 n \n"
        xref += "trailer\n<< /Size \(signature + 1) /Root \(root)\(info.map { " /Info \($0)" } ?? "") /Prev \(previous) >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        update.append(Data(xref.utf8))
        // Where the signature's hex goes, and the byte ranges around it.
        guard let contents = update.range(of: Data("/Contents <".utf8), in: sigOffset..<update.count),
              let rangeAt = update.range(of: Data(rangeSlot.utf8), in: sigOffset..<update.count) else {
            throw Failure(String(localized: "Couldn't find where to put the signature"))
        }
        let holeStart = contents.upperBound - 1, holeEnd = contents.upperBound + room * 2 + 1
        var ranges = "[0 \(holeStart) \(holeEnd) \(update.count - holeEnd)]"
        ranges += String(repeating: " ", count: rangeSlot.count - ranges.count)
        update.replaceSubrange(rangeAt, with: Data(ranges.utf8))
        let signed = update[0..<holeStart] + update[holeEnd..<update.count]
        let cms = try Self.cms(Data(signed), identity: identity)
        guard cms.count <= room else { throw Failure(String(localized: "The certificate's signature is too big")) }
        let hex = cms.map { String(format: "%02X", $0) }.joined() + String(repeating: "0", count: (room - cms.count) * 2)
        update.replaceSubrange(contents.upperBound..<(contents.upperBound + room * 2), with: Data(hex.utf8))
        return update
    }

    /// A detached PKCS #7 signature of `content`, with the signing time and the certificate chain.
    static func cms(_ content: Data, identity: SecIdentity) throws -> Data {
        var encoder: CMSEncoder?
        guard CMSEncoderCreate(&encoder) == errSecSuccess, let encoder else { throw Failure(String(localized: "Couldn't sign")) }
        var status = CMSEncoderAddSigners(encoder, identity)
        if status == errSecSuccess { status = CMSEncoderSetHasDetachedContent(encoder, true) }
        if status == errSecSuccess { status = CMSEncoderAddSignedAttributes(encoder, .attrSigningTime) }
        if status == errSecSuccess { status = CMSEncoderSetCertificateChainMode(encoder, .chainWithRootOrFail) }
        if status != errSecSuccess { status = CMSEncoderSetCertificateChainMode(encoder, .signerOnly) }
        if status == errSecSuccess { status = content.withUnsafeBytes { CMSEncoderUpdateContent(encoder, $0.baseAddress!, content.count) } }
        var out: CFData?
        if status == errSecSuccess { status = CMSEncoderCopyEncodedContent(encoder, &out) }
        guard status == errSecSuccess, let out else {
            throw Failure((SecCopyErrorMessageString(status, nil) as String?) ?? String(localized: "Couldn't sign"))
        }
        // CMSEncoder writes BER, with lengths left open; a PDF's signature is read as DER, every length given.
        var reader = BER(bytes: [UInt8](out as Data))
        guard let der = reader.next() else { throw Failure(String(localized: "Couldn't sign")) }
        return Data(der)
    }

    /// Rewrites BER as definite-length encoding: each element's length given, its contents rewritten the same way.
    struct BER {
        let bytes: [UInt8]
        var at = 0

        /// The next element, rewritten, or nil at its end-of-contents mark or the end.
        mutating func next() -> [UInt8]? {
            guard at + 1 < bytes.count, !(bytes[at] == 0 && bytes[at + 1] == 0) else { at += 2; return nil }
            var tag = [bytes[at]]
            let constructed = bytes[at] & 0x20 != 0
            at += 1
            if tag[0] & 0x1F == 0x1F {   // a tag number in several bytes
                while at < bytes.count, bytes[at] & 0x80 != 0 { tag.append(bytes[at]); at += 1 }
                tag.append(bytes[at]); at += 1
            }
            let first = bytes[at]; at += 1
            var content: [UInt8] = []
            if first == 0x80 {           // open length: elements up to the end-of-contents mark
                while let child = next() { content += child }
            } else {
                var length = Int(first)
                if first & 0x80 != 0 {
                    length = 0
                    for _ in 0..<Int(first & 0x7F) { length = length << 8 | Int(bytes[at]); at += 1 }
                }
                let end = at + length
                if constructed {
                    var inner = BER(bytes: Array(bytes[at..<end]))
                    while inner.at < inner.bytes.count, let child = inner.next() { content += child }
                } else {
                    content = Array(bytes[at..<end])
                }
                at = end
            }
            return tag + Self.length(content.count) + content
        }

        static func length(_ n: Int) -> [UInt8] {
            guard n >= 0x80 else { return [UInt8(n)] }
            var octets: [UInt8] = []
            var rest = n
            while rest > 0 { octets.insert(UInt8(rest & 0xFF), at: 0); rest >>= 8 }
            return [0x80 | UInt8(octets.count)] + octets
        }
    }

    private static func value(_ key: String, in dictionary: String) -> String? {
        guard let at = dictionary.range(of: key) else { return nil }
        return dictionary[at.upperBound...].split(whereSeparator: { $0.isWhitespace || $0 == "/" || $0 == ">" }).first.map(String.init)
    }

    private static func reference(_ key: String, in dictionary: String) -> String? {
        guard let at = dictionary.range(of: key),
              let match = dictionary[at.upperBound...].range(of: #"\s*\d+\s+\d+\s+R"#, options: .regularExpression),
              match.lowerBound == at.upperBound else { return nil }
        return dictionary[match].trimmingCharacters(in: .whitespaces)
    }

    /// Text as a PDF string: in UTF-16 with its mark, so any letter goes in.
    private static func literal(_ text: String) -> String {
        "<FEFF" + text.utf16.map { String(format: "%04X", $0) }.joined() + ">"
    }

    private static func pdfDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMddHHmmss"
        return "D:\(f.string(from: date))Z"
    }
}
#endif

#if os(macOS)
import SwiftUI

/// Protect › Sign with Certificate: choose a certificate from the Keychain, say why, and save a signed copy.
struct DigitalSignatureSheet: View {
    let viewer: Viewer
    let name: String
    @ViewState private var identities: [(name: String, identity: SecIdentity)] = []
    @ViewState private var chosen = 0
    @ViewState private var reason = String(localized: "Approved")
    @ViewState private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign with Certificate").font(.title2.bold())
            Text("Signs a copy of the document with a certificate from your Keychain, such as one on a FINA or IDDEEA card. Any change made to the copy afterwards breaks the signature, so sign last.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if identities.isEmpty {
                Label("No certificate with a private key was found in the Keychain. Insert the card, or add the certificate in Keychain Access.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                Form {
                    Picker("Certificate", selection: $chosen) {
                        ForEach(identities.indices, id: \.self) { Text(identities[$0].name).tag($0) }
                    }
                    TextField("Reason", text: $reason)
                }
                .formStyle(.grouped)
            }
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sign and Save…", action: sign).keyboardShortcut(.defaultAction).disabled(identities.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { identities = DigitalSignature.identities() }
    }

    private func sign() {
        viewer.settle()
        guard viewer.doc.newPassword == nil, !viewer.doc.pdf.isEncrypted else {
            failure = String(localized: "Take the password off before signing: a signed copy can't be protected afterwards.")
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = String(localized: "\(name) signed")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let identity = identities[chosen]
            let data = try DigitalSignature.sign(viewer.doc.writable, identity: identity.identity, reason: reason, name: identity.name)
            try data.write(to: url)
            viewer.message = String(localized: "Signed and saved \(url.lastPathComponent)")
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
#endif
