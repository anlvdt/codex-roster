import CoreGraphics
import Testing
@testable import CodexRoster

@Test func physicalClearanceHugsCameraWithFourteenPointInset() {
    let notched = NotchGeometry(
        cameraWidth: 185,
        inset: 37,
        centerX: 720,
        screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        backingScaleFactor: 2
    )
    #expect(notched.hasNotch)
    #expect(notched.physicalClearance == 171) // 185 - 14
    #expect(notched.cameraWidth == 185) // expanded popup keeps raw width

    let tight = NotchGeometry(
        cameraWidth: 175,
        inset: 37,
        centerX: 720,
        screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        backingScaleFactor: 2
    )
    #expect(tight.physicalClearance == 170) // floor

    let nonNotch = NotchGeometry(
        cameraWidth: 0,
        inset: 0,
        centerX: 960,
        screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        backingScaleFactor: 2
    )
    #expect(!nonNotch.hasNotch)
    #expect(nonNotch.physicalClearance == 0)
}

@Test func notchWindowFrameNudgesTopAboveScreenMaxY() {
    let geometry = NotchGeometry(
        cameraWidth: 180,
        inset: 37,
        centerX: 720.25,
        screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        backingScaleFactor: 2
    )
    let frame = geometry.windowFrame(width: 486.3, height: 37)
    let scale = geometry.backingScaleFactor
    let overscan = 1 / scale
    let h = NotchGeometry.align(37, scale: scale)
    // One physical pixel above the display; height unchanged.
    #expect(frame.height == h)
    #expect(frame.maxY == geometry.screenFrame.maxY + overscan)
    #expect(frame.minY == geometry.screenFrame.maxY - h + overscan)
    #expect(NotchGeometry.align(frame.minX, scale: scale) == frame.minX)
    let expectedMid = NotchGeometry.align(geometry.centerX, scale: scale)
    #expect(abs(frame.midX - expectedMid) < 0.6)
}

@Test func nonNotchWindowFrameStaysFlushWithoutOverscan() {
    let geometry = NotchGeometry(
        cameraWidth: 0,
        inset: 0,
        centerX: 960,
        screenFrame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        backingScaleFactor: 2
    )
    let frame = geometry.windowFrame(width: 270, height: 32)
    #expect(frame.maxY == geometry.screenFrame.maxY)
    #expect(frame.height == 32)
    #expect(frame.minY == geometry.screenFrame.maxY - 32)
}

@Test func windowFrameTopIsNotReRoundedIndependently() {
    // Guard: top must equal align(maxY) + overscan, not align(maxY - h) + h.
    let geometry = NotchGeometry(
        cameraWidth: 200,
        inset: 38,
        centerX: 800,
        screenFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000.25),
        backingScaleFactor: 2
    )
    let frame = geometry.windowFrame(width: 400, height: 38)
    let scale = geometry.backingScaleFactor
    let topFlush = NotchGeometry.align(geometry.screenFrame.maxY, scale: scale)
    let overscan = 1 / scale
    #expect(frame.maxY == topFlush + overscan)
}

@Test func expandedRosterCountsPlanSectionHeadersInHeight() {
    let sections = [5, 5, 5, 5]
    #expect(NotchRosterLayout.columnCount(sectionCounts: sections, expanded: true) == 2)
    #expect(NotchRosterLayout.needsRosterScroll(sectionCounts: sections, expanded: true, maximumHeight: 530))
    let height = NotchRosterLayout.rosterGridHeight(sectionCounts: sections, expanded: true, maximumHeight: 530)
    #expect(height <= 530)
    let smallHeight = NotchRosterLayout.rosterGridHeight(sectionCounts: [2, 2], expanded: true)
    #expect(smallHeight == 2 * NotchRosterLayout.rowHeight + NotchRosterLayout.sectionHeaderHeight
        + 2 * NotchRosterLayout.rowSpacing + NotchRosterLayout.gridVerticalPadding)
}

