import XCTest
@testable import Kinetic

/// R4 BUG-G1：卡片起点的长按 / 显示器拖动与空白起点的框选互斥，归属在按下时锁定。
final class ContentGestureOwnershipTests: XCTestCase {
    private let card = CGRect(x: 100, y: 100, width: 180, height: 230)
    private let neighbour = CGRect(x: 302, y: 100, width: 180, height: 230)
    private let searchField = CGRect(x: 100, y: 20, width: 500, height: 28)

    private func resolve(_ point: CGPoint) -> ContentPointerOwner {
        ContentPointerOwner.resolve(point, cardFrames: [card, neighbour], controlFrames: [searchField])
    }

    func testTheStartDecidesTheOwner() {
        XCTAssertEqual(resolve(CGPoint(x: 150, y: 150)), .card, "Poster")
        XCTAssertEqual(resolve(CGPoint(x: 270, y: 320)), .card, "Badge / caption inside the card")
        XCTAssertEqual(resolve(CGPoint(x: 291, y: 200)), .blank, "Gap between cards")
        XCTAssertEqual(resolve(CGPoint(x: 120, y: 30)), .control, "Search field")
        XCTAssertEqual(resolve(CGPoint(x: 700, y: 600)), .blank)
    }

    func testACardOriginNeverBecomesAMarqueeWhileDraggingAcrossGapsAndBlankSpace() {
        var gesture = ContentPointerGesture()
        let start = CGPoint(x: 150, y: 150)
        XCTAssertEqual(gesture.owner(startingAt: start, resolve: { resolve(start) }), .card)
        // 拖动途中经过空白与卡片间隙：归属不重新计算。
        for location in [CGPoint(x: 291, y: 200), CGPoint(x: 700, y: 600), CGPoint(x: 900, y: 10)] {
            let owner = gesture.owner(startingAt: start, resolve: { resolve(location) })
            XCTAssertEqual(owner, .card)
            XCTAssertFalse(ContentPointerGesture.allowsMarquee(owner: owner, translation: CGSize(width: location.x - start.x, height: location.y - start.y),
                                                               displayDragActive: false))
        }
        XCTAssertFalse(ContentPointerGesture.isBlankClick(owner: .card, translation: .zero),
                       "Releasing a card press never clears the selection")
    }

    func testDisplayDragExcludesMarqueeAndBlankOriginStaysAMarquee() {
        XCTAssertFalse(ContentPointerGesture.allowsMarquee(owner: .blank, translation: CGSize(width: 80, height: 40), displayDragActive: true))
        XCTAssertTrue(ContentPointerGesture.allowsMarquee(owner: .blank, translation: CGSize(width: 80, height: 40), displayDragActive: false))
        XCTAssertFalse(ContentPointerGesture.allowsMarquee(owner: .blank, translation: CGSize(width: 3, height: 2), displayDragActive: false),
                       "Below the click tolerance it is a click")
        XCTAssertTrue(ContentPointerGesture.isBlankClick(owner: .blank, translation: CGSize(width: 3, height: 2)))
        XCTAssertFalse(ContentPointerGesture.allowsMarquee(owner: .control, translation: CGSize(width: 80, height: 0), displayDragActive: false))

        // 空白起点的框选移动进入卡片区域：仍是框选，不会变成显示器拖动。
        var gesture = ContentPointerGesture()
        let start = CGPoint(x: 700, y: 600)
        XCTAssertEqual(gesture.owner(startingAt: start, resolve: { resolve(start) }), .blank)
        XCTAssertEqual(gesture.owner(startingAt: start, resolve: { resolve(CGPoint(x: 150, y: 150)) }), .blank)
    }

    func testANewPressIsResolvedAgainEvenIfTheSystemCancelledThePreviousOne() {
        var gesture = ContentPointerGesture()
        let cardStart = CGPoint(x: 150, y: 150)
        _ = gesture.owner(startingAt: cardStart, resolve: { resolve(cardStart) })
        // 没有收到 onEnded（系统取消），下一次按下在空白处。
        let blankStart = CGPoint(x: 700, y: 600)
        XCTAssertEqual(gesture.owner(startingAt: blankStart, resolve: { resolve(blankStart) }), .blank)
        gesture.end()
        XCTAssertNil(gesture.owner)
        XCTAssertNil(gesture.start)
    }
}
