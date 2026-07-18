//
//  Instrument.swift
//  MiSiSol
//

import Foundation

/// Instrumentos soportados por el afinador.
enum Instrument: String, CaseIterable, Identifiable {
    case guitar
    case bass
    case ukulele

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .guitar: return "Guitarra"
        case .bass: return "Bajo"
        case .ukulele: return "Ukelele"
        }
    }

    /// Notas (nombre, octava) de la afinación estándar, ordenadas de la cuerda más grave a la más aguda.
    /// El ukelele usa afinación reentrante: la cuerda más aguda en orden físico (G4) suena más grave
    /// que la siguiente (C4), pero aquí se listan en el orden físico habitual de las cuerdas.
    var standardTuningNoteNames: [(name: String, octave: Int)] {
        switch self {
        case .guitar: return [("E", 2), ("A", 2), ("D", 3), ("G", 3), ("B", 3), ("E", 4)]
        case .bass: return [("E", 1), ("A", 1), ("D", 2), ("G", 2)]
        case .ukulele: return [("G", 4), ("C", 4), ("E", 4), ("A", 4)]
        }
    }

    /// Número de cuerdas del instrumento.
    var numberOfStrings: Int { standardTuningNoteNames.count }
}
