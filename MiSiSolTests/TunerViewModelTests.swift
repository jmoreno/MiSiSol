//
//  TunerViewModelTests.swift
//  MiSiSolTests
//

import XCTest
@testable import MiSiSol

@MainActor
final class TunerViewModelTests: XCTestCase {

    func testSmoothingAveragesRecentFrequencies() {
        let vm = TunerViewModel(instrument: .guitar, smoothingWindowSize: 4)

        for _ in 0..<4 { vm.processPitch(110) }
        XCTAssertEqual(vm.detectedFrequency ?? 0, 110, accuracy: 0.01)

        // Una lectura puntual desviada no debe mover la media al valor crudo: se suaviza.
        vm.processPitch(150)
        let expected: Float = (110 * 3 + 150) / 4
        XCTAssertEqual(vm.detectedFrequency ?? 0, expected, accuracy: 0.01)
    }

    func testStatusInTuneWithinCentsMargin() {
        let vm = TunerViewModel(instrument: .guitar, inTuneCentsMargin: 5, smoothingWindowSize: 1)
        let target = vm.targetNote!.frequency
        vm.processPitch(Float(target))
        XCTAssertEqual(vm.status, .inTune)
        XCTAssertEqual(vm.centsOffset, 0, accuracy: 0.5)
    }

    func testStatusTooLowWhenFrequencyBelowTarget() {
        let vm = TunerViewModel(instrument: .guitar, inTuneCentsMargin: 5, smoothingWindowSize: 1)
        let target = vm.targetNote!.frequency
        let flat = target * pow(2.0, -20.0 / 1200.0) // 20 cents por debajo del objetivo
        vm.processPitch(Float(flat))
        XCTAssertEqual(vm.status, .tooLow)
    }

    func testStatusTooHighWhenFrequencyAboveTarget() {
        let vm = TunerViewModel(instrument: .guitar, inTuneCentsMargin: 5, smoothingWindowSize: 1)
        let target = vm.targetNote!.frequency
        let sharp = target * pow(2.0, 20.0 / 1200.0) // 20 cents por encima del objetivo
        vm.processPitch(Float(sharp))
        XCTAssertEqual(vm.status, .tooHigh)
    }

    func testNilFrequencyResetsToNoSignal() {
        let vm = TunerViewModel(instrument: .guitar)
        vm.processPitch(110)
        XCTAssertNotEqual(vm.status, .noSignal)

        vm.processPitch(nil)
        XCTAssertEqual(vm.status, .noSignal)
        XCTAssertNil(vm.detectedFrequency)
        XCTAssertNil(vm.detectedNote)
    }

    func testSelectingInstrumentResetsTuningAndUpdatesTargetNote() {
        let vm = TunerViewModel(instrument: .guitar)
        XCTAssertEqual(vm.targetNote?.fullName, "E2")

        vm.selectInstrument(.bass)
        XCTAssertEqual(vm.instrument, .bass)
        XCTAssertEqual(vm.selectedStringIndex, 0)
        XCTAssertEqual(vm.targetNote?.fullName, "E1")
    }

    func testSelectingStringUpdatesTargetNote() {
        let vm = TunerViewModel(instrument: .guitar)
        vm.selectString(at: 5)
        XCTAssertEqual(vm.targetNote?.fullName, "E4")
    }

    func testTransposeUpdatesTargetNoteFrequency() {
        let vm = TunerViewModel(instrument: .guitar)
        vm.transpose(bySemitones: -2)
        XCTAssertEqual(vm.targetNote?.fullName, "D2")
    }

    func testSelectingCustomTuningUpdatesTargetNote() {
        let vm = TunerViewModel(instrument: .guitar)
        vm.selectTuning(.dropD)
        XCTAssertEqual(vm.targetNote?.fullName, "D2")
    }

    func testSelectingTuningWithFewerStringsClampsSelectedStringIndex() {
        let vm = TunerViewModel(instrument: .guitar)
        vm.selectString(at: 5) // última cuerda de la guitarra (6 cuerdas)

        vm.selectTuning(.standard(for: .bass)) // el bajo solo tiene 4 cuerdas
        XCTAssertEqual(vm.selectedStringIndex, 3)
        XCTAssertEqual(vm.targetNote?.fullName, "G2")
    }
}
