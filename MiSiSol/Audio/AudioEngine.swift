//
//  AudioEngine.swift
//  MiSiSol
//
//  Wrapper sobre AVAudioEngine: captura audio del micrófono y expone los buffers capturados.
//  No hace detección de pitch aquí; solo entrega [Float] + sampleRate para que
//  TunerViewModel se lo pase a PitchDetector.
//

import AVFoundation

// `nonisolated` por la misma razón que ToneGenerator: el tap de audio se instala y se invoca
// desde el hilo real-time de captura, no desde @MainActor.
nonisolated final class AudioEngine {

    /// Tamaño de buffer del tap, en muestras. 4096 muestras a 44.1kHz son ~93ms, más del doble
    /// del periodo del Mi grave del bajo transportado varios semitonos abajo (ver
    /// `PitchDetector.minimumBufferSize`), y sigue dando una latencia razonable para el afinador.
    private let bufferSize: AVAudioFrameCount
    private let engine = AVAudioEngine()

    private(set) var isRunning = false

    init(bufferSize: AVAudioFrameCount = 4096) {
        self.bufferSize = bufferSize
    }

    /// Estado actual del permiso de micrófono.
    static var microphonePermission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }

    /// Solicita permiso de micrófono si aún no se ha concedido o denegado.
    static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Empieza a capturar audio del micrófono. Cada buffer capturado se entrega a `onBuffer`
    /// como `[Float]` (canal 0) junto con el sampleRate real del hardware.
    ///
    /// `onBuffer` se invoca desde el hilo real-time de captura de audio, no desde el hilo
    /// principal: quien lo use (p.ej. TunerViewModel) es responsable de saltar a @MainActor
    /// antes de tocar estado de UI.
    func start(onBuffer: @escaping ([Float], Double) -> Void) throws {
        stop()

        let session = AVAudioSession.sharedInstance()
        // El modo .measurement se probó para evitar el procesado de voz de .default en
        // .playAndRecord, pero también desactiva el control automático de ganancia de *entrada*:
        // sin tocar el móvil pegado al instrumento, la señal capturada queda floja y eso bajaba
        // la claridad de la autocorrelación en general (no solo en cuerdas graves). .default con
        // AGC da una señal más fuerte a costa de algo de procesado, mejor tradeoff aquí.
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { buffer, _ in
            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength))
            onBuffer(samples, format.sampleRate)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    /// Detiene la captura y libera el tap.
    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }
}
