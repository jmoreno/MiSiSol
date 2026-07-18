//
//  NoteTests.swift
//  MiSiSolTests
//

import XCTest
@testable import MiSiSol

final class NoteTests: XCTestCase {

    private let frequencyTolerance = 0.01

    func testFrequencyAtA4IsReferenceFrequency() {
        XCTAssertEqual(Note.frequency(forSemitonesFromA4: 0), 440.0, accuracy: frequencyTolerance)
    }

    func testFrequencyOneOctaveAboveA4IsDouble() {
        XCTAssertEqual(Note.frequency(forSemitonesFromA4: 12), 880.0, accuracy: frequencyTolerance)
    }

    func testFrequencyOneOctaveBelowA4IsHalf() {
        XCTAssertEqual(Note.frequency(forSemitonesFromA4: -12), 220.0, accuracy: frequencyTolerance)
    }

    func testFrequencyOfKnownGuitarLowE() {
        let e2 = Note.make(name: "E", octave: 2)
        XCTAssertNotNil(e2)
        XCTAssertEqual(e2?.frequency ?? 0, 82.41, accuracy: 0.01)
    }

    func testFrequencyOfKnownBassLowE() {
        let e1 = Note.make(name: "E", octave: 1)
        XCTAssertNotNil(e1)
        XCTAssertEqual(e1?.frequency ?? 0, 41.20, accuracy: 0.01)
    }

    func testMakeWithInvalidNameReturnsNil() {
        XCTAssertNil(Note.make(name: "H", octave: 4))
    }

    func testNoteForSemitonesRoundTripsName() {
        let c4 = Note.note(forSemitonesFromA4: -9)
        XCTAssertEqual(c4.name, "C")
        XCTAssertEqual(c4.octave, 4)
    }

    func testClosestNoteToExactFrequencyHasZeroCents() {
        let (note, cents) = Note.closest(to: 440.0)
        XCTAssertEqual(note.fullName, "A4")
        XCTAssertEqual(cents, 0, accuracy: 0.5)
    }

    func testClosestNoteToSlightlySharpFrequencyHasPositiveCents() {
        // ~10 cents por encima de A4 (440 * 2^(10/1200))
        let sharpFrequency = 440.0 * pow(2.0, 10.0 / 1200.0)
        let (note, cents) = Note.closest(to: sharpFrequency)
        XCTAssertEqual(note.fullName, "A4")
        XCTAssertEqual(cents, 10, accuracy: 0.5)
    }

    func testClosestNoteToSlightlyFlatFrequencyHasNegativeCents() {
        // ~10 cents por debajo de A4
        let flatFrequency = 440.0 * pow(2.0, -10.0 / 1200.0)
        let (note, cents) = Note.closest(to: flatFrequency)
        XCTAssertEqual(note.fullName, "A4")
        XCTAssertEqual(cents, -10, accuracy: 0.5)
    }

    func testClosestNoteToFrequencyBetweenTwoNotesPicksNearest() {
        // A2 (110Hz) + 2 semitonos ~ B2 (123.47Hz), tomamos un valor claramente más cerca de B2
        let (note, _) = Note.closest(to: 123.0)
        XCTAssertEqual(note.fullName, "B2")
    }
}
