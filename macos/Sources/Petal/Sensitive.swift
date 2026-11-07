import AppKit
import ApplicationServices
import ScreenCaptureKit

/// What a picture for Petal AI (petal_look's screenshot) must not show: password fields, fields named for a password,
/// token, key, card number or security code, any text holding one of the vault's secrets (or one Petal typed this
/// run), and every field Petal filled with a secret, however it looks now (a revealed password, a card number a
/// page shows unmasked). Found through Accessibility right before and right after the picture is taken, matched
/// element by element (one that moved is covered all the way between; one that appeared, went or moved far means no
/// picture), and blacked out in memory before anything is written; a window that can't be read whole in time isn't
/// in the picture at all.
/// Never on the main thread.
enum Sensitive {
    private static let lock = NSLock()
    /// Fields Petal filled with a secret, kept (in memory only) until Petal quits.
    nonisolated(unsafe) private static var fields: [(pid: pid_t, element: AXUIElement)] = []

    /// Petal is about to fill `element` with a secret.
    static func filled(_ element: AXUIElement, pid: pid_t) {
        lock.lock()
        defer { lock.unlock() }
        guard !fields.contains(where: { $0.pid == pid && CFEqual($0.element, element) }) else { return }
        fields.append((pid, element))
        if fields.count > 500 { fields.removeFirst(fields.count - 500) }
    }

