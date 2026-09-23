import AppKit

// ─────────────────────────────────────────────────────────────────────────────
// THE COIN, AS A REAL DRAG
//
// A chat composer attaches a file that is DROPPED on it. It does not reliably
// attach one that is pasted: measured, Gemini ignores a pasted file entirely,
// and a drop of the same file works on Claude.ai, ChatGPT and Gemini alike.
// Since somebody is already dragging the coin, the honest thing is for that
// gesture to BE a drag — so the browser receives exactly what it would from
// Finder.
//
// STARTED LATE, ON PURPOSE. A system drag delivers to whatever is under the
// cursor, and dropping a `.md` on a terminal running Claude Code types its
// path into the prompt — noise in front of the brief, at the destination that
// already works best. So the session is not begun when the coin is picked up;
// it is begun the first time the coin is over a BROWSER, and never otherwise.
// Everything else keeps the delivery path it has always had.
//
// The event handed to `beginDraggingSession` is synthesised, because the real
// mouse-down was consumed by the coin's own gesture long before we knew where
// the fling was heading. If AppKit declines it, `begin` returns nil and the
// caller is exactly where it was: the paste path, unchanged.
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class CoinDragSource: NSObject, NSDraggingSource {

    /// Where the drag is now, in Cocoa screen coordinates — the aim label and
    /// the target highlight are still ours to draw while AppKit owns the mouse.
    var onMoved: ((NSPoint) -> Void)?
    /// Where it ended, and whether anything took it.
    var onEnded: ((NSPoint, NSDragOperation) -> Void)?

    private(set) var session: NSDraggingSession?

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // `.copy` everywhere, including within Deiko: releasing back over the
        // orb must not read as a move of somebody's persona file.
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, movedTo screenPoint: NSPoint) {
        onMoved?(screenPoint)
    }

    func draggingSession(
        _ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation
    ) {
        self.session = nil
        onEnded?(screenPoint, operation)
    }

    /// True while AppKit owns the mouse, so the coin's own gesture knows to
    /// stay out of the way.
    var isDragging: Bool { session != nil }

    /// Begin the drag, or report that it could not start.
    ///
    /// `image` is the coin as it looks on screen, so the thing that leaves the
    /// card is the thing that lands — a default file icon here would make the
    /// gesture read as "moving a document" rather than "handing this over".
    @discardableResult
    func begin(from view: NSView, file: URL, image: NSImage, at pointInWindow: NSPoint) -> Bool {
        guard let window = view.window else { return false }
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        let size = image.size
        item.setDraggingFrame(
            NSRect(x: pointInWindow.x - size.width / 2, y: pointInWindow.y - size.height / 2,
                   width: size.width, height: size.height),
            contents: image
        )
        guard let event = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else { return false }

        let started = view.beginDraggingSession(with: [item], event: event, source: self)
        session = started
        return true
    }
}
