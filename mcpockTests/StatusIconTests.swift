import XCTest
import SwiftUI
@testable import mcpock

/// The menu-bar icon's badge is a shape, not a count or a pulse (v1.5 spec,
/// Phase 6): nothing for all fine, a ring for slow / needs sign-in / still
/// checking / set up differently, a diamond only for broken.
final class StatusIconTests: XCTestCase {
    func testAllFineShowsNoBadge() {
        XCTAssertEqual(StatusBadgeKind.forAggregate(.allHealthy), .none)
    }

    func testSlowUnknownAndDiffersShareTheRing() {
        XCTAssertEqual(StatusBadgeKind.forAggregate(.degradedOrUnknown), .ring)
        XCTAssertEqual(StatusBadgeKind.forAggregate(.attention), .ring,
                       "a setup mismatch earns the ring, never the diamond")
    }

    func testBrokenIsTheOnlyDiamond() {
        XCTAssertEqual(StatusBadgeKind.forAggregate(.broken), .diamond)
    }

    /// End to end from the monitor's pure verdict: a differing but healthy set
    /// rings, one broken server diamonds whatever else is going on.
    func testBadgeFollowsTheMonitorVerdict() {
        XCTAssertEqual(StatusBadgeKind.forAggregate(HealthMonitor.iconState([.healthy, .healthy])), .none)
        XCTAssertEqual(StatusBadgeKind.forAggregate(HealthMonitor.iconState([.healthy], anyDiffers: true)), .ring)
        XCTAssertEqual(StatusBadgeKind.forAggregate(HealthMonitor.iconState([.healthy, .degraded])), .ring)
        XCTAssertEqual(StatusBadgeKind.forAggregate(HealthMonitor.iconState([.broken, .degraded], anyDiffers: true)), .diamond)
    }

    func testEveryStateHasItsOwnAccessibilityLabel() {
        let states: [AggregateState] = [.allHealthy, .attention, .degradedOrUnknown, .broken]
        let labels = states.map(StatusIconView.accessibilityLabel(for:))
        XCTAssertEqual(Set(labels).count, states.count, "labels must differ per state: \(labels)")
        for label in labels {
            XCTAssertTrue(label.hasPrefix("mcpock: "), label)
        }
        XCTAssertTrue(StatusIconView.accessibilityLabel(for: .broken).contains("broken"))
        XCTAssertTrue(StatusIconView.accessibilityLabel(for: .attention).contains("set up differently"))
    }

    /// A MenuBarExtra label only keeps an image, and turns it into a template:
    /// the badge must be baked into a non-template image or it never shows
    /// (it didn't, until Phase 7). All fine stays the plain template glyph.
    func testBadgedIconIsOneColouredImage() {
        XCTAssertTrue(StatusIconView.image(for: .none).isTemplate)
        for kind in [StatusBadgeKind.ring, .diamond] {
            let image = StatusIconView.image(for: kind)
            XCTAssertFalse(image.isTemplate, "\(kind) must keep its colour")
            XCTAssertEqual(image.size, StatusIconView.canvas)
            XCTAssertNotNil(image.cgImage(forProposedRect: nil, context: nil, hints: nil), "\(kind) draws")
        }
    }

    /// The spec's sizes: a 7pt ring with a 2pt stroke, a 6pt diamond.
    func testBadgeGeometryMatchesTheSpec() {
        XCTAssertEqual(StatusIconView.ringSize, 7)
        XCTAssertEqual(StatusIconView.ringStroke, 2)
        XCTAssertEqual(StatusIconView.diamondSide, 6)
    }
}
