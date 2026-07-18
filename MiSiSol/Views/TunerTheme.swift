//
//  TunerTheme.swift
//  MiSiSol
//
//  Paleta de la pantalla principal del afinador: tema oscuro cálido fijo (no se adapta al
//  modo claro/oscuro del sistema), como el de muchas apps de audio/instrumentos.
//

import SwiftUI

enum TunerTheme {
    static let background = Color(red: 0x15 / 255, green: 0x11 / 255, blue: 0x0C / 255)
    static let surface = Color(red: 0x24 / 255, green: 0x1D / 255, blue: 0x15 / 255)
    static let textPrimary = Color(red: 0xF4 / 255, green: 0xEC / 255, blue: 0xDF / 255)
    static let textSecondary = Color(red: 0xA8 / 255, green: 0x9A / 255, blue: 0x84 / 255)

    static let accent = Color(red: 0xD9 / 255, green: 0x7A / 255, blue: 0x3D / 255)
    static let accentText = Color(red: 0x2B / 255, green: 0x16 / 255, blue: 0x08 / 255)

    static let success = Color(red: 0x7F / 255, green: 0xAE / 255, blue: 0x4A / 255)
    static let warning = Color(red: 0xE0 / 255, green: 0xA3 / 255, blue: 0x39 / 255)
    static let danger = Color(red: 0xD9 / 255, green: 0x63 / 255, blue: 0x4A / 255)
}

extension TuningStatus {
    var color: Color {
        switch self {
        case .inTune: return TunerTheme.success
        case .tooLow: return TunerTheme.warning
        case .tooHigh: return TunerTheme.danger
        case .noSignal: return TunerTheme.textSecondary
        }
    }

    var label: String {
        switch self {
        case .inTune: return "Afinado"
        case .tooLow: return "Sube"
        case .tooHigh: return "Baja"
        case .noSignal: return "Sin señal"
        }
    }
}

/// Estilo visual del indicador de afinación, elegible en el sheet de ajustes y persistido entre
/// sesiones con `@AppStorage`.
enum GaugeStyle: String, CaseIterable, Identifiable {
    /// Arco semicircular con aguja, como un potenciómetro.
    case dial
    /// Línea horizontal centrada en la nota objetivo, con una bolita que se mueve a los lados.
    case bar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dial: return "Dial"
        case .bar: return "Barra"
        }
    }
}

/// Cápsula de selección reutilizada por el selector de instrumento, cuerda y modo.
struct TunerChip: View {
    let label: String
    let isSelected: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? TunerTheme.accentText : TunerTheme.textSecondary)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(isSelected ? TunerTheme.accent : TunerTheme.surface)
            .clipShape(Capsule())
    }
}
