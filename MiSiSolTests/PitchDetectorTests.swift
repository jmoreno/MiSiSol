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

    func testBufferTooShortForConfiguredRangeReturnsNil() {
        let tinyBuffer = sineWave(frequency: 440.0, duration: 0.001)
        XCTAssertNil(detector.detectPitch(in: tinyBuffer, sampleRate: sampleRate))
    }
}
