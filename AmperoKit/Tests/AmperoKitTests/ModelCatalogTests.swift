import XCTest
@testable import AmperoKit

final class ModelCatalogTests: XCTestCase {
    func testBundledCatalogLoads() throws {
        let catalog = try ModelCatalog.loadBundled()
        for block in Block.allCases {
            XCTAssertFalse(catalog.models(for: block).isEmpty, "\(block) has no models")
        }
        // Codes proven on a pedal (docs/models.md in ampero-bridge).
        XCTAssertEqual(catalog.model(.fx2, code: 9)?.name, "Governor")
        XCTAssertEqual(catalog.model(.dly, code: 9)?.name, "Slapback")
        XCTAssertEqual(catalog.model(.rvb, code: 4)?.name, "Spring")
    }

    func testCabModelsShareOneLayout() throws {
        let catalog = try ModelCatalog.loadBundled()
        XCTAssertEqual(catalog.models(for: .cab).count, 70)
        let cab = try XCTUnwrap(catalog.model(.cab, code: 34))
        XCTAssertEqual(cab.name, "UK Black 4x12")
        XCTAssertEqual(cab.params.map(\.name), ["Mic", "Volume", "Position X", "Position Y",
                                                "Position Z", "Low Cut", "High Cut"])
        XCTAssertEqual(cab.params[5].format(0), "Off")
        XCTAssertEqual(cab.params[6].format(1801), "Off")
        XCTAssertEqual(cab.params[6].format(100), "3000 Hz")
    }

    func testClassicPSRangeIsCapped() throws {
        // Writing 6 to Classic PS Range wedges the pedal; the catalog must stop at 5.
        let catalog = try ModelCatalog.loadBundled()
        let classicPS = catalog.models(for: .fx2).first { $0.name == "Classic PS" }
        XCTAssertEqual(classicPS?.params.first?.rawRange.upperBound, 5)
    }

    func testDelayTimeFormatting() throws {
        let catalog = try ModelCatalog.loadBundled()
        let time = catalog.model(.dly, code: 9)?.params.first { $0.name == "Time" }
        XCTAssertNotNil(time)
        XCTAssertEqual(time?.format(110), "130")   // raw + 20 = ms
    }
}
