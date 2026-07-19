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

    #if DEBUG
    /// Archivo abierto mientras `startDebugRecording(to:)` está activo. Solo para diagnóstico:
    /// permite capturar exactamente el mismo audio crudo que le llega a `PitchDetector` (antes de
    /// cualquier suavizado o lógica de afinación) y compartirlo para analizarlo fuera del dispositivo,
    /// en vez de intentar adivinar por qué una señal real falla sin poder escucharla.
    private var debugRecordingFile: AVAudioFile?
    #endif

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
        // .record (no .playAndRecord: mientras se escucha no se reproduce nada — playReferenceNote()
        // ya para esta captura antes de sonar) + .measurement, sin AGC/cancelación de eco/supresión
        // de ruido: ese procesado, pensado para llamadas, atenúa señales tonales sostenidas y
        // graves, justo las fundamentales de E2 (82Hz) y E1 (41Hz). Sin `.allowBluetooth`: un
        // micrófono Bluetooth por HFP tiene banda de voz (~300-3400Hz) muy lejos del instrumento,
        // así que si hay auriculares o un coche emparejados no queremos que la entrada se enrute ahí.
        //
        // Nota histórica (ver Specs.md): `.measurement` ya se probó una vez y se revirtió a
        // `.default` porque "la señal quedaba floja y bajaba la claridad". Aquella prueba se hizo
        // sin el diezmado ni el backpressure de `PitchAnalysisGate`, así que probablemente estaba
        // contaminada por el atasco de la cola de análisis, no por la ausencia de AGC en sí: la
        // correlación normalizada es invariante a la amplitud, lo que importa es la relación
        // señal/ruido, no el volumen. `setInputGain` de abajo compensa la falta de AGC cuando el
        // hardware lo permite.
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        if session.isInputGainSettable {
            try? session.setInputGain(1.0)
        }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            #if DEBUG
            if let file = self?.debugRecordingFile {
                try? file.write(from: buffer)
            }
            #endif
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

    #if DEBUG
    /// Empieza a grabar en paralelo el audio crudo del tap (el mismo `[Float]` que recibe
    /// `PitchDetector`, antes de cualquier suavizado) a un .wav, para poder compartirlo y analizar
    /// un caso real que falla sin depender de describirlo de palabra. Solo tiene efecto mientras
    /// la captura ya está activa (`start(onBuffer:)`); si se llama antes, no hay tap que grabar.
    func startDebugRecording(to url: URL) throws {
        let format = engine.inputNode.outputFormat(forBus: 0)
        debugRecordingFile = try AVAudioFile(forWriting: url, settings: format.settings)
    }

    /// Cierra el archivo de grabación de depuración. Seguro de llamar aunque no hubiera ninguna
    /// grabación en curso.
    func stopDebugRecording() {
        debugRecordingFile = nil
    }
    #endif
}
