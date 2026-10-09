import XCTest
import AppKit
@testable import mcpock

/// Round 9 (review of round 8): the Check servers value never wraps or
/// changes width, the slider's keyboard steps and snap glide, and Copy for
/// Claude's orange "Copied" state.
@MainActor
final class Round9SettingsTests: XCTestCase {

    // MARK: - Check servers slider

    func testValueLabelsAreShortWithoutEvery() {
        XCTAssertEqual(ProbeInterval.allCases.map(\.title),
                       ["1 min", "5 min", "15 min", "30 min", "1 h", "4 h", "Manual"])
        XCTAssertFalse(ProbeInterval.allCases.contains { $0.title.contains("Every") })
    }

    func testValueWidthFitsTheWidestLabel() {
        let width = SettingsGeneralPane.valueWidth
        for interval in ProbeInterval.allCases {
            XCTAssertLessThanOrEqual(SettingsGeneralPane.valueTextWidth(interval.title), width, interval.title)
        }
        // Sized to the labels, not a guess: no big empty gap beside the slider.
        let widest = ProbeInterval.allCases.map { SettingsGeneralPane.valueTextWidth($0.title) }.max() ?? 0
        XCTAssertLessThan(width - widest, 4)
        XCTAssertEqual(SettingsGeneralPane.sliderWidth, 190)
    }

    func testKeyboardStepsMoveOneWholeStop() {
        XCTAssertEqual(ProbeInterval.stepped(from: .fiveMinutes, toward: 1.05), .fifteenMinutes)
        XCTAssertEqual(ProbeInterval.stepped(from: .fiveMinutes, toward: 0.95), .oneMinute)
        XCTAssertEqual(ProbeInterval.stepped(from: .fiveMinutes, toward: 1.0), .fiveMinutes)
        XCTAssertEqual(ProbeInterval.stepped(from: .oneMinute, toward: -0.1), .oneMinute)
        XCTAssertEqual(ProbeInterval.stepped(from: .manual, toward: 6.1), .manual)
        // Home / End jump straight to the ends.
        XCTAssertEqual(ProbeInterval.stepped(from: .fifteenMinutes, toward: 0), .oneMinute)
        XCTAssertEqual(ProbeInterval.stepped(from: .fifteenMinutes, toward: 6), .manual)
    }

    func testSnapGlidesAndEndsOnTheStop() {
        let frames = ProbeInterval.snapFrames(from: 2.3, to: 2)
        XCTAssertEqual(frames.count, 9)
        XCTAssertEqual(frames.last, 2)
        // Moves the whole way in one direction, fastest first (ease-out).
        XCTAssertTrue(zip(frames, frames.dropFirst()).allSatisfy { $0 >= $1 })
        XCTAssertGreaterThan(abs(2.3 - frames[0]), abs(frames[7] - frames[8]))
        XCTAssertEqual(ProbeInterval.snapFrames(from: 4, to: 4), [4])
        XCTAssertEqual(ProbeInterval.snapFrames(from: 3.6, to: 4).last, 4)
    }

    // MARK: - Copy for Claude

    func testClaudeOrangeReadsWithWhiteText() {
        let hex = Theme.claudeOrangeHex
        func channel(_ shift: UInt32) -> Double {
            let c = Double((hex >> shift) & 0xFF) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
        XCTAssertGreaterThanOrEqual(1.05 / (luminance + 0.05), 4.5, "white on Claude orange meets 4.5:1")
    }

    func testCopiedTimings() {
        XCTAssertEqual(SettingsConnectPane.claudeCopiedSeconds, 2)
        XCTAssertEqual(SettingsConnectPane.claudeTitle, "Copy for Claude")
    }
}