@Test func collapsedRosterKeepsFixedScrollViewport() {
    let sections = [5, 5, 5, 5]
    #expect(NotchRosterLayout.needsRosterScroll(sectionCounts: sections, expanded: false))
    #expect(
        NotchRosterLayout.rosterGridHeight(sectionCounts: sections, expanded: false)
            == NotchRosterLayout.collapsedRosterHeight
    )
    #expect(NotchRosterLayout.columnCount(sectionCounts: sections, expanded: false) == 2)
}

@Test func singlePlanBandSkipsHeadersAndFitsPreferredColumns() {
    let sections = [10]
    #expect(NotchRosterLayout.contentRowCount(sectionCounts: sections, columns: 2) == 5)
    // Larger rosters retain two readable columns.
    #expect(NotchRosterLayout.preferredColumnCount(sectionCounts: sections) == 2)
    #expect(NotchRosterLayout.columnCount(sectionCounts: sections, expanded: true) == 2)
    #expect(NotchRosterLayout.contentRowCount(sectionCounts: sections, columns: 3) == 4)
    #expect(!NotchRosterLayout.needsRosterScroll(sectionCounts: sections, expanded: true))
}

@Test func smallRosterStaysTwoColumnsWhenExpanded() {
    let sections = [3, 2]
    #expect(NotchRosterLayout.preferredColumnCount(sectionCounts: sections) == 2)
    #expect(NotchRosterLayout.columnCount(sectionCounts: sections, expanded: true) == 2)
    #expect(!NotchRosterLayout.needsRosterScroll(sectionCounts: sections, expanded: true))
}

@Test func comfortableWidthCapsColumnsBeforeCrush() {
    // Two wide columns preserve room for identity, quota, and actions.
    #expect(NotchRosterLayout.maxColumnsForComfortableWidth() == 2)
}

@Test func rosterColumnsPreserveEveryAccountInReadingOrder() {
    for count in 0...80 {
        for columns in 1...4 {
            let ranges = NotchRosterLayout.columnRanges(accountCount: count, columns: columns)
            #expect(ranges.flatMap { Array($0) } == Array(0..<count))
            #expect(ranges.count == columns)
        }
    }
    #expect(NotchRosterLayout.columnRanges(accountCount: 15, columns: 3) == [0..<5, 5..<10, 10..<15])
    #expect(NotchRosterLayout.columnSectionCounts(sectionCounts: [5, 3, 7], columns: 3) == [[5], [3, 2], [5]])
    #expect(NotchRosterLayout.contentRowCount(sectionCounts: [5, 3, 7], columns: 3) == 7)
}

@Test func expandedRosterFitsAllRowsUntilScreenLimit() {
    let sections = [3, 5, 7]
    let full = NotchRosterLayout.rosterGridHeight(sectionCounts: sections, expanded: true, maximumHeight: 1000)
    #expect(full > 530)
    #expect(full < 1000)
    #expect(!NotchRosterLayout.needsRosterScroll(sectionCounts: sections, expanded: true, maximumHeight: full))
    #expect(NotchRosterLayout.needsRosterScroll(sectionCounts: sections, expanded: true, maximumHeight: full - 1))
    #expect(NotchRosterLayout.rosterGridHeight(sectionCounts: sections, expanded: true, maximumHeight: 600) == 600)
    #expect(NotchRosterLayout.rosterGridHeight(sectionCounts: [100], expanded: true, maximumHeight: 900) == 900)
}

@Test func captionReservesItsHeightAndAdditionalGap() {
    let plain = NotchRosterLayout.deckHeight(sectionCounts: [3, 2], expanded: true)
    let caption = NotchRosterLayout.deckHeight(sectionCounts: [3, 2], expanded: true, hasNextActionCaption: true)
    #expect(caption - plain == NotchRosterLayout.nextActionCaptionHeight + NotchRosterLayout.deckSectionSpacing)
}
