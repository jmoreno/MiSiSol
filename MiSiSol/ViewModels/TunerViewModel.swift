//
//  TunerViewModel.swift
//  MiSiSol
//
//  Conecta la captura de audio (AudioEngine + PitchDetector) y la reproducción de nota de
//  referencia (ToneGenerator) con la UI del afinador.
//

import Foundation
import Observation

/// Cómo se elige la cuerda objetivo con la que se compara la frecuencia detectada.
enum TunerMode: String, CaseIterable, Identifiable {
    /// El usuario elige la cuerda objetivo a mano (ver `selectString(at:)`).
    case manual
    /// La cuerda objetivo se recalcula sola: la más cercana en cents a lo que se está escuchando.
    case automatic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .automatic: return "Automático"
        }
    }
}

/// Estado de afinación de la cuerda seleccionada respecto a su nota objetivo.
enum TuningStatus: Equatable {
    /// No hay señal de entrada suficientemente clara.
    case noSignal
    /// La frecuencia detectada está por debajo del objetivo: hay que subir el tono.
    case tooLow
    /// La frecuencia detectada está por encima del objetivo: hay que bajar el tono.
    case tooHigh
    /// La desviación está dentro del margen de cents configurado.
    case inTune
}

// `nonisolated` para evitar que el aislamiento a @MainActor por defecto del módulo genere un
// deinit con salto de actor (ver el mismo razonamiento en ToneGenerator/AudioEngine). El propio
// código salta explícitamente a @MainActor donde hace falta (ver `startListening()`), así que
// las actualizaciones de estado observable siguen ocurriendo en el hilo principal.
@Observable
nonisolated final class TunerViewModel {

    // MARK: - Dependencias

    private let pitchDetector: PitchDetector
    private let audioEngine: AudioEngine
    private let toneGenerator: ToneGenerator
    /// Cola serial donde se ejecuta `PitchDetector.detectPitch`, fuera del hilo real-time de audio.
    /// Es serial (no la cola global concurrente) para que los buffers se procesen en el mismo
    /// orden en que llegan y no se solape el análisis de dos buffers a la vez.
    private let pitchQueue = DispatchQueue(label: "com.zinkinapps.misisol.pitch", qos: .userInitiated)

    /// Margen de cents dentro del cual se considera "afinado".
    let inTuneCentsMargin: Double
    /// Número de lecturas usadas en la media móvil de suavizado de la frecuencia detectada.
    private let smoothingWindowSize: Int

    // MARK: - Estado observable

    private(set) var instrument: Instrument
    private(set) var tuning: Tuning
    private(set) var selectedStringIndex: Int = 0
    private(set) var mode: TunerMode = .manual

    /// En modo automático, solo cambiamos la cuerda objetivo si la nueva candidata está al menos
    /// esto más cerca (en cents) que la actualmente seleccionada. Evita que el indicador parpadee
    /// entre dos cuerdas vecinas cuando la nota está justo en el punto medio entre ambas.
    private let autoSwitchHysteresisCents: Double = 10

    var detectedFrequency: Float?
    var detectedNote: Note?
    var centsOffset: Double = 0
    var status: TuningStatus = .noSignal

    private var recentFrequencies: [Float] = []
    private var wasListeningBeforeReferenceNote = false

    /// Lecturas sin detección clara consecutivas hasta ahora. No se resetea el suavizado a la
    /// primera lectura fallida: una señal real (ruido, un ataque más flojo, un instante de menor
    /// claridad) puede fallar el umbral puntualmente sin que el usuario haya dejado de tocar.
    private var consecutiveMissedReadings = 0
    private let maxConsecutiveMissedReadings: Int

    // MARK: - Init

    init(
        instrument: Instrument = .guitar,
        pitchDetector: PitchDetector = PitchDetector(),
        audioEngine: AudioEngine = AudioEngine(),
        toneGenerator: ToneGenerator = ToneGenerator(),
        inTuneCentsMargin: Double = 5.0,
        smoothingWindowSize: Int = 5,
        maxConsecutiveMissedReadings: Int = 3
    ) {
        self.instrument = instrument
        self.tuning = .standard(for: instrument)
        self.pitchDetector = pitchDetector
        self.audioEngine = audioEngine
        self.toneGenerator = toneGenerator
        self.inTuneCentsMargin = inTuneCentsMargin
        self.smoothingWindowSize = smoothingWindowSize
        self.maxConsecutiveMissedReadings = maxConsecutiveMissedReadings
    }

    /// Nota objetivo de la cuerda actualmente seleccionada.
    var targetNote: Note? {
        guard tuning.strings.indices.contains(selectedStringIndex) else { return nil }
        return tuning.strings[selectedStringIndex]
    }

    // MARK: - Selección de instrumento / afinación / cuerda

    func selectInstrument(_ newInstrument: Instrument) {
        instrument = newInstrument
        tuning = .standard(for: newInstrument)
        selectedStringIndex = 0
    }

    func selectTuning(_ newTuning: Tuning) {
        tuning = newTuning
        if !tuning.strings.indices.contains(selectedStringIndex) {
            selectedStringIndex = max(0, tuning.strings.count - 1)
        }
    }

    func transpose(bySemitones offset: Int) {
        selectTuning(.transposedStandard(for: instrument, bySemitones: offset))
    }

    func selectString(at index: Int) {
        guard tuning.strings.indices.contains(index) else { return }
        selectedStringIndex = index
    }

    func setMode(_ newMode: TunerMode) {
        mode = newMode
    }

    // MARK: - Captura de audio

    func startListening() {
        // El closure de `onBuffer` se invoca en el hilo real-time de captura de audio: debe
        // volver lo antes posible. `PitchDetector` hace autocorrelación sobre miles de muestras,
        // demasiado costoso para ese hilo (si tarda más que la duración de un buffer, se acumula
        // retraso o se pierden buffers). Por eso el cálculo se manda a una cola en background, y
        // solo el salto final a @MainActor toca el hilo principal para actualizar la UI.
        try? audioEngine.start { [pitchDetector, pitchQueue, weak self] samples, sampleRate in
            pitchQueue.async {
                let pitch = pitchDetector.detectPitch(in: samples, sampleRate: sampleRate)
                Task { @MainActor in
                    self?.processPitch(pitch)
                }
            }
        }
    }

    func stopListening() {
        audioEngine.stop()
    }

    // MARK: - Procesado de pitch

    /// Procesa una nueva lectura de frecuencia (o `nil` si no hay señal clara): aplica el
    /// suavizado (media móvil) y actualiza nota detectada, cents respecto a la cuerda objetivo
    /// y estado. Público y directo para poder testear la lógica inyectando frecuencias
    /// simuladas, sin depender de AVAudioEngine real.
    func processPitch(_ frequency: Float?) {
        guard let frequency, frequency > 0 else {
            consecutiveMissedReadings += 1
            guard consecutiveMissedReadings >= maxConsecutiveMissedReadings else { return }
            recentFrequencies.removeAll()
            detectedFrequency = nil
            detectedNote = nil
            centsOffset = 0
            status = .noSignal
            return
        }
        consecutiveMissedReadings = 0

        recentFrequencies.append(frequency)
        if recentFrequencies.count > smoothingWindowSize {
            recentFrequencies.removeFirst(recentFrequencies.count - smoothingWindowSize)
        }
        let smoothed = recentFrequencies.reduce(0, +) / Float(recentFrequencies.count)
        detectedFrequency = smoothed
        detectedNote = Note.closest(to: Double(smoothed)).note

        if mode == .automatic {
            selectNearestString(toFrequency: smoothed)
        }

        guard let targetNote else {
            centsOffset = 0
            status = .noSignal
            return
        }

        let cents = 1200 * log2(Double(smoothed) / targetNote.frequency)
        centsOffset = cents
        if abs(cents) <= inTuneCentsMargin {
            status = .inTune
        } else if cents < 0 {
            status = .tooLow
        } else {
            status = .tooHigh
        }
    }

    /// Busca, entre las cuerdas de la afinación actual (no entre las 12 notas cromáticas), la más
    /// cercana en cents a `frequency`, y la convierte en la cuerda seleccionada si está claramente
    /// más cerca que la actual (ver `autoSwitchHysteresisCents`).
    private func selectNearestString(toFrequency frequency: Float) {
        guard !tuning.strings.isEmpty else { return }

        let distances = tuning.strings.map { abs(1200 * log2(Double(frequency) / $0.frequency)) }
        guard let (nearestIndex, nearestDistance) = distances.enumerated().min(by: { $0.element < $1.element }) else {
            return
        }
        guard nearestIndex != selectedStringIndex else { return }

        let currentDistance = distances[selectedStringIndex]
        if currentDistance - nearestDistance >= autoSwitchHysteresisCents {
            selectedStringIndex = nearestIndex
        }
    }

    // MARK: - Nota de referencia

    private(set) var isPlayingReferenceNote = false

    /// Reproduce la nota de referencia de la cuerda seleccionada, pausando temporalmente
    /// la escucha del micrófono para no confundir el tono reproducido con la señal capturada.
    func playReferenceNote() {
        guard let targetNote else { return }
        wasListeningBeforeReferenceNote = audioEngine.isRunning
        audioEngine.stop()
        toneGenerator.play(frequency: Float(targetNote.frequency))
        isPlayingReferenceNote = true
    }

    /// Detiene la nota de referencia y reanuda la escucha si estaba activa antes de reproducirla.
    func stopReferenceNote() {
        toneGenerator.stop()
        isPlayingReferenceNote = false
        if wasListeningBeforeReferenceNote {
            wasListeningBeforeReferenceNote = false
            startListening()
        }
    }
}
