//
//  Tuning.swift
//  MiSiSol
//
//  Modelo de afinación: un conjunto de cuerdas, cada una con su nota base.
//

import Foundation

/// Afinación de un instrumento: lista ordenada de notas (una por cuerda), de la más grave a la más aguda.
/// Una afinación custom es simplemente una lista de notas, no depende de ninguna afinación estándar.
struct Tuning: Equatable, Codable {
    var name: String
    var instrument: Instrument
    var strings: [Note]
    /// Semitonos de transposición respecto a la afinación estándar del instrumento.
    /// Solo tiene significado informativo para afinaciones derivadas de la estándar (0 en afinaciones custom).
    var transposeSemitones: Int

    init(name: String, instrument: Instrument, strings: [Note], transposeSemitones: Int = 0) {
        self.name = name
        self.instrument = instrument
        self.strings = strings
        self.transposeSemitones = transposeSemitones
    }

    /// Afinación estándar del instrumento (sin transposición).
    static func standard(for instrument: Instrument) -> Tuning {
        let notes = instrument.standardTuningNoteNames.compactMap { Note.make(name: $0.name, octave: $0.octave) }
        return Tuning(name: "Estándar", instrument: instrument, strings: notes)
    }

    /// Desplaza la afinación estándar del instrumento `offset` semitonos (positivo = arriba, negativo = abajo).
    /// Recalcula las frecuencias de cada cuerda a partir de la afinación estándar + offset.
    static func transposedStandard(for instrument: Instrument, bySemitones offset: Int) -> Tuning {
        let base = standard(for: instrument)
        let shifted = base.strings.map { Note.note(forSemitonesFromA4: $0.semitonesFromA4 + offset) }
        return Tuning(name: transposeLabel(for: offset), instrument: instrument, strings: shifted, transposeSemitones: offset)
    }

    /// Etiqueta legible para un desplazamiento de semitonos (ej. "Media asta abajo", "Un tono abajo").
    static func transposeLabel(for offset: Int) -> String {
        guard offset != 0 else { return "Estándar" }
        let direction = offset > 0 ? "arriba" : "abajo"
        switch abs(offset) {
        case 1: return "Media asta \(direction)"
        case 2: return "Un tono \(direction)"
        default: return "\(abs(offset)) semitonos \(direction)"
        }
    }

    /// Afinación custom: el usuario asigna manualmente la nota de cada cuerda.
    static func custom(instrument: Instrument, name: String = "Personalizada", notes: [Note]) -> Tuning {
        Tuning(name: name, instrument: instrument, strings: notes)
    }

    /// Afinaciones alternativas predefinidas comunes para un instrumento (además de estándar y custom libre).
    static func alternates(for instrument: Instrument) -> [Tuning] {
        switch instrument {
        case .guitar:
            return [dropD]
        case .bass, .ukulele:
            return []
        }
    }

    /// Drop D: la sexta cuerda (más grave) baja un tono completo respecto al estándar.
    static var dropD: Tuning {
        let notes: [Note] = [("D", 2), ("A", 2), ("D", 3), ("G", 3), ("B", 3), ("E", 4)]
            .compactMap { Note.make(name: $0.0, octave: $0.1) }
        return Tuning(name: "Drop D", instrument: .guitar, strings: notes)
    }
}
