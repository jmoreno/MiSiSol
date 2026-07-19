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

    /// Reproduce el error de octava confirmado con grabaciones reales: el Sol grave de una
    /// guitarra (G3, ~196.00Hz) se detectaba como el Sol una octava por encima (~392Hz) porque su
    /// segundo armónico, mucho más fuerte que la fundamental, cruzaba el umbral de claridad
    /// primero (a mitad de periodo) con una correlación alta, y el detector se quedaba ahí sin
    /// comprobar que el periodo real (el doble de ese lag) tenía una correlación todavía más alta.
    /// El mismo patrón apareció también en el Re grave de un bajo (D2 detectado como D3) en las
    /// mismas grabaciones.
    func testCorrectsOctaveErrorWhenSecondHarmonicDominatesFundamental() {
        let buffer = sineWaveWithHarmonic(frequency: 196.00, harmonic: 2, harmonicAmplitude: 1.0, amplitude: 0.2)
        let detected = detector.detectPitch(in: buffer, sampleRate: sampleRate)
        XCTAssertNotNil(detected, "No se detectó ninguna frecuencia con fundamental débil + 2º armónico dominante")
        guard let detected else { return }
        XCTAssertEqual(detected, 196.00, accuracy: 196.00 * 0.01, "Se detectó \(detected)Hz: probablemente enganchado al 2º armónico (~392Hz) en vez de a la fundamental")
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
        // 1.5 es un umbral imposible de alcanzar (la claridad, un coeficiente de correlación,
        // nunca supera 1): a propósito, para no acoplar el test a lo cerca de 1.0 que llegue una
        // sinusoide limpia en la implementación actual (con diezmado y sin ventana de Hann llega
        // a ~0.9998, por lo que un umbral como 0.999 dejaría de fallar y rompería este test).
        let strictDetector = PitchDetector(clarityThreshold: 1.5)
        let buffer = sineWave(frequency: 220)
        let result = strictDetector.detectPitchWithDiagnostics(in: buffer, sampleRate: sampleRate)
        XCTAssertNil(result.frequency)
        XCTAssertGreaterThan(result.clarity, 0.5) // por debajo del umbral exigido, pero no cero
    }

    // MARK: - Diezmado

    func testDecimationFactorAt48kHzHardwareSampleRateIsFour() {
        // Caso de referencia del historial de depuración: a 48kHz (la frecuencia de muestreo real
        // de la mayoría de dispositivos) con maxFrequency=1200Hz, diezmar por 4 deja 12kHz, 10x
        // maxFrequency de margen de sobra sobre el mínimo de Nyquist (2x).
        XCTAssertEqual(PitchDetector.decimationFactor(for: 48000, maxFrequency: 1200), 4)
    }

    func testDecimationFactorNeverGoesBelowOne() {
        // A una frecuencia de muestreo baja (o un maxFrequency alto) donde ni el propio hardware
        // llega a 10x maxFrequency, no tiene sentido "diezmar por 0": no se diezma en absoluto.
        XCTAssertEqual(PitchDetector.decimationFactor(for: 8000, maxFrequency: 1200), 1)
    }

    func testDetectsAccuratelyAt48kHzSampleRate() {
        // El hardware real no siempre está a 44.1kHz (el valor que usan el resto de tests): hay
        // que confirmar que el diezmado (activado por defecto) no introduce error a la frecuencia
        // de muestreo real de la mayoría de dispositivos.
        let sr: Double = 48000
        let frequency = 110.0
        let sampleCount = Int(sr * 0.2)
        let buffer = (0..<sampleCount).map { i in
            Float(0.8 * sin(2.0 * Double.pi * frequency * Double(i) / sr))
        }
        let detected = detector.detectPitch(in: buffer, sampleRate: sr)
        XCTAssertNotNil(detected)
        guard let detected else { return }
        XCTAssertEqual(detected, Float(frequency), accuracy: Float(frequency) * 0.01)
    }

    func testDecimationDoesNotChangeDetectionCompatedToNotDecimating() {
        let withDecimation = PitchDetector(usesDecimation: true)
        let withoutDecimation = PitchDetector(usesDecimation: false)
        let buffer = sineWave(frequency: 196.00)

        let detectedWithDecimation = withDecimation.detectPitch(in: buffer, sampleRate: sampleRate)
        let detectedWithoutDecimation = withoutDecimation.detectPitch(in: buffer, sampleRate: sampleRate)

        XCTAssertNotNil(detectedWithDecimation)
        XCTAssertNotNil(detectedWithoutDecimation)
        guard let detectedWithDecimation, let detectedWithoutDecimation else { return }
        XCTAssertEqual(detectedWithDecimation, detectedWithoutDecimation, accuracy: 1.0, "Diezmar no debería cambiar perceptiblemente la frecuencia detectada")
    }
}
