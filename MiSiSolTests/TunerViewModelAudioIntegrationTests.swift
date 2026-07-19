//
//  TunerViewModelAudioIntegrationTests.swift
//  MiSiSolTests
//
//  Prueba con AVAudioEngine real (no las dependencias inyectadas que usa el resto de
//  TunerViewModelTests) la secuencia escuchar → reproducir nota de referencia → parar → seguir
//  escuchando: el "momento delicado" documentado en TunerViewModel.stopReferenceNote(), donde se
//  le devuelve la sesión de audio a AudioEngine (categoría .record) mientras el fundido de salida
//  de ToneGenerator (categoría .playback) todavía puede estar sonando.
//
//  Los tests son síncronos (no `async`) y bombean el run loop a mano con
//  `RunLoop.current.run(until:)` en vez de `Task.sleep`: stopReferenceNote() programa la reanudación
//  con `DispatchQueue.main.asyncAfter`, un timer que necesita que el run loop del hilo principal
//  esté girando de verdad para dispararse — cosa que un test `async` no garantiza (su cuerpo no
//  corre necesariamente sobre el run loop real), pero un método de test síncrono clásico sí, igual
//  que en la app real con UIApplicationMain.
//

import AVFoundation
import XCTest
@testable import MiSiSol

final class TunerViewModelAudioIntegrationTests: XCTestCase {

    private func pumpRunLoop(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testPlayingReferenceNoteThenStoppingResumesListening() throws {
        let audioEngine = AudioEngine()
        let toneGenerator = ToneGenerator()
        let vm = TunerViewModel(
            instrument: .guitar,
            audioEngine: audioEngine,
            toneGenerator: toneGenerator,
            tuningStore: TuningStore(defaults: UserDefaults(suiteName: "TunerViewModelAudioIntegrationTests.\(UUID().uuidString)")!)
        )
        defer {
            vm.stopReferenceNote()
            vm.stopListening()
        }

        vm.startListening()
        pumpRunLoop(for: 0.3)
        XCTAssertTrue(audioEngine.isRunning, "startListening() debe dejar la captura activa")

        vm.playReferenceNote()
        XCTAssertTrue(vm.isPlayingReferenceNote)
        XCTAssertTrue(toneGenerator.isPlaying)
        XCTAssertFalse(audioEngine.isRunning, "Mientras suena la referencia no debe estar escuchando (no confundir la señal)")

        vm.stopReferenceNote()
        XCTAssertFalse(vm.isPlayingReferenceNote)
        XCTAssertFalse(toneGenerator.isPlaying)

        // stopReferenceNote() espera el fundido de salida (ToneGenerator.rampDuration) antes de
        // reclamar la sesión para escuchar; se da margen de sobra para que termine esa espera y el
        // beginCapture() posterior.
        pumpRunLoop(for: 2.0)
        XCTAssertTrue(
            audioEngine.isRunning,
            "Tras parar la referencia debe reanudar la escucha sola. audioErrorMessage=[\(vm.audioErrorMessage ?? "nil")]"
        )
    }

    func testPlayingReferenceNoteWhileNotListeningDoesNotStartListeningAfterStop() throws {
        let audioEngine = AudioEngine()
        let toneGenerator = ToneGenerator()
        let vm = TunerViewModel(
            instrument: .guitar,
            audioEngine: audioEngine,
            toneGenerator: toneGenerator,
            tuningStore: TuningStore(defaults: UserDefaults(suiteName: "TunerViewModelAudioIntegrationTests.\(UUID().uuidString)")!)
        )
        defer {
            vm.stopReferenceNote()
            vm.stopListening()
        }

        // Nunca se llamó a startListening(): reproducir y parar la referencia no debe empezar a
        // escuchar por su cuenta (wasListeningBeforeReferenceNote debe seguir siendo false).
        vm.playReferenceNote()
        XCTAssertTrue(toneGenerator.isPlaying)

        vm.stopReferenceNote()
        pumpRunLoop(for: 2.0)
        XCTAssertFalse(audioEngine.isRunning)
    }
}
