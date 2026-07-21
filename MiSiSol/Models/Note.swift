//
//  Note.swift
//  MiSiSol
//
//  Representa una nota musical en temperamento igual, con A4 = 440Hz como referencia.
//

import Foundation

/// Nota musical (ej. E2, A2, D3...) con su frecuencia en temperamento igual.
struct Note: Equatable, Hashable, Codable {

    /// Frecuencia de referencia de A4 (La 4) en Hz.
    static let referenceFrequency: Double = 440.0

    /// Nombres de las 12 notas cromáticas, empezando en Do.
    static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    /// Índice de A4 dentro de `noteNames` y su octava, usados como origen de coordenadas.
    private static let a4NoteIndex = 9
    private static let a4Octave = 4

    /// Nombre de la nota sin octava (ej. "E", "A#").
    let name: String
    /// Octava de la nota (notación científica, A4 = La central de referencia).
    let octave: Int
    /// Distancia en semitonos respecto a A4 (puede ser negativa).
    let semitonesFromA4: Int

    /// Nombre completo de la nota en notación anglosajona (siempre la interna, ver `name`), ej. "E2".
    var fullName: String { "\(name)\(octave)" }

    /// Nombre completo de la nota en la convención de notación elegida, ej. "Mi2" en notación
    /// latina para la misma nota que `fullName` muestra como "E2". Solo cambia cómo se presenta:
    /// `name` (usado en igualdad, persistencia y cálculo de semitonos) siempre es anglosajón.
    func fullName(using style: NoteNamingStyle) -> String {
        guard let index = Note.noteNames.firstIndex(of: name) else { return fullName }
        return "\(style.noteNames[index])\(octave)"
    }

    /// Frecuencia de esta nota en Hz.
    var frequency: Double { Note.frequency(forSemitonesFromA4: semitonesFromA4) }

    /// Calcula la frecuencia de una nota a partir de su distancia en semitonos respecto a A4.
    /// Fórmula estándar de temperamento igual: f = 440 * 2^(n/12).
    static func frequency(forSemitonesFromA4 n: Int) -> Double {
        referenceFrequency * pow(2.0, Double(n) / 12.0)
    }

    /// Construye la nota que está a `n` semitonos de A4.
    static func note(forSemitonesFromA4 n: Int) -> Note {
        let totalIndex = a4NoteIndex + n
        let noteIndex = ((totalIndex % 12) + 12) % 12
        let octave = a4Octave + Int(floor(Double(totalIndex) / 12.0))
        return Note(name: noteNames[noteIndex], octave: octave, semitonesFromA4: n)
    }

    /// Construye una nota a partir de su nombre (ej. "E") y octava (ej. 2).
    /// Devuelve `nil` si el nombre no es una nota cromática válida.
    static func make(name: String, octave: Int) -> Note? {
        guard let noteIndex = noteNames.firstIndex(of: name) else { return nil }
        let semitones = (noteIndex - a4NoteIndex) + (octave - a4Octave) * 12
        return Note(name: name, octave: octave, semitonesFromA4: semitones)
    }

    /// Encuentra la nota más cercana a una frecuencia dada y la desviación en cents
    /// (positiva si la frecuencia está por encima de la nota, negativa si está por debajo).
    static func closest(to frequency: Double) -> (note: Note, cents: Double) {
        guard frequency > 0 else { return (note(forSemitonesFromA4: 0), 0) }
        let exactSemitones = 12 * log2(frequency / referenceFrequency)
        let nearestSemitone = Int(exactSemitones.rounded())
        let nearestNote = note(forSemitonesFromA4: nearestSemitone)
        let cents = (exactSemitones - Double(nearestSemitone)) * 100
        return (nearestNote, cents)
    }
}

/// Convención de nombres de nota para mostrar en la interfaz, elegible en ajustes y persistida
/// con `@AppStorage`. El nombre interno de `Note` (usado en igualdad, persistencia y cálculo de
/// semitonos) siempre es anglosajón; esto solo afecta a cómo se presenta en pantalla.
enum NoteNamingStyle: String, CaseIterable, Identifiable, Codable {
    case anglo
    case latin

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anglo: return "C-D-E"
        case .latin: return "Do-Re-Mi"
        }
    }

    /// Nombres de las 12 notas cromáticas en este estilo, en el mismo orden que `Note.noteNames`.
    fileprivate var noteNames: [String] {
        switch self {
        case .anglo: return Note.noteNames
        case .latin: return ["Do", "Do#", "Re", "Re#", "Mi", "Fa", "Fa#", "Sol", "Sol#", "La", "La#", "Si"]
        }
    }
}
