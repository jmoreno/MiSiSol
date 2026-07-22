//
//  ToneGeneratorTests.swift
//  MiSiSolTests
//

import AVFoundation
import XCTest
@testable import MiSiSol

final class ToneGeneratorTests: XCTestCase {

    private let sampleRate: Double = 44100

    /// Magnitud de la energía de `samples` en `targetFrequency`, mediante el algoritmo de Goertzel
    /// (una DFT de un único bin), usado aquí solo para verificar en los tests que la frecuencia
    /// dominante generada es la esperada, sin depender de ninguna librería de FFT.
    private func goertzelMagnitude(_ samples: [Float], targetFrequency: Double, sampleRate: Double) -> Double {
        let n = samples.count
        let k = (0.5 + Double(n) * targetFrequency / sampleRate)
        let omega = 2.0 * Double.pi * k.rounded(.down) / Double(n)
        let coeff = 2.0 * cos(omega)
        var s0 = 0.0, s1 = 0.0, s2 = 0.0
        for sample in samples {
            s0 = Double(sample) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let real = s1 - s2 * cos(omega)
        let imaginary = s2 * sin(omega)
        return (real * real + imaginary * imaginary).squareRoot()
    }

    func testGenerateSamplesReturnsRequestedCount() {
        let samples = ToneGenerator.generateSamples(frequency: 440, sampleRate: sampleRate, count: 1000)
        XCTAssertEqual(samples.count, 1000)
    }

    func testGenerateSamplesWithZeroCountReturnsEmpty() {
        let samples = ToneGenerator.generateSamples(frequency: 440, sampleRate: sampleRate, count: 0)
        XCTAssertTrue(samples.isEmpty)
    }

    func testGenerateSamplesStartsAtZeroPhase() {
        let samples = ToneGenerator.generateSamples(frequency: 440, sampleRate: sampleRate, count: 10, amplitude: 0.7)
        XCTAssertEqual(samples[0], 0, accuracy: 0.0001)
    }

    func testGenerateSamplesAmplitudeStaysWithinBounds() {
        let amplitude: Float = 0.6
        let samples = ToneGenerator.generateSamples(frequency: 220, sampleRate: sampleRate, count: 4410, amplitude: amplitude)
        for sample in samples {
            XCTAssertLessThanOrEqual(abs(sample), amplitude + 0.0001)
        }
    }

    func testGenerateSamplesZeroCrossingsMatchExpectedFrequency() {
        let frequency: Double = 220
        let duration = 0.5
        let count = Int(sampleRate * duration)
        let samples = ToneGenerator.generateSamples(frequency: Float(frequency), sampleRate: sampleRate, count: count)

        var crossings = 0
        for i in 1..<samples.count where (samples[i - 1] < 0) != (samples[i] < 0) {
            crossings += 1
        }
        // Una onda senoidal cruza el cero dos veces por periodo.
        let estimatedFrequency = Double(crossings) / 2.0 / duration
        XCTAssertEqual(estimatedFrequency, frequency, accuracy: frequency * 0.02)
    }

    func testGenerateSamplesDominantFrequencyMatchesTarget() {
        let targetFrequency: Double = 110
        let otherFrequency: Double = 440
        let count = 4096
        let samples = ToneGenerator.generateSamples(frequency: Float(targetFrequency), sampleRate: sampleRate, count: count)

        let magnitudeAtTarget = goertzelMagnitude(samples, targetFrequency: targetFrequency, sampleRate: sampleRate)
        let magnitudeAtOther = goertzelMagnitude(samples, targetFrequency: otherFrequency, sampleRate: sampleRate)

        XCTAssertGreaterThan(magnitudeAtTarget, magnitudeAtOther * 10)
    }

    func testPlayAndStopUpdatesPlaybackState() {
        let generator = ToneGenerator()
        XCTAssertFalse(generator.isPlaying)
        XCTAssertNil(generator.currentFrequency)

        generator.play(frequency: 440)
        XCTAssertTrue(generator.isPlaying)
        XCTAssertEqual(generator.currentFrequency, 440)

        generator.stop()
        XCTAssertFalse(generator.isPlaying)
        XCTAssertNil(generator.currentFrequency)
    }

    /// Reproduce el bug real reportado: tras parar la nota de referencia, `TunerViewModel` le
    /// devuelve la sesión de audio a `AudioEngine` para reanudar la escucha (categoría `.record`),
    /// lo que para el motor de `ToneGenerator` por su cuenta (dos categorías de sesión no pueden
    /// estar activas a la vez) sin avisar a `ToneGenerator`. Antes del fix, `ensureEngineIsRunning`
    /// se basaba en una bandera propia que nunca se enteraba de esto, así que una segunda nota de
    /// referencia se quedaba muda. Aquí se simula ese "parón externo" llamando a `engine.stop()`
    /// directamente, sin necesidad de reproducir la interacción real entre sesiones de audio.
    func testPlayRestartsEngineIfItWasStoppedExternally() {
        let generator = ToneGenerator()

        generator.play(frequency: 440)
        XCTAssertTrue(generator.engine.isRunning)

        generator.stop()
        generator.engine.stop()
        XCTAssertFalse(generator.engine.isRunning)

        generator.play(frequency: 440)
        XCTAssertTrue(
            generator.engine.isRunning,
            "Una segunda nota de referencia debe volver a arrancar el motor aunque el sistema lo hubiera parado por su cuenta"
        )
    }
}
