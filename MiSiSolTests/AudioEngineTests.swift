//
//  AudioEngineTests.swift
//  MiSiSolTests
//
//  Prueba la resiliencia a interrupciones y cambios de ruta publicando en NotificationCenter las
//  mismas notificaciones reales que dispararía el sistema (una llamada, unos auriculares...), en
//  vez de solo leer el código. No sustituye a probarlo con hardware real (una llamada entrante de
//  verdad, un auricular Bluetooth real emparejado), pero ejercita exactamente los mismos observers
//  y el mismo código de reintento que se dispararía en ese caso.
//

import AVFoundation
import XCTest
@testable import MiSiSol

final class AudioEngineTests: XCTestCase {

    /// `AudioEngine` despacha sus observers a `DispatchQueue.main.async`; no hay otro gancho de
    /// sincronización sin tocar código de producción solo para hacerlo testeable, así que se le da
    /// un margen corto para que el run loop principal drene ese bloque.
    private func waitForMainQueueDispatch() async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    func testInterruptionBeginStopsCaptureAndEndedWithShouldResumeRestartsIt() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }

        try engine.start { _, _ in }
        XCTAssertTrue(engine.isRunning)

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        try await waitForMainQueueDispatch()
        XCTAssertFalse(engine.isRunning, "Una interrupción que empieza debe parar la captura")

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
            ]
        )
        try await waitForMainQueueDispatch()
        XCTAssertTrue(engine.isRunning, "Si el sistema permite reanudar (.shouldResume), la captura debe volver sola")
    }

    func testInterruptionEndedWithoutShouldResumeDoesNotRestartCapture() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }

        try engine.start { _, _ in }

        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        try await waitForMainQueueDispatch()

        // Sin .shouldResume (p.ej. el usuario cortó la llamada activamente): no reanudar solo.
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        )
        try await waitForMainQueueDispatch()
        XCTAssertFalse(engine.isRunning)
    }

    func testRouteChangeWithNewDeviceReinstallsTapAndKeepsRunning() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }

        try engine.start { _, _ in }
        XCTAssertTrue(engine.isRunning)

        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue]
        )
        try await waitForMainQueueDispatch()

        // Un cambio de ruta real reinstala el tap (para el motor y lo vuelve a arrancar); sigue
        // escuchando al terminar, no se queda "sorda".
        XCTAssertTrue(engine.isRunning)
    }

    func testCategoryChangeRouteReasonDoesNotTriggerRestartLoop() async throws {
        let engine = AudioEngine()
        defer { engine.stop() }

        try engine.start { _, _ in }
        XCTAssertTrue(engine.isRunning)

        // .categoryChange es el que la propia AudioEngine dispara al configurar su sesión en
        // beginCapture(): no debe reaccionar también a este (provocaría un bucle de reinicios).
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.categoryChange.rawValue]
        )
        try await waitForMainQueueDispatch()
        XCTAssertTrue(engine.isRunning)
    }
}
