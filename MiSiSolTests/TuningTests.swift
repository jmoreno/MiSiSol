//
//  TuningTests.swift
//  MiSiSolTests
//

import XCTest
@testable import MiSiSol

final class TuningTests: XCTestCase {

    func testStandardGuitarTuningHasSixStringsInOrder() {
        let tuning = Tuning.standard(for: .guitar)
        XCTAssertEqual(tuning.strings.map(\.fullName), ["E2", "A2", "D3", "G3", "B3", "E4"])
    }

    func testStandardBassTuningHasFourStrings() {
        let tuning = Tuning.standard(for: .bass)
        XCTAssertEqual(tuning.strings.map(\.fullName), ["E1", "A1", "D2", "G2"])
    }

    func testStandardUkuleleTuningIsReentrant() {
        let tuning = Tuning.standard(for: .ukulele)
        XCTAssertEqual(tuning.strings.map(\.fullName), ["G4", "C4", "E4", "A4"])
    }

    func testTransposedGuitarTuningTwoSemitonesDownRecalculatesNotesAndFrequencies() {
        let tuning = Tuning.transposedStandard(for: .guitar, bySemitones: -2)
        XCTAssertEqual(tuning.strings.map(\.fullName), ["D2", "G2", "C3", "F3", "A3", "D4"])

        let standard = Tuning.standard(for: .guitar)
        for (transposedNote, standardNote) in zip(tuning.strings, standard.strings) {
            let expectedFrequency = Note.frequency(forSemitonesFromA4: standardNote.semitonesFromA4 - 2)
            XCTAssertEqual(transposedNote.frequency, expectedFrequency, accuracy: 0.001)
        }
        XCTAssertEqual(tuning.transposeSemitones, -2)
    }

    func testTransposedTuningLabelsDescribeCommonOffsets() {
        XCTAssertEqual(Tuning.transposeLabel(for: 0), "Estándar")
        XCTAssertEqual(Tuning.transposeLabel(for: -1), "Media asta abajo")
        XCTAssertEqual(Tuning.transposeLabel(for: -2), "Un tono abajo")
        XCTAssertEqual(Tuning.transposeLabel(for: 1), "Media asta arriba")
    }

    func testCustomTuningBuildsExactNumberOfStringsForInstrument() {
        let instrument = Instrument.ukulele
        let customNotes: [Note] = [("A", 4), ("D", 4), ("F#", 4), ("B", 4)]
            .compactMap { Note.make(name: $0.0, octave: $0.1) }
        let tuning = Tuning.custom(instrument: instrument, name: "Personalizada", notes: customNotes)

        XCTAssertEqual(tuning.strings.count, instrument.numberOfStrings)
        XCTAssertEqual(tuning.strings.map(\.fullName), ["A4", "D4", "F#4", "B4"])
        XCTAssertEqual(tuning.transposeSemitones, 0)
    }

    func testDropDAlternateTuningLowersOnlySixthString() {
        let dropD = Tuning.dropD
        XCTAssertEqual(dropD.strings.map(\.fullName), ["D2", "A2", "D3", "G3", "B3", "E4"])
        XCTAssertEqual(dropD.strings[0].frequency, 73.42, accuracy: 0.01)
    }

    func testAlternatesForGuitarIncludeDropD() {
        let alternates = Tuning.alternates(for: .guitar)
        XCTAssertTrue(alternates.contains { $0.name == "Drop D" })
    }
}
