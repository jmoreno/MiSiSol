//
//  TunerViewModelTests.swift
//  MiSiSolTests
//

import XCTest
@testable import MiSiSol

@MainActor
final class TunerViewModelTests: XCTestCase {

    private var suiteName: String!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TunerViewModelTests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        testDefaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// Crea un `TunerViewModel` con un `TuningStore` aislado (dominio de UserDefaults propio de
    /// este test), para no leer ni escribir en las preferencias reales de la app.
    private func makeViewModel(
        instrument: Instrument = .guitar,
        inTuneCentsMargin: Double = 5.0,
        smoothingWindowSize: Int = 5,
        maxConsecutiveMissedReadings: Int = 3
    ) -> TunerViewModel {
        TunerViewModel(
            instrument: instrument,
            tuningStore: TuningStore(defaults: testDefaults),
            inTuneCentsMargin: inTuneCentsMargin,
            smoothingWindowSize: smoothingWindowSize,
            maxConsecutiveMissedReadings: maxConsecutiveMissedReadings
        )
    }

    func testSmoothingIgnoresIsolatedOutlierReading() {
        let vm = makeViewModel(smoothingWindowSize: 5)

        for _ in 0..<5 { vm.processPitch(110) }
        XCTAssertEqual(vm.detectedFrequency ?? 0, 110, accuracy: 0.01)

        // Un pico de ruido de fondo puntual (una lectura suelta muy distinta) no debe mover la
        // mediana: a diferencia de una media, la mediana ignora por completo un único valor
        // extremo mientras el resto de la ventana siga de acuerdo.
        vm.processPitch(300)
        XCTAssertEqual(vm.detectedFrequency ?? 0, 110, accuracy: 0.01)

        // Pero si la nueva frecuencia se sostiene (bastan un par de lecturas más, en cuanto
        // domina la ventana de 5), la mediana la termina reflejando: ya no es un pico puntual.
        vm.processPitch(300)
        vm.processPitch(300)
        XCTAssertEqual(vm.detectedFrequency ?? 0, 300, accuracy: 0.01)
    }

    func testStatusInTuneWithinCentsMargin() {
        let vm = makeViewModel(inTuneCentsMargin: 5, smoothingWindowSize: 1)
        let target = vm.targetNote!.frequency
        vm.processPitch(Float(target))
        XCTAssertEqual(vm.status, .inTune)
        XCTAssertEqual(vm.centsOffset, 0, accuracy: 0.5)
    }

    func testStatusTooLowWhenFrequencyBelowTarget() {
        let vm = makeViewModel(inTuneCentsMargin: 5, smoothingWindowSize: 1)
        let target = vm.targetNote!.frequency
        let flat = target * pow(2.0, -20.0 / 1200.0) // 20 cents por debajo del objetivo
        vm.processPitch(Float(flat))
        XCTAssertEqual(vm.status, .tooLow)
    }

    func testStatusTooHighWhenFrequencyAboveTarget() {
        let vm = makeViewModel(inTuneCentsMargin: 5, smoothingWindowSize: 1)
        let target = vm.targetNote!.frequency
        let sharp = target * pow(2.0, 20.0 / 1200.0) // 20 cents por encima del objetivo
        vm.processPitch(Float(sharp))
        XCTAssertEqual(vm.status, .tooHigh)
    }

    func testNilFrequencyResetsToNoSignalAfterConsecutiveMisses() {
        let vm = makeViewModel(maxConsecutiveMissedReadings: 3)
        vm.processPitch(110)
        XCTAssertNotEqual(vm.status, .noSignal)

        vm.processPitch(nil)
        vm.processPitch(nil)
        vm.processPitch(nil)
        XCTAssertEqual(vm.status, .noSignal)
        XCTAssertNil(vm.detectedFrequency)
        XCTAssertNil(vm.detectedNote)
    }

    func testIsolatedMissedReadingDoesNotResetSmoothedFrequency() {
        let vm = makeViewModel(smoothingWindowSize: 4, maxConsecutiveMissedReadings: 3)
        for _ in 0..<4 { vm.processPitch(110) }
        XCTAssertEqual(vm.detectedFrequency ?? 0, 110, accuracy: 0.01)

        // Una lectura fallida aislada (por debajo del máximo de fallos consecutivos) no debe
        // borrar el historial de suavizado ni el estado detectado.
        vm.processPitch(nil)
        XCTAssertEqual(vm.detectedFrequency ?? 0, 110, accuracy: 0.01)
        XCTAssertNotEqual(vm.status, .noSignal)

        // Una lectura buena vuelve a poner el contador de fallos a cero.
        vm.processPitch(110)
        XCTAssertEqual(vm.detectedFrequency ?? 0, 110, accuracy: 0.01)
    }

