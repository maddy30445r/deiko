import AppKit

/// Turns the coin into a real system drag, so a browser receives the file exactly as it would from Finder.
/// Chat composers attach a dropped file more reliably than a pasted one.
///
/// The session begins only once the coin is over a browser, never on pickup: a `.md` dropped on a
/// terminal would type its path into the prompt. Elsewhere the paste path applies. The event passed to
/// `beginDraggingSession` is synthesised because the coin's own gesture consumed the real mouse-down;
/// if AppKit declines it, `begin` returns false.
@MainActor
final class CoinDragSource: NSObject, NSDraggingSource {

    /// Where the drag is now, in Cocoa screen coordinates. The aim label and target highlight
    /// are still drawn by us while AppKit owns the mouse.
    var onMoved: ((NSPoint) -> Void)?
    /// Where it ended, and whether anything took it.
    var onEnded: ((NSPoint, NSDragOperation) -> Void)?

    private(set) var session: NSDraggingSession?

    func draggingSession(
        _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        // `.copy` everywhere, including within Deiko, so releasing over the orb never reads as a move.
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

    /// Begin the drag, or return false if it could not start.
    ///
    /// `image` is the coin as drawn, so what leaves the card is what lands.
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