    /// Petal filled `element` with a secret this run.
    static func isFilled(_ element: AXUIElement, pid: pid_t) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return fields.contains { $0.pid == pid && CFEqual($0.element, element) }
    }

    private static func filled(of pid: pid_t) -> [AXUIElement] {
        lock.lock()
        defer { lock.unlock() }
        return fields.filter { $0.pid == pid }.map(\.element)
    }

    struct Scan {
        /// Each part that may show a secret and where, in screen points (top-left origin, as Accessibility gives
        /// them): the element, so a read before the picture and one after can be matched up (`blackouts`).
        var found: [(element: AXUIElement, rect: CGRect)] = []
        /// Read whole in time: only then may the window be in a picture.
        var complete = true
    }

    /// What to black out of a picture taken between `before` and `after` (two reads of one window, `window` its
    /// frame), each part matched to itself by its Accessibility element: covered wherever it was meanwhile, or nil
    /// (no picture) when a part appeared, went or moved too far while the picture was taken (UIMap.blackouts).
    static func blackouts(_ before: Scan, _ after: Scan, window: CGRect) -> [CGRect]? {
        var elements: [AXUIElement] = []
        func id(_ element: AXUIElement) -> Int {
            if let at = elements.firstIndex(where: { CFEqual($0, element) }) { return at }
            elements.append(element)
            return elements.count - 1
        }
        let then = before.found.map { (id: id($0.element), rect: $0.rect) }
        let now = after.found.map { (id: id($0.element), rect: $0.rect) }
        return UIMap.blackouts(before: then, after: now, window: window)
    }

    private static let attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute,
                                     kAXPlaceholderValueAttribute, kAXIdentifierAttribute, kAXPositionAttribute, kAXSizeAttribute]

    /// Every part of `window` that may show a secret within `visible` (the picture's part of the screen), read
    /// before `deadline`. What lies wholly outside the picture isn't walked into.
    static func scan(window: AXUIElement, pid: pid_t, visible: CGRect, deadline: Date) -> Scan {
        let names = attributes as CFArray
        let around = visible.insetBy(dx: -40, dy: -40)
        var scan = Scan()
        let vault = VaultIndex.current()
        // A vault that can't be read can't be searched for: no window is checked whole.
        guard !vault.unreadable else { scan.complete = false; return scan }
        let mine = filled(of: pid)
        // Each element read: its parent (by when it was read) and its place among that parent's children.
        var stack: [(element: AXUIElement, depth: Int, parent: Int, order: Int)] = [(window, 0, -1, 0)]
        var visited = 0
        // Every element read, by id (only one actually read gets one), its frame and its parent, and the text each
        // shows in the picture: a part with no bounds of its own is covered by the nearest around it that has some
        // (UIMap.cover), and a secret split over several pieces (a card number in fours) is looked for in them.
        var parts = UIMap.ScanParts<AXUIElement>()
        /// Covers the part read as `id`: by its own frame, else its nearest ancestor's; false when none has one.
        func cover(_ id: Int) -> Bool {
            guard let (element, frame) = parts.cover(id) else { return false }
            scan.found.append((element, frame.insetBy(dx: -4, dy: -4)))
            return true
        }
        while let (element, depth, parent, order) = stack.popLast() {
            guard visited < 40_000, Date() < deadline else { scan.complete = false; return scan }
            visited += 1
            var raw: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
            guard error == .success, let list = raw as? [AnyObject] else {
                // The window itself, or an app too busy to answer or failing: not read whole. An element gone
                // meanwhile: skipped (nothing of it shows any more).
                if depth == 0 || UIMap.childRead(error: error.rawValue, count: 0) != .gone { scan.complete = false; return scan }
                continue
            }
            var values: [String: Any] = [:]
            for (name, value) in zip(attributes, list) {
                if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { continue }
                values[name] = value
            }
            let role = values[kAXRoleAttribute] as? String ?? ""
            var node = UINode(role: role)
            node.subrole = values[kAXSubroleAttribute] as? String ?? ""
            node.title = values[kAXTitleAttribute] as? String ?? ""
            node.label = values[kAXDescriptionAttribute] as? String ?? ""
            node.help = values[kAXHelpAttribute] as? String ?? ""
            node.placeholder = values[kAXPlaceholderValueAttribute] as? String ?? ""
            node.identifier = values[kAXIdentifierAttribute] as? String ?? ""
            let frame = Reader.frame(values[kAXPositionAttribute], values[kAXSizeAttribute])
            let me = parts.read(element, frame: frame, parent: parent)
            let placed = frame.width > 0 && frame.height > 0
            // A password field's value is never read; anything else's is searched whole.
            let secure = UIMap.isSecure(node)
            let value = secure ? "" : Reader.text(Windows.value(element, kAXValueAttribute) as CFTypeRef?, whole: true)
            // Named for a secret only counts for a field one types into: a window or page called "API keys" isn't
            // blacked out whole (its text is still searched below).
            let secret = secure || UIMap.looksSecretField(node) || mine.contains { CFEqual($0, element) }
                || [node.title, node.label, node.help, node.placeholder, value].contains { !$0.isEmpty && vault.matches($0) }
            // Every text shown counts as a piece, one holding part of a secret by itself too: the rest of that secret
            // in the pieces beside it is found only with it (an Amex number as 37828224 and 6310005). One with no
            // bounds may be in the picture: it counts, covered by what's around it if need be.
            let shown = [value, node.title, node.label].first { !$0.isEmpty } ?? ""
            if !secure, !shown.isEmpty, !placed || frame.intersects(around) { parts.shows(shown, id: me, order: order) }
            // A part that may show a secret with no bounds of its own (an attribute that failed, or a zero size):
            // what holds it is covered, else the window isn't read whole.
            if secret, !cover(me) { scan.complete = false; return scan }
            // Far down a page or scrolled away: not in the picture.
            if depth > 0, placed, !frame.intersects(around) { continue }
            // A list's rows showing (what's scrolled away isn't in the picture), else every child. Children that
            // couldn't be read, or that lie deeper than the scan goes, leave the window not read whole.
            let names = Reader.listRoles.contains(role) ? ["AXVisibleRows", "AXVisibleChildren", kAXChildrenAttribute] : [kAXChildrenAttribute]
            let (read, children) = Self.children(element, names)
            guard UIMap.covered(read, depth: depth, maxDepth: Self.maxDepth) else { scan.complete = false; return scan }
            // A page that shows nothing of itself to Accessibility can't be checked.
            if role == "AXWebArea", children.isEmpty, frame.width > 40, frame.height > 40 { scan.complete = false; return scan }
            for (index, child) in children.enumerated().reversed() { stack.append((child, depth + 1, me, index)) }
        }
        // A secret only the pieces show together: every piece of it is covered.
        guard let joined = parts.joined(matches: vault.matches, going: { Date() < deadline }) else {
            scan.complete = false
            return scan
        }
        for id in joined where !cover(id) { scan.complete = false; return scan }
        return scan
    }

    static let maxDepth = 80

    /// An element's children by the first of `names` it has, with what reading them said (an error kept, never
    /// taken for "none").
    static func children(_ element: AXUIElement, _ names: [String]) -> (UIMap.ChildRead, [AXUIElement]) {
        for name in names {
            var raw: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &raw)
            let list = error == .success ? (raw as? [AXUIElement]) : nil
            if error == .success, raw != nil, list == nil { return (.unreadable, []) }   // not a list of elements
            let read = UIMap.childRead(error: error.rawValue, count: list?.count ?? 0)
            switch read {
            case .none: continue
            case .children: return (read, list ?? [])
            case .gone, .unreadable: return (read, [])
            }
        }
        return (.none, [])
    }

    /// The Accessibility window of `pid` with this window server id.
    static func window(pid: pid_t, id: CGWindowID) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        let all: [AXUIElement] = Windows.value(app, kAXWindowsAttribute) ?? []
        return all.first { Windows.id(of: $0) == id }
    }

    /// `image` (of what's at `origin` on the screen, `scale` pixels a point) with every rect painted black, drawn
    /// in memory; nil when it can't be drawn (then there's no picture).
    static func blackOut(_ image: CGImage, _ rects: [CGRect], origin: CGPoint, scale: CGFloat) -> CGImage? {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for rect in rects {
            let top = (rect.minY - origin.y) * scale
            context.fill(CGRect(x: (rect.minX - origin.x) * scale, y: CGFloat(height) - top - rect.height * scale,
                                width: rect.width * scale, height: rect.height * scale))
        }
        return context.makeImage()
    }
}
