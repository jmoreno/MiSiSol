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
    private var sourceNode: AVAudioSourceNode?

    private(set) var isPlaying = false
    private(set) var currentFrequency: Float?

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

    /// Empieza a reproducir por el altavoz una nota continua a `frequency` Hz.
    /// Si ya había una nota sonando, la sustituye.
    func play(frequency: Float, amplitude: Float = 0.5) {
        stop()

        let phaseIncrement = 2.0 * Double.pi * Double(frequency) / sampleRate
        // El estado de fase se aísla en una clase aparte (en vez de una propiedad de ToneGenerator)
        // para que el closure de render de audio, que se ejecuta en el hilo real-time de audio,
        // no capture `self` ni dependa de su aislamiento de actor.
        let state = TonePhaseState()

        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return }
        let node = AVAudioSourceNode { _, _, frameCount, audioBufferList in
            let bufferList = UnsafeMutableAudioBufferListPointer(audioBufferList)
            var phase = state.phase
            for frame in 0..<Int(frameCount) {
                let value = amplitude * Float(sin(phase))
                phase += phaseIncrement
                if phase > 2 * .pi { phase -= 2 * .pi }
                for buffer in bufferList {
                    UnsafeMutableBufferPointer<Float>(buffer)[frame] = value
                }
            }
            state.phase = phase
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node

        do {
            try engine.start()
            isPlaying = true
            currentFrequency = frequency
        } catch {
            engine.detach(node)
            sourceNode = nil
            isPlaying = false
            currentFrequency = nil
        }
    }

    /// Detiene la reproducción y libera el nodo generador.
    func stop() {
        guard let sourceNode else { return }
        engine.stop()
        engine.detach(sourceNode)
        self.sourceNode = nil
        isPlaying = false
        currentFrequency = nil
    }
}

/// Estado mutable de fase para el closure de render de audio de `ToneGenerator.play`.
/// `AVAudioSourceNode` invoca el closure en el hilo real-time de audio, que lo llama de forma
/// serial por diseño, así que no hay condición de carrera real pese a que el compilador no
/// pueda comprobarlo estáticamente.
nonisolated private final class TonePhaseState: @unchecked Sendable {
    var phase: Double = 0
}
