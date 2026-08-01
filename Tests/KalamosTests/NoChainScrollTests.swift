import Testing
import CoreGraphics
@testable import Kalamos

/// ISC-119 — the word list keeps the wheel to itself.
///
/// One gesture in real use found this: with the pointer over the list, reaching
/// the last row handed the wheel to the Preferences page underneath and the whole
/// window took off. AppKit calls that scroll chaining and does it by design.
///
/// `NoChainScrollView.swallows` is the answer, and it is tested here rather than
/// through the view because an `NSEvent` cannot be built in a test — a scroll
/// event only comes from the window server. What CAN be pinned down is the
/// decision, and the two poles matter equally: swallowing too little brings the
/// bug back, swallowing too much freezes the page under the pointer.
@MainActor
struct NoChainScrollTests {
    /// Six visible rows out of ten. Offsets: 0 at the top, 152 at the bottom.
    private let content: CGFloat = 380
    private let visible: CGFloat = 228
    private var bottom: CGFloat { content - visible }

    private func swallows(offset: CGFloat, dy: CGFloat, dx: CGFloat = 0,
                          content: CGFloat? = nil, visible: CGFloat? = nil) -> Bool {
        NoChainScrollView.swallows(contentHeight: content ?? self.content,
                                   visibleHeight: visible ?? self.visible,
                                   offsetY: offset, deltaY: dy, deltaX: dx)
    }

    // MARK: the bug itself

    @Test func atTheBottomScrollingDownIsSwallowed() {
        #expect(swallows(offset: bottom, dy: -8))
    }

    @Test func atTheTopScrollingUpIsSwallowed() {
        #expect(swallows(offset: 0, dy: 8))
    }

    /// Half a point of slack, because a scroll offset lands on fractions.
    @Test func almostAtTheBottomCountsAsTheBottom() {
        #expect(swallows(offset: bottom - 0.4, dy: -8))
    }

    // MARK: the poles that would make it feel broken

    /// The list must stay escapable. Swallowing this would trap you at the end.
    @Test func atTheBottomScrollingBackUpIsNotSwallowed() {
        #expect(!swallows(offset: bottom, dy: 8))
    }

    @Test func atTheTopScrollingDownIsNotSwallowed() {
        #expect(!swallows(offset: 0, dy: -8))
    }

    @Test func inTheMiddleNothingIsSwallowed() {
        #expect(!swallows(offset: bottom / 2, dy: -8))
        #expect(!swallows(offset: bottom / 2, dy: 8))
    }

    /// A list that needs no scrolling is not a dead zone: the page must still
    /// move under the pointer, at both ends, in both directions.
    @Test func aShortListNeverSwallows() {
        for dy in [-8.0, 8.0] {
            #expect(!swallows(offset: 0, dy: dy, content: 76, visible: 228))
        }
    }

    /// Exactly full is still short: there is nothing to scroll.
    @Test func anExactlyFullListNeverSwallows() {
        #expect(!swallows(offset: 0, dy: -8, content: 228, visible: 228))
    }

    /// A sideways gesture belongs to whatever scrolls horizontally, not to us.
    @Test func aHorizontalGestureIsNeverOurs() {
        #expect(!swallows(offset: bottom, dy: -2, dx: -20))
    }
}
