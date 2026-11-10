import AppKit
import CoreText

/// The documents `Petal --viewer-check` loads when it's given none, made by the check itself in a throwaway folder
/// of its own: a two-page PDF whose first page has the words its steps look for, a Word document (AppKit's own
/// writer) and a three-slide PowerPoint deck (the few parts a deck needs, zipped here). Every word is made up.
enum ViewerSamples {
    /// The PDF's first page: "A sample report" (its first fifteen characters are what the comments step quotes),
    /// then the sentence the window step selects and cuts ("Growth held steady" before " through the second half.").
    static let firstPage = ["A sample report",
                            "Growth held steady through the second half.",
                            "Costs fell a little, and the team stayed the same size.",
                            "Every word here is made up for Petal's viewer check."]
    static let secondPage = ["What comes next", "Two more quarters like the last one, with nothing new to buy."]
    static let slides = [("Quarterly plan", "A made-up deck for Petal's viewer check"),
                         ("What changed", "Three things, each said briefly"),
                         ("Next steps", "Who does what, and by when")]

    /// The three samples in `folder` (made if it isn't there): nil when one couldn't be made, said by name.
    static func make(in folder: URL) -> (pdf: URL, document: URL, deck: URL)? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let made = (pdf: folder.appending(path: "Sample report.pdf"), document: folder.appending(path: "Sample letter.docx"),
                    deck: folder.appending(path: "Sample deck.pptx"))
        guard pdf([firstPage, secondPage], to: made.pdf) else { print("samples: the PDF couldn't be made"); return nil }
        guard docx(to: made.document) else { print("samples: the Word document couldn't be made"); return nil }
        guard pptx(to: made.deck) else { print("samples: the deck couldn't be made"); return nil }
        return made
    }

    /// A PDF with a page per list of lines, drawn as text (Core Text), so PDFKit finds its words and lines.
    static func pdf(_ pages: [[String]], to url: URL) -> Bool {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        for lines in pages {
            context.beginPDFPage(nil)
            for (index, line) in lines.enumerated() {
                let font = CTFontCreateWithName("Helvetica" as CFString, index == 0 ? 22 : 13, nil)
                context.textPosition = CGPoint(x: 72, y: 700 - CGFloat(index) * 28)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: font])), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// A Word document through AppKit's own Office Open XML writer.
    static func docx(to url: URL) -> Bool {
        let text = NSMutableAttributedString(string: "A sample letter\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
        text.append(NSAttributedString(string: "This letter is made up for Petal's viewer check.\nIt has three short paragraphs.\nThis is the last of them.\n",
                                       attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        guard let data = try? text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// A PowerPoint deck: a slide per entry of `slides` (a title and a line), with the one master, layout and theme a
    /// deck must have. Quick Look previews it as slides.
    static func pptx(to url: URL) -> Bool {
        let spaces = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" "
            + "xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
        let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let kind = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        let content = "application/vnd.openxmlformats-officedocument."
        func relationships(_ items: [(String, String)]) -> String {
            head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + items.enumerated().map { "<Relationship Id=\"rId\($0.offset + 1)\" Type=\"\(kind)\($0.element.0)\" Target=\"\($0.element.1)\"/>" }.joined()
                + "</Relationships>"
        }
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let tree = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/>"
            + "<a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
        func box(_ id: Int, _ name: String, y: Int, height: Int, size: Int, _ text: String) -> String {
            "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"838200\" y=\"\(y)\"/>"
                + "<a:ext cx=\"10515600\" cy=\"\(height)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr wrap=\"square\"/><a:lstStyle/>"
                + "<a:p><a:r><a:rPr lang=\"en-US\" sz=\"\(size)\"/><a:t>\(escaped(text))</a:t></a:r></a:p></p:txBody></p:sp>"
        }
        let numbers = Array(1...slides.count)
        var files: [(String, String)] = []
        files.append(("[Content_Types].xml", head + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"\(content)presentationml.presentation.main+xml\"/>"
            + "<Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"\(content)presentationml.slideMaster+xml\"/>"
            + "<Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"\(content)presentationml.slideLayout+xml\"/>"
            + "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"\(content)theme+xml\"/>"
            + numbers.map { "<Override PartName=\"/ppt/slides/slide\($0).xml\" ContentType=\"\(content)presentationml.slide+xml\"/>" }.joined() + "</Types>"))
        files.append(("_rels/.rels", relationships([("officeDocument", "ppt/presentation.xml")])))
        files.append(("ppt/presentation.xml", head + "<p:presentation \(spaces)><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"rId1\"/></p:sldMasterIdLst><p:sldIdLst>"
            + numbers.map { "<p:sldId id=\"\(255 + $0)\" r:id=\"rId\($0 + 2)\"/>" }.joined()
            + "</p:sldIdLst><p:sldSz cx=\"12192000\" cy=\"6858000\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>"))
        files.append(("ppt/_rels/presentation.xml.rels",
                      relationships([("slideMaster", "slideMasters/slideMaster1.xml"), ("theme", "theme/theme1.xml")] + numbers.map { ("slide", "slides/slide\($0).xml") })))
        files.append(("ppt/slideMasters/slideMaster1.xml", head + "<p:sldMaster \(spaces)><p:cSld><p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg>"
            + "<p:spTree>\(tree)</p:spTree></p:cSld><p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" "
            + "accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>"
            + "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/></p:sldLayoutIdLst></p:sldMaster>"))
        files.append(("ppt/slideMasters/_rels/slideMaster1.xml.rels", relationships([("slideLayout", "../slideLayouts/slideLayout1.xml"), ("theme", "../theme/theme1.xml")])))
        files.append(("ppt/slideLayouts/slideLayout1.xml", head + "<p:sldLayout \(spaces) type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree>\(tree)</p:spTree></p:cSld>"
            + "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"))
        files.append(("ppt/slideLayouts/_rels/slideLayout1.xml.rels", relationships([("slideMaster", "../slideMasters/slideMaster1.xml")])))
        let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
        let line = "<a:ln w=\"9525\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln>"
        let effect = "<a:effectStyle><a:effectLst/></a:effectStyle>"
        let colors = [("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "44546A"), ("lt2", "E7E6E6"), ("accent1", "4472C4"), ("accent2", "ED7D31"), ("accent3", "A5A5A5"),
                      ("accent4", "FFC000"), ("accent5", "5B9BD5"), ("accent6", "70AD47"), ("hlink", "0563C1"), ("folHlink", "954F72")]
            .map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()
        let font = "<a:latin typeface=\"Helvetica\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/>"
        files.append(("ppt/theme/theme1.xml", head + "<a:theme xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" name=\"Plain\"><a:themeElements>"
            + "<a:clrScheme name=\"Plain\">\(colors)</a:clrScheme><a:fontScheme name=\"Plain\"><a:majorFont>\(font)</a:majorFont><a:minorFont>\(font)</a:minorFont></a:fontScheme>"
            + "<a:fmtScheme name=\"Plain\"><a:fillStyleLst>\(fill)\(fill)\(fill)</a:fillStyleLst><a:lnStyleLst>\(line)\(line)\(line)</a:lnStyleLst>"
            + "<a:effectStyleLst>\(effect)\(effect)\(effect)</a:effectStyleLst><a:bgFillStyleLst>\(fill)\(fill)\(fill)</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>"))
        for (index, slide) in slides.enumerated() {
            let title = box(2, "Title", y: 365125, height: 1325563, size: 4000, slide.0)
            let body = box(3, "Body", y: 1825625, height: 4351338, size: 2400, slide.1)
            let xml: String = head + "<p:sld \(spaces)><p:cSld><p:spTree>" + tree + title + body + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
            files.append(("ppt/slides/slide\(index + 1).xml", xml))
            files.append(("ppt/slides/_rels/slide\(index + 1).xml.rels", relationships([("slideLayout", "../slideLayouts/slideLayout1.xml")])))
        }
        let parts: [(name: String, data: Data)] = files.map { (name: $0.0, data: Data($0.1.utf8)) }
        return (try? archive(parts).write(to: url)) != nil
    }

    /// A zip archive of `files`, each stored as it is (no compression): all a deck's parts need.
    static func archive(_ files: [(name: String, data: Data)]) -> Data {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var value = UInt32(index)
            for _ in 0..<8 { value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
            table[index] = value
        }
        func checksum(_ data: Data) -> UInt32 {
            var value: UInt32 = 0xFFFF_FFFF
            for byte in data { value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8) }
            return value ^ 0xFFFF_FFFF
        }
        func bytes<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
        var archive = Data()
        var directory = Data()
        for file in files {
            let name = Data(file.name.utf8)
            let offset = UInt32(archive.count), size = UInt32(file.data.count), sum = checksum(file.data)
            // Version 2.0, no flags, stored, no time or date (1980-01-01), then the sums and lengths.
            var common = Data()
            for field in [UInt16(20), 0, 0, 0, 0x21] { common += bytes(field) }
            for field in [sum, size, size] { common += bytes(field) }
            for field in [UInt16(name.count), 0] { common += bytes(field) }
            archive += bytes(UInt32(0x0403_4B50))
            archive += common
            archive += name
            archive += file.data
            // The directory's entry: made by 2.0, the same fields, no comment, disk 0, no attributes, where it starts.
            directory += bytes(UInt32(0x0201_4B50))
            directory += bytes(UInt16(20))
            directory += common
            for field in [UInt16(0), 0, 0] { directory += bytes(field) }
            directory += bytes(UInt32(0))
            directory += bytes(offset)
            directory += name
        }
        let start = UInt32(archive.count)
        archive += directory
        archive += bytes(UInt32(0x0605_4B50))
        for field in [UInt16(0), 0, UInt16(files.count), UInt16(files.count)] { archive += bytes(field) }
        archive += bytes(UInt32(directory.count))
        archive += bytes(start)
        archive += bytes(UInt16(0))
        return archive
    }
}
