//
//  PitchDetectionCorpusTests.swift
//  MiSiSolTests
//
//  Corre la detección de pitch contra grabaciones reales (ver MiSiSolTests/Fixtures/README.md),
//  la misma validación que antes se hacía a mano con un script en Python fuera del repo.
//

import AVFoundation
import XCTest
@testable import MiSiSol

final class PitchDetectionCorpusTests: XCTestCase {

    private struct ManifestEntry: Decodable {
        let file: String
        let instrument: String
        let note: String
        let expectedFrequency: Double
        let toleranceCents: Double
        let comment: String?
    }

    /// Mismo tamaño de buffer que `AudioEngine` usa en producción: el corpus debe procesarse
    /// igual que llegaría el audio real, no en un único bloque gigante.
    private static let productionBufferSize = 4096

    private static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    private func loadManifest() throws -> [ManifestEntry] {
        let manifestURL = Self.fixturesDirectory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        return try JSONDecoder().decode([ManifestEntry].self, from: data)
    }

    private func loadSamples(from url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        return (samples, format.sampleRate)
    }

    /// Procesa `fileURL` buffer a buffer a través de `PitchDetector` y la mediana móvil de
    /// `TunerViewModel` (sus valores por defecto, los mismos que usa la app real), y comprueba que
    /// la nota coincide con la esperada dentro de la tolerancia.
    ///
    /// Se compara contra la mediana de *todas* las lecturas suavizadas (no nulas) del fichero
    /// entero, no contra la última ni contra el estado final: estas grabaciones duran varios
    /// segundos y no son una sola nota limpia de principio a fin (silencio entre intentos, la
    /// cuerda apagándose, ruido de manos al final...). Tomar solo la última lectura es frágil —
    /// una lectura suelta de ruido al final del fichero, después de la parte sostenida y bien
    /// afinada, bastaría para hacer fallar el test— mientras que la mediana de toda la serie
    /// necesita que la mayoría de las lecturas coincidan, igual que se hizo al validar esto mismo
    /// manualmente con las grabaciones (ver historial de depuración en Docs/Specs.md).
    private func assertDetectsExpectedNote(
        _ entry: ManifestEntry,
        at fileURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let (samples, sampleRate) = try loadSamples(from: fileURL)
        let detector = PitchDetector()
        let viewModel = TunerViewModel(instrument: .guitar) // instrumento/cuerda no importan aquí: solo miramos detectedFrequency

        var smoothedReadings: [Float] = []
        var offset = 0
        while offset + Self.productionBufferSize <= samples.count {
            let chunk = Array(samples[offset..<(offset + Self.productionBufferSize)])
            let frequency = detector.detectPitch(in: chunk, sampleRate: sampleRate)
            viewModel.processPitch(frequency)
            if let detected = viewModel.detectedFrequency {
                smoothedReadings.append(detected)
            }
            offset += Self.productionBufferSize
        }

        XCTAssertFalse(smoothedReadings.isEmpty, "\(entry.file): no se llegó a detectar ninguna nota", file: file, line: line)
        guard !smoothedReadings.isEmpty else { return }
        let detected = Self.median(of: smoothedReadings)

        let cents = 1200 * log2(Double(detected) / entry.expectedFrequency)
        XCTAssertLessThanOrEqual(
            abs(cents),
            entry.toleranceCents,
            "\(entry.file) (\(entry.note)): detectado \(detected)Hz, esperado \(entry.expectedFrequency)Hz "
                + "(\(String(format: "%+.0f", cents)) cents de diferencia, tolerancia ±\(entry.toleranceCents))",
            file: file,
            line: line
        )
    }

    private static func median(of values: [Float]) -> Float {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        } else {
            return sorted[mid]
        }
    }

    func testCorpusMatchesExpectedNoteWithinTolerance() throws {
        let manifest = try loadManifest()
        XCTAssertFalse(manifest.isEmpty, "El manifiesto no debería estar vacío")

        var missingFiles: [String] = []
        var checkedAtLeastOne = false

        for entry in manifest {
            let fileURL = Self.fixturesDirectory.appendingPathComponent(entry.file)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                missingFiles.append(entry.file)
                continue
            }
            checkedAtLeastOne = true
            try assertDetectsExpectedNote(entry, at: fileURL)
        }

        guard checkedAtLeastOne else {
            throw XCTSkip(
                "Ninguna de las grabaciones del corpus está presente en \(Self.fixturesDirectory.path). "
                    + "Ver MiSiSolTests/Fixtures/README.md para añadirlas."
            )
        }

        if !missingFiles.isEmpty {
            // No hace fallar el test (el resto del corpus sí se comprobó): solo deja constancia de
            // qué faltaba, por si el checkout está incompleto.
            print("⚠️ Faltan del corpus de grabaciones: \(missingFiles.joined(separator: ", "))")
        }
    }
}
