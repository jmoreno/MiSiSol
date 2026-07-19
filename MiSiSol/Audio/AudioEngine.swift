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

    /// Último closure pasado a `start(onBuffer:)`, recordado para poder reinstalar el tap sin que
    /// quien llama tenga que volver a invocar `start` (p.ej. al reanudar tras una interrupción o
    /// un cambio de ruta, ver `beginCapture`/los observers más abajo).
    private var onBuffer: (([Float], Double) -> Void)?
    /// Si la captura estaba activa justo antes de que empezara una interrupción (llamada, Siri...).
    /// El sistema para el motor por su cuenta al empezar; esto es lo único que nos permite saber,
    /// al terminar, si había que reanudarla.
    private var wasRunningBeforeInterruption = false

    /// Se invoca (en el hilo principal) si un reintento automático de captura —tras una
    /// interrupción o un cambio de ruta— falla. `start(onBuffer:)` ya devuelve el error del primer
    /// intento directamente (`throws`); esto cubre los reintentos posteriores, que si no,
    /// fallarían en silencio y el usuario se quedaría sin saber por qué la app dejó de escuchar.
    var onRestartError: ((Error) -> Void)?

    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var configurationChangeObserver: NSObjectProtocol?

    #if DEBUG
    /// Archivo abierto mientras `startDebugRecording(to:)` está activo. Solo para diagnóstico:
    /// permite capturar exactamente el mismo audio crudo que le llega a `PitchDetector` (antes de
    /// cualquier suavizado o lógica de afinación) y compartirlo para analizarlo fuera del dispositivo,
    /// en vez de intentar adivinar por qué una señal real falla sin poder escucharla.
    private var debugRecordingFile: AVAudioFile?
    #endif

    init(bufferSize: AVAudioFrameCount = 4096) {
        self.bufferSize = bufferSize
        observeSessionAndEngineChanges()
    }

    deinit {
        [interruptionObserver, routeChangeObserver, configurationChangeObserver].forEach {
            if let token = $0 { NotificationCenter.default.removeObserver(token) }
        }
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
        self.onBuffer = onBuffer
        try beginCapture()
    }

    /// Detiene la captura y libera el tap.
    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
    }

    /// Configura la sesión de audio, instala el tap y arranca el motor. Extraído de `start` para
    /// poder repetirlo internamente (reanudar tras una interrupción, reinstalar el tap tras un
    /// cambio de ruta) sin depender de que quien llama vuelva a invocar `start(onBuffer:)`.
    private func beginCapture() throws {
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
            self?.onBuffer?(samples, format.sampleRate)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    // MARK: - Interrupciones, cambios de ruta y de configuración del motor

    /// Registra los observers de `AVAudioSession`/`AVAudioEngine` que permiten reaccionar a
    /// eventos que están completamente fuera de nuestro control: una llamada entrante, Siri,
    /// conectar o desconectar unos auriculares... Sin esto, cualquiera de ellos deja el afinador
    /// "sordo" hasta que el usuario cierra y reabre la app.
    ///
    /// Los tres llegan en un hilo arbitrario (no necesariamente el principal): se despachan al
    /// hilo principal antes de tocar `isRunning`/`onBuffer` o de llamar a `beginCapture()`, para
    /// serializarlos con las llamadas a `start()`/`stop()` (que en esta app siempre llegan desde
    /// el hilo principal) sin necesitar un lock nuevo.
    private func observeSessionAndEngineChanges() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            DispatchQueue.main.async { self?.handleInterruption(notification) }
        }

        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            DispatchQueue.main.async { self?.handleRouteChange(notification) }
        }

        // Con `object: engine` (no `nil`): esta notificación la puede disparar cualquier
        // AVAudioEngine de la app (también el de ToneGenerator), y solo nos interesa la nuestra.
        configurationChangeObserver = center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.restartIfRunning() }
        }
    }

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            // El sistema para la captura por su cuenta al empezar la interrupción; solo
            // reflejamos el estado y recordamos si había que reanudarla al terminar.
            wasRunningBeforeInterruption = isRunning
            isRunning = false
        case .ended:
            defer { wasRunningBeforeInterruption = false }
            guard wasRunningBeforeInterruption else { return }
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt
            let options = optionsValue.map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
            guard options.contains(.shouldResume) else { return }
            attemptRestart()
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard isRunning,
              let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .routeConfigurationChange, .override:
            // El formato real del hardware (sample rate, canales) puede haber cambiado con la
            // nueva ruta: reinstalamos el tap para que lo recoja, en vez de seguir con el antiguo.
            attemptRestart()
        default:
            // p.ej. `.categoryChange`: lo disparamos nosotros mismos al (re)configurar la sesión
            // en `beginCapture`, no es un cambio real de hardware — reaccionar también aquí
            // provocaría un bucle de reinicios.
            break
        }
    }

    private func restartIfRunning() {
        guard isRunning else { return }
        attemptRestart()
    }

    private func attemptRestart() {
        do {
            try beginCapture()
        } catch {
            onRestartError?(error)
        }
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
