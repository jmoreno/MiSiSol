//
//  PitchDetectorTests.swift
//  MiSiSolTests
//

import XCTest
@testable import MiSiSol

final class PitchDetectorTests: XCTestCase {

    private let sampleRate: Double = 44100
    private let detector = PitchDetector()

    private func sineWave(frequency: Double, duration: Double = 0.2, amplitude: Float = 0.8) -> [Float] {
        let sampleCount = Int(sampleRate * duration)
        return (0..<sampleCount).map { i in
            amplitude * Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
        }
    }

    /// Señal con fundamental + un armónico de la misma amplitud (a diferencia de `sineWave`,
    /// que es una sinusoide pura). Un instrumento real nunca es una sinusoide pura: tiene
    /// armónicos que interfieren entre sí y desforman la curva de autocorrelación con mínimos y
    /// máximos intermedios antes de llegar al periodo fundamental.
    private func sineWaveWithHarmonic(
        frequency: Double,
        harmonic: Int,
        harmonicAmplitude: Float,
        duration: Double = 0.2,
        amplitude: Float = 0.5
    ) -> [Float] {
        let sampleCount = Int(sampleRate * duration)
        return (0..<sampleCount).map { i in
            let fundamental = amplitude * Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate))
            let overtone = harmonicAmplitude * Float(sin(2.0 * Double.pi * frequency * Double(harmonic) * Double(i) / sampleRate))
            return fundamental + overtone
        }
    }

    private func assertDetects(_ frequency: Double, tolerancePercent: Double = 1.0, file: StaticString = #filePath, line: UInt = #line) {
        let buffer = sineWave(frequency: frequency)
        let detected = detector.detectPitch(in: buffer, sampleRate: sampleRate)
        XCTAssertNotNil(detected, "No se detectó ninguna frecuencia para una señal pura de \(frequency)Hz", file: file, line: line)
        guard let detected else { return }
        let tolerance = Float(frequency * tolerancePercent / 100.0)
        XCTAssertEqual(detected, Float(frequency), accuracy: tolerance, file: file, line: line)
    }

    func testDetectsGuitarLowE() {
        assertDetects(82.41)
    }

    func testDetectsA2() {
        assertDetects(110.0)
    }

    func testDetectsA4() {
        assertDetects(440.0)
    }

    func testDetectsBassLowE() {
        assertDetects(41.20)
    }

    func testDetectsTransposedDownBassLowE() {
        // Mi grave del bajo transportado ~2 semitonos abajo.
        assertDetects(36.7)
    }

    func testSilenceReturnsNil() {
        let silence = [Float](repeating: 0, count: Int(sampleRate * 0.2))
        XCTAssertNil(detector.detectPitch(in: silence, sampleRate: sampleRate))
    }

    func testWhiteNoiseReturnsNil() {
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<Int(sampleRate * 0.2)).map { _ in
            Float.random(in: -1...1, using: &generator)
        }
        XCTAssertNil(detector.detectPitch(in: noise, sampleRate: sampleRate))
    }

    /// Reproduce el caso reportado con instrumento real: la cuerda Si (B3, ~246.94Hz) de una
    /// guitarra no se detectaba ("como si no oyera nada") mientras que el Mi agudo (E4, ~329.63Hz)
    /// sí. Con fundamental + un segundo armónico de igual amplitud, la interferencia entre ambos
    /// crea un máximo local *antes* del periodo fundamental cuya correlación no llega al umbral de
    /// claridad; el detector se rendía ahí en vez de seguir buscando el máximo del periodo real
    /// (que sí lo supera con holgura). El fallo no depende de la nota: reproduce igual para B3 y
    /// E4, lo que explica que a un instrumento real le afecte a una cuerda y no a otra según el
    /// balance de armónicos real de cada una.
    func testDetectsNoteWithInterferingHarmonicNearFundamental() {
        for frequency in [246.94, 329.63] {
            let buffer = sineWaveWithHarmonic(frequency: frequency, harmonic: 2, harmonicAmplitude: 0.5)
            let detected = detector.detectPitch(in: buffer, sampleRate: sampleRate)
            XCTAssertNotNil(detected, "No se detectó \(frequency)Hz con un segundo armónico de igual amplitud")
            guard let detected else { continue }
            XCTAssertEqual(detected, Float(frequency), accuracy: Float(frequency) * 0.01)
        }
    }

    func testBufferTooShortForConfiguredRangeReturnsNil() {
        let tinyBuffer = sineWave(frequency: 440.0, duration: 0.001)
        XCTAssertNil(detector.detectPitch(in: tinyBuffer, sampleRate: sampleRate))
    }

    func testDiagnosticsReportHighClarityForCleanSineWave() {
        let buffer = sineWave(frequency: 220)
        let result = detector.detectPitchWithDiagnostics(in: buffer, sampleRate: sampleRate)
        XCTAssertNotNil(result.frequency)
        XCTAssertGreaterThan(result.clarity, 0.9)
    }

    func testDiagnosticsReportClarityEvenWhenBelowThreshold() {
        let strictDetector = PitchDetector(clarityThreshold: 0.999)
        let buffer = sineWave(frequency: 220)
        let result = strictDetector.detectPitchWithDiagnostics(in: buffer, sampleRate: sampleRate)
        XCTAssertNil(result.frequency)
        XCTAssertGreaterThan(result.clarity, 0.5) // por debajo del umbral exigido, pero no cero
    }
}
