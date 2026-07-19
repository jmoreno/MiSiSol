//
//  PitchAnalysisGateTests.swift
//  MiSiSolTests
//

import XCTest
@testable import MiSiSol

final class PitchAnalysisGateTests: XCTestCase {

    func testFirstEntrySucceedsAndBlocksUntilLeave() {
        let gate = PitchAnalysisGate()
        XCTAssertTrue(gate.tryEnter(), "El primer buffer debe aceptarse")
        XCTAssertFalse(gate.tryEnter(), "Un buffer que llega mientras el anterior sigue en curso debe descartarse")
        XCTAssertFalse(gate.tryEnter(), "Sigue descartando mientras no se llame a leave()")

        gate.leave()
        XCTAssertTrue(gate.tryEnter(), "Tras terminar el análisis anterior, el siguiente buffer se acepta")
    }

    /// Reproduce el escenario real: un análisis lento (controlado con semáforos, no con sleeps,
    /// para que el test sea determinista) procesando en background mientras llegan varios buffers
    /// más desde el "hilo de captura". Solo el primero se procesa; los que llegan mientras tanto
    /// se descartan sin encolarse; y tras liberarse el análisis lento, el siguiente buffer que
    /// llega sí se procesa.
    func testDiscardsBuffersWhileSlowAnalysisInProgressAndProcessesTheNextOneAfterwards() {
        let gate = PitchAnalysisGate()
        let analysisStarted = DispatchSemaphore(value: 0)
        let releaseAnalysis = DispatchSemaphore(value: 0)
        let firstBufferFinished = DispatchSemaphore(value: 0)

        var processedBuffers: [Int] = []
        let processedLock = NSLock()
        func record(_ id: Int) {
            processedLock.lock()
            processedBuffers.append(id)
            processedLock.unlock()
        }

        // Buffer 1: simula un análisis lento (p.ej. una build sin optimizar tardando más que la
        // duración de un buffer real).
        XCTAssertTrue(gate.tryEnter())
        DispatchQueue.global().async {
            defer {
                gate.leave()
                firstBufferFinished.signal()
            }
            analysisStarted.signal()
            releaseAnalysis.wait()
            record(1)
        }
        analysisStarted.wait()

        // Buffers 2, 3 y 4 "llegan" mientras el 1 sigue en curso: se descartan sin encolar nada.
        XCTAssertFalse(gate.tryEnter(), "buffer 2 debe descartarse")
        XCTAssertFalse(gate.tryEnter(), "buffer 3 debe descartarse")
        XCTAssertFalse(gate.tryEnter(), "buffer 4 debe descartarse")

        releaseAnalysis.signal()
        firstBufferFinished.wait() // determinista: esperamos a que el 1 termine y libere el gate

        // Buffer 5 llega después de liberarse: se acepta y se procesa.
        XCTAssertTrue(gate.tryEnter(), "tras liberarse el análisis anterior, el siguiente buffer se acepta")
        record(5)
        gate.leave()

        XCTAssertEqual(processedBuffers.sorted(), [1, 5], "Solo el buffer lento (1) y el que llega tras liberarse (5) deben procesarse; 2, 3 y 4 se descartaron")
    }
}
