import AppKit
import ApplicationServices
import ScreenCaptureKit

/// What a picture for Petal AI (petal_look's screenshot) must not show: password fields, fields named for a password,
/// token, key, card number or security code, any text holding one of the vault's secrets (or one Petal typed this
/// run), and every field Petal filled with a secret, however it looks now (a revealed password, a card number a
/// page shows unmasked). Found through Accessibility right before and right after the picture is taken, and blacked
/// out in memory before anything is written; a window that can't be read whole in time isn't in the picture at all.
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

    private static func filled(of pid: pid_t) -> [AXUIElement] {
        lock.lock()
        defer { lock.unlock() }
        return fields.filter { $0.pid == pid }.map(\.element)
    }

    struct Scan {
        /// Where secrets may show, in screen points (top-left origin, as Accessibility gives them).
        var rects: [CGRect] = []
        /// Read whole in time: only then may the window be in a picture.
        var complete = true
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
        let mine = filled(of: pid)
        var stack: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var visited = 0
        while let (element, depth) = stack.popLast() {
            guard visited < 40_000, Date() < deadline else { scan.complete = false; return scan }
            visited += 1
            var raw: CFArray?
            let error = AXUIElementCopyMultipleAttributeValues(element, names, AXCopyMultipleAttributeOptions(rawValue: 0), &raw)
            guard error == .success, let list = raw as? [AnyObject] else {
                // The window itself, or an app too busy to answer: not read whole. An element gone meanwhile: skipped.
                if depth == 0 || error == .cannotComplete { scan.complete = false; return scan }
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
            var secret = UIMap.isSecure(node) || UIMap.looksSecret(node) || mine.contains { CFEqual($0, element) }
            if !secret {
                // A password field's value is never read; anything else's is searched whole.
                let value = Reader.text(Windows.value(element, kAXValueAttribute) as CFTypeRef?, whole: true)
                secret = [node.title, node.label, node.help, node.placeholder, value].contains { !$0.isEmpty && vault.matches($0) }
            }
            if secret, frame.width > 0, frame.height > 0 { scan.rects.append(frame.insetBy(dx: -4, dy: -4)) }
            // Far down a page or scrolled away: not in the picture.
            if depth > 0, frame.width > 0, frame.height > 0, !frame.intersects(around) { continue }
            guard depth < 80 else { continue }
            let children: [AXUIElement]
            if Reader.listRoles.contains(role) {
                children = Windows.value(element, "AXVisibleRows") ?? Windows.value(element, "AXVisibleChildren") ?? Windows.value(element, kAXChildrenAttribute) ?? []
            } else {
                children = Windows.value(element, kAXChildrenAttribute) ?? []
            }
            // A page that shows nothing of itself to Accessibility can't be checked.
            if role == "AXWebArea", children.isEmpty, frame.width > 40, frame.height > 40 { scan.complete = false; return scan }
            for child in children.reversed() { stack.append((child, depth + 1)) }
        }
        return scan
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
