//
//  ToneGenerator.swift
//  MiSiSol
//
//  Genera una onda senoidal pura y la reproduce por el altavoz. La generación de samples
//  está separada de la reproducción para poder testear la forma de onda sin audio real.
//

import AVFoundation

// `nonisolated` porque el nodo de render de `play(frequency:amplitude:)` se ejecuta en el hilo
// real-time de audio: si el tipo quedara aislado a @MainActor por defecto (ajuste del proyecto),
// el runtime de concurrencia intentaría intervenir ese closure en tiempo real, lo cual no es seguro.
nonisolated final class ToneGenerator {

    // No `private`: los tests necesitan poder parar el motor directamente para simular lo que
    // hace el sistema cuando `AudioEngine` reclama la sesión de audio compartida para escuchar
    // (ver `ToneGeneratorTests.testPlayRestartsEngineIfItWasStoppedExternally`), sin depender de
    // reproducir esa interacción real entre sesiones de audio dentro de un test.
    let engine = AVAudioEngine()
    private let sampleRate: Double
    private let state = TonePhaseState()
    /// Si el nodo de render ya está `attach`ado al motor. A diferencia de si el motor está
    /// arrancado (`engine.isRunning`, que puede cambiar por causas externas), esto solo pasa una
    /// vez: intentar volver a `attach`/`connect` el mismo nodo lanzaría una excepción.
    private var isNodeAttached = false

    private(set) var isPlaying = false
    private(set) var currentFrequency: Float?

    /// Duración del fundido de entrada/salida al empezar o parar una nota. Sin esto, la amplitud
    /// salta de golpe entre 0 y el valor objetivo y se oye como un chasquido de estática.
    /// No es `private`: `TunerViewModel` la usa para esperar a que el fundido de salida termine
    /// antes de devolverle la sesión de audio a `AudioEngine` (ver `stopReferenceNote`).
    static let rampDuration: Double = 0.015

    init(sampleRate: Double = 44100) {
        self.sampleRate = sampleRate
    }

    /// Genera `count` muestras de una onda senoidal pura a `frequency` Hz, empezando en fase 0.
    /// Función pura, sin tocar AVAudioEngine: es lo que permite testear la forma de onda generada
    /// sin necesidad de reproducir audio real.
    static func generateSamples(frequency: Float, sampleRate: Double, count: Int, amplitude: Float = 0.5) -> [Float] {
        guard count > 0 else { return [] }
        let phaseIncrement = 2.0 * Double.pi * Double(frequency) / sampleRate
        var phase: Double = 0
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            samples[i] = amplitude * Float(sin(phase))
            phase += phaseIncrement
            if phase > 2 * .pi { phase -= 2 * .pi }
        }
        return samples
    }

    /// Empieza a reproducir por el altavoz una nota continua a `frequency` Hz, con un fundido de
    /// entrada corto para evitar chasquidos. Si ya había una nota sonando, cambia de frecuencia
    /// sin reiniciar el motor de audio (reiniciarlo en cada nota es lo que producía el chasquido
    /// al arrancar: enganchar/desenganchar la ruta de audio del hardware sí hace "pop" aunque la
    /// forma de onda en sí no tenga ningún salto).
    func play(frequency: Float, amplitude: Float = 0.8) {
        configureSessionForPlayback()
        ensureEngineIsRunning()
        state.targetFrequency = Double(frequency)
        state.targetAmplitude = Double(amplitude)
        isPlaying = true
        currentFrequency = frequency
    }

    /// Dejar de sonar con un fundido de salida corto, en vez de parar el motor de golpe.
    /// El motor se queda preparado (en silencio) para la próxima vez.
    func stop() {
        state.targetAmplitude = 0
        isPlaying = false
        currentFrequency = nil
    }

    /// Configura la sesión de audio para reproducción en cada `play()` (no solo la primera vez),
    /// para que reproducir una nota funcione aunque la captura de micrófono no se haya llegado a
    /// arrancar todavía (p.ej. el usuario pulsa "Reproducir" mientras se resuelve el permiso de
    /// micrófono al abrir la app).
    ///
    /// Categoría `.playback` (no `.playAndRecord`): no necesitamos capturar nada mientras suena la
    /// referencia, y así no compite con la categoría `.record` que usa `AudioEngine` al escuchar
    /// (solo una puede estar activa a la vez). `.playback` ya enruta al altavoz y admite salida
    /// Bluetooth A2DP sin necesidad de opciones adicionales.
    private func configureSessionForPlayback() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    /// Arranca el motor si hace falta. Se llama en cada `play()`, no solo la primera vez: cuando
    /// `AudioEngine` retoma la sesión compartida para escuchar (categoría `.record`), el sistema
    /// para este motor por su cuenta (dos categorías de sesión no pueden estar activas a la vez),
    /// y sin comprobar el estado real (`engine.isRunning`) en vez de una bandera propia, una
    /// segunda nota de referencia se quedaría muda: el nodo seguiría "attachado" pero el motor ya
    /// no, y nada volvería a arrancarlo.
    private func ensureEngineIsRunning() {
        if !isNodeAttached {
            attachRenderNode()
            isNodeAttached = true
        }

        guard !engine.isRunning else { return }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            // Se reintentará en el próximo play(): el nodo ya sigue attachado, no hace falta
            // volver a crearlo.
        }
    }

    private func attachRenderNode() {
        // El formato se pide al propio mainMixerNode en vez de fijarlo a 44.1kHz: el sample rate
        // real del hardware varía según el dispositivo y la ruta de audio activa (auriculares,
        // Bluetooth...). Usar un formato que no coincide con el del engine es una causa habitual
        // de fallos de arranque intermitentes en dispositivo real (el simulador siempre usa
        // 44.1kHz, por eso ahí no se notaba).
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let effectiveSampleRate = format.sampleRate > 0 ? format.sampleRate : sampleRate
        state.rampStep = 1.0 / (Self.rampDuration * effectiveSampleRate)

        // El estado (fase, amplitud, objetivo) se aísla en una clase aparte (en vez de propiedades
        // de ToneGenerator) para que el closure de render de audio, que se ejecuta en el hilo
        // real-time de audio, no capture `self` ni dependa de su aislamiento de actor.
        let node = AVAudioSourceNode(format: format) { [state] _, _, frameCount, audioBufferList in
            let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
            var phase = state.phase
            var amplitude = state.currentAmplitude
            let target = state.targetAmplitude
            let phaseIncrement = 2.0 * Double.pi * state.targetFrequency / effectiveSampleRate
            for frame in 0..<Int(frameCount) {
                if amplitude < target {
                    amplitude = min(target, amplitude + state.rampStep)
                } else if amplitude > target {
                    amplitude = max(target, amplitude - state.rampStep)
                }
                let value = Float(amplitude) * Float(sin(phase))
                phase += phaseIncrement
                if phase > 2 * .pi { phase -= 2 * .pi }
                for buffer in bufferList {
                    UnsafeMutableBufferPointer<Float>(buffer)[frame] = value
                }
            }
            state.phase = phase
            state.currentAmplitude = amplitude
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }
}

/// Estado compartido entre quien llama a `play()`/`stop()` (hilo principal) y el closure de
/// render de audio (hilo real-time): `targetFrequency`/`targetAmplitude` los escribe el primero
/// y los lee el segundo en cada callback; `phase`/`currentAmplitude`/`rampStep` solo los toca el
/// hilo de render. Son todo `Double` sencillos con un único escritor y un único lector por campo,
/// lectura/escritura atómica a nivel de hardware: suficiente aquí sin necesidad de un lock.
nonisolated private final class TonePhaseState: @unchecked Sendable {
    var phase: Double = 0
    var currentAmplitude: Double = 0
    var rampStep: Double = 1
    var targetFrequency: Double = 440
    var targetAmplitude: Double = 0
}
