import CoreGraphics
import Testing
@testable import FleetCore

/// Where the app's menu opens: at the pointer for a right-click, under its control for a list. Screen points, y upward.
struct MenuPlacementTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 200, height: 280)

    @Test func aRightClickOpensTheMenuWithItsTopLeftCornerAtThePointer() {
        let frame = MenuPlacement.atPointer(size, pointer: CGPoint(x: 300, y: 700), screen: screen)
        #expect(frame == CGRect(x: 300, y: 420, width: 200, height: 280))
    }

    @Test func nearTheRightEdgeItOpensToTheLeftOfThePointer() {
        let frame = MenuPlacement.atPointer(size, pointer: CGPoint(x: 1340, y: 700), screen: screen)
        #expect(frame.maxX == 1340)
        #expect(frame.maxY == 700)
    }

    @Test func nearTheBottomItOpensOverThePointer() {
        let frame = MenuPlacement.atPointer(size, pointer: CGPoint(x: 300, y: 100), screen: screen)
        #expect(frame.minY == 100)
        #expect(frame.minX == 300)
    }

    @Test func aMenuTallerThanBothRoomsStaysOnTheScreen() {
        let frame = MenuPlacement.atPointer(CGSize(width: 200, height: 600), pointer: CGPoint(x: 300, y: 450), screen: screen)
        #expect(frame.minY >= MenuPlacement.margin)
        #expect(frame.maxY <= 900 - MenuPlacement.margin)
    }

    @Test func aMenuTallerThanTheScreenKeepsItsFirstRowsOnIt() {
        let frame = MenuPlacement.atPointer(CGSize(width: 200, height: 1000), pointer: CGPoint(x: 300, y: 450), screen: screen)
        #expect(frame.maxY == 900 - MenuPlacement.margin)
    }

    @Test func aListOpensUnderItsControlWithTheirLeftEdgesTogether() {
        let control = CGRect(x: 400, y: 600, width: 120, height: 28)
        let window = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = MenuPlacement.under(size, control: control, window: window, screen: screen, gap: 4)
        #expect(frame == CGRect(x: 400, y: 316, width: 200, height: 280))
    }

    @Test func aListThatWouldPassTheWindowsRightEdgeEndsAtTheControlsRightEdge() {
        // The "…" at the end of a card, 40 points from the window's right edge.
        let control = CGRect(x: 1072, y: 600, width: 28, height: 28)
        let window = CGRect(x: 0, y: 0, width: 1140, height: 900)
        let frame = MenuPlacement.under(size, control: control, window: window, screen: screen, gap: 4)
        #expect(frame.maxX == 1100)
        #expect(frame.maxY == 596)
    }

    @Test func aListWithTooLittleRoomUnderItsControlOpensOverIt() {
        let control = CGRect(x: 400, y: 120, width: 120, height: 28)
        let frame = MenuPlacement.under(size, control: control, window: screen, screen: screen, gap: 4)
        #expect(frame.minY == 152)
    }

    @Test func aListStaysUnderItsControlWhileThatRoomIsTheLarger() {
        // Too little room under it, and less over it: it stays under and moves up to the screen's bottom margin.
        let control = CGRect(x: 400, y: 500, width: 120, height: 28)
        let tall = CGSize(width: 200, height: 600)
        let frame = MenuPlacement.under(tall, control: control, window: screen, screen: screen, gap: 4)
        #expect(frame.minY == MenuPlacement.margin)
        #expect(MenuPlacement.room(control: control, screen: screen, gap: 4) == 492)
    }

    @Test func theRoomOfARightClickIsTheLargerSide() {
        #expect(MenuPlacement.room(pointer: CGPoint(x: 10, y: 700), screen: screen) == 696)
        #expect(MenuPlacement.room(pointer: CGPoint(x: 10, y: 100), screen: screen) == 796)
    }
}
