import AppKit
import Testing
@testable import LaunchPlatform

@Suite("HotCornerMonitor screen hit testing")
struct HotCornerMonitorTests {
    private let frame = NSRect(x: 0, y: 0, width: 1470, height: 956)

    @Test("包含 min 边界（左下/左上原点侧）")
    func minEdgesInclusive() {
        #expect(HotCornerMonitor.screenFrameContains(frame, point: NSPoint(x: 0, y: 0)))
        #expect(HotCornerMonitor.screenFrameContains(frame, point: NSPoint(x: 0, y: 955)))
        #expect(HotCornerMonitor.screenFrameContains(frame, point: NSPoint(x: 1469, y: 0)))
    }

    @Test("包含 max 边界（鼠标压到屏幕最顶/最右边时 Cocoa 坐标 == maxY/maxX）")
    func maxEdgesInclusive() {
        #expect(HotCornerMonitor.screenFrameContains(frame, point: NSPoint(x: 0, y: 956)))
        #expect(HotCornerMonitor.screenFrameContains(frame, point: NSPoint(x: 1470, y: 956)))
        #expect(HotCornerMonitor.screenFrameContains(frame, point: NSPoint(x: 1470, y: 0)))
    }

    @Test("超出边界返回 false")
    func outsideReturnsFalse() {
        #expect(!HotCornerMonitor.screenFrameContains(frame, point: NSPoint(x: -1, y: 0)))
        #expect(!HotCornerMonitor.screenFrameContains(frame, point: NSPoint(x: 0, y: 957)))
        #expect(!HotCornerMonitor.screenFrameContains(frame, point: NSPoint(x: 1471, y: 0)))
    }
}
