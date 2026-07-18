//
//  TuningStoreTests.swift
//  MiSiSolTests
//

import XCTest
@testable import MiSiSol

final class TuningStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TuningStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLoadTuningWithNothingSavedReturnsNil() {
        let store = TuningStore(defaults: defaults)
        XCTAssertNil(store.loadTuning(for: .guitar))
    }

    func testSaveThenLoadRoundTripsTheTuning() {
        let store = TuningStore(defaults: defaults)
        let dropD = Tuning.dropD

        store.saveTuning(dropD, for: .guitar)

        let loaded = store.loadTuning(for: .guitar)
        XCTAssertEqual(loaded?.name, dropD.name)
        XCTAssertEqual(loaded?.strings, dropD.strings)
    }

    func testTuningsAreStoredIndependentlyPerInstrument() {
        let store = TuningStore(defaults: defaults)
        store.saveTuning(.dropD, for: .guitar)

        XCTAssertNil(store.loadTuning(for: .bass))
        XCTAssertEqual(store.loadTuning(for: .guitar)?.name, "Drop D")
    }
}
