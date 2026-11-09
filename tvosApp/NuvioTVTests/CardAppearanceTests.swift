import XCTest
@testable import NuvioTV

final class CardAppearanceTests: XCTestCase {
    func testEmptyStoreGivesTheCardDefaults() {
        let suite = "nuvio.tests.cardAppearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(CardAppearance.stored(in: defaults), CardAppearance())
        XCTAssertTrue(CardAppearance().liquidGlassCards)
        XCTAssertTrue(CardAppearance().smoothFocus)
        XCTAssertEqual(CardAppearance().trailerDelay, 7)
    }

    func testSavedSettingsAreRead() {
        let suite = "nuvio.tests.cardAppearance.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: SettingsKey.liquidGlassCards)
        defaults.set(true, forKey: SettingsKey.posterLabels)
        defaults.set(12, forKey: SettingsKey.trailerDelay)
        defaults.set(CardCornerRadiusOption.pill.rawValue, forKey: SettingsKey.cardCornerRadius)
        defaults.set(true, forKey: SettingsKey.amoled)

        let appearance = CardAppearance.stored(in: defaults)
        XCTAssertFalse(appearance.liquidGlassCards)
        XCTAssertTrue(appearance.posterLabels)
        XCTAssertEqual(appearance.trailerDelay, 12)
        XCTAssertEqual(appearance.cardCornerRadius, CardCornerRadiusOption.pill.rawValue)
        XCTAssertTrue(appearance.amoled)
        XCTAssertFalse(appearance.amoledSurfaces)
    }
}
