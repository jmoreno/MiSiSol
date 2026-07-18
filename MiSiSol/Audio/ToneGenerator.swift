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

    private let engine = AVAudioEngine()
    private let sampleRate: Double
    private let state = TonePhaseState()
    private var isEngineRunning = false

    private(set) var isPlaying = false
    private(set) var currentFrequency: Float?

    /// Duración del fundido de entrada/salida al empezar o parar una nota. Sin esto, la amplitud
    /// salta de golpe entre 0 y el valor objetivo y se oye como un chasquido de estática.
    private static let rampDuration: Double = 0.015

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
    func play(frequency: Float, amplitude: Float = 0.5) {
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

    private func ensureEngineIsRunning() {
        guard !isEngineRunning else { return }

        // Se configura la sesión aquí (no solo en AudioEngine) para que reproducir una nota
        // funcione aunque la captura de micrófono no se haya llegado a arrancar todavía (p.ej.
        // el usuario pulsa "Reproducir" mientras se resuelve el permiso de micrófono al abrir
        // la app). Es idempotente: si ya estaba configurada, esta llamada no hace nada distinto.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetooth])
        try? session.setActive(true)

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

        do {
            engine.prepare()
            try engine.start()
            isEngineRunning = true
        } catch {
            engine.detach(node)
        }
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