    func testSelectingInstrumentResetsTuningAndUpdatesTargetNote() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.targetNote?.fullName, "E2")

        vm.selectInstrument(.bass)
        XCTAssertEqual(vm.instrument, .bass)
        XCTAssertEqual(vm.selectedStringIndex, 0)
        XCTAssertEqual(vm.targetNote?.fullName, "E1")
    }

    func testSelectingStringUpdatesTargetNote() {
        let vm = makeViewModel()
        vm.selectString(at: 5)
        XCTAssertEqual(vm.targetNote?.fullName, "E4")
    }

    func testTransposeUpdatesTargetNoteFrequency() {
        let vm = makeViewModel()
        vm.transpose(bySemitones: -2)
        XCTAssertEqual(vm.targetNote?.fullName, "D2")
    }

    func testSelectingCustomTuningUpdatesTargetNote() {
        let vm = makeViewModel()
        vm.selectTuning(.dropD)
        XCTAssertEqual(vm.targetNote?.fullName, "D2")
    }

    func testSelectingTuningWithFewerStringsClampsSelectedStringIndex() {
        let vm = makeViewModel()
        vm.selectString(at: 5) // última cuerda de la guitarra (6 cuerdas)

        vm.selectTuning(.standard(for: .bass)) // el bajo solo tiene 4 cuerdas
        XCTAssertEqual(vm.selectedStringIndex, 3)
        XCTAssertEqual(vm.targetNote?.fullName, "G2")
    }

    // MARK: - Persistencia de afinación por instrumento

    func testSelectingTuningPersistsItForThatInstrument() {
        let store = TuningStore(defaults: testDefaults)
        let vm = TunerViewModel(instrument: .guitar, tuningStore: store)

        vm.selectTuning(.dropD)

        XCTAssertEqual(store.loadTuning(for: .guitar)?.name, "Drop D")
    }

    func testNewViewModelRestoresPersistedTuningForInstrument() {
        let store = TuningStore(defaults: testDefaults)
        let first = TunerViewModel(instrument: .guitar, tuningStore: store)
        first.transpose(bySemitones: -2)

        // Una instancia nueva (como al reabrir la app) recupera la afinación guardada.
        let second = TunerViewModel(instrument: .guitar, tuningStore: store)
        XCTAssertEqual(second.targetNote?.fullName, "D2")
    }

    func testSwitchingInstrumentRestoresThatInstrumentsPersistedTuning() {
        let store = TuningStore(defaults: testDefaults)
        let vm = TunerViewModel(instrument: .guitar, tuningStore: store)
        vm.selectTuning(.dropD)

        vm.selectInstrument(.bass)
        XCTAssertEqual(vm.targetNote?.fullName, "E1") // el bajo no tiene afinación guardada: estándar

        vm.selectInstrument(.guitar)
        XCTAssertEqual(vm.targetNote?.fullName, "D2") // la guitarra recupera Drop D
    }

    // MARK: - Modo automático

    func testDefaultModeIsManual() {
        let vm = makeViewModel()
        XCTAssertEqual(vm.mode, .manual)
    }

    func testAutomaticModeSelectsNearestStringToDetectedFrequency() {
        let vm = makeViewModel(smoothingWindowSize: 1)
        vm.setMode(.automatic)
        XCTAssertEqual(vm.selectedStringIndex, 0) // E2 por defecto

        let a2 = Note.make(name: "A", octave: 2)!.frequency // segunda cuerda de la guitarra
        vm.processPitch(Float(a2))
        XCTAssertEqual(vm.selectedStringIndex, 1)
        XCTAssertEqual(vm.targetNote?.fullName, "A2")
    }

    func testManualModeDoesNotChangeSelectedStringBasedOnDetectedPitch() {
        let vm = makeViewModel(smoothingWindowSize: 1)
        // Modo manual por defecto, cuerda 0 (E2) seleccionada.
        let a2 = Note.make(name: "A", octave: 2)!.frequency
        vm.processPitch(Float(a2))
        XCTAssertEqual(vm.selectedStringIndex, 0)
        XCTAssertEqual(vm.targetNote?.fullName, "E2")
    }

    func testAutomaticModeHysteresisAvoidsFlickeringNearMidpointBetweenStrings() {
        let vm = makeViewModel(smoothingWindowSize: 1)
        vm.setMode(.automatic)

        let e2 = Note.make(name: "E", octave: 2)!.frequency
        let a2 = Note.make(name: "A", octave: 2)!.frequency
        let totalCents = 1200 * log2(a2 / e2)

        vm.processPitch(Float(e2))
        XCTAssertEqual(vm.selectedStringIndex, 0)

        // Un poco más cerca de A2 que de E2, pero por debajo del margen de histéresis (10 cents):
        // no debería cambiar de cuerda objetivo todavía.
        let nearMidpoint = e2 * pow(2.0, (totalCents / 2 + 3) / 1200.0)
        vm.processPitch(Float(nearMidpoint))
        XCTAssertEqual(vm.selectedStringIndex, 0)

        // Claramente más cerca de A2 (por encima del margen de histéresis): ahora sí cambia.
        let clearlyCloserToA2 = e2 * pow(2.0, (totalCents - 20) / 1200.0)
        vm.processPitch(Float(clearlyCloserToA2))
        XCTAssertEqual(vm.selectedStringIndex, 1)
    }
}
