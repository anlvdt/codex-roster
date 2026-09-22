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
    // Contiguous columns include only their own section headers.
    // The tallest of three columns has seven accounts and two headers.
    let sections = [5, 5, 5, 5]
    #expect(NotchRosterLayout.contentRowCount(sectionCounts: sections, columns: 2) == 12)
    #expect(NotchRosterLayout.columnCount(sectionCounts: sections, expanded: true) == 3)
    #expect(NotchRosterLayout.contentRowCount(sectionCounts: sections, columns: 3) == 9)
    #expect(!NotchRosterLayout.needsRosterScroll(sectionCounts: sections, expanded: true))

    let height = NotchRosterLayout.rosterGridHeight(sectionCounts: sections, expanded: true)
    // Headers use sectionHeaderHeight (not full rowHeight) to avoid bottom void.
    let headerCount = 2
    let accountRows = 7
    let logicalRows = headerCount + accountRows
    let expected = CGFloat(headerCount) * NotchRosterLayout.sectionHeaderHeight
        + CGFloat(headerCount - 1) * NotchRosterLayout.sectionHeaderTopGap
        + CGFloat(accountRows) * NotchRosterLayout.rowHeight
        + CGFloat(logicalRows - 1) * NotchRosterLayout.rowSpacing
        + NotchRosterLayout.gridVerticalPadding
    #expect(height == expected)
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
    // ≥8 accounts prefer width-aware columns (3 on the panoramic deck).
    #expect(NotchRosterLayout.preferredColumnCount(sectionCounts: sections) == 3)
    #expect(NotchRosterLayout.columnCount(sectionCounts: sections, expanded: true) == 3)
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
    // Panoramic deck (~996pt usable) keeps cards ≥ minComfortableCardWidth → 3 cols.
    #expect(NotchRosterLayout.maxColumnsForComfortableWidth() == 3)
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
