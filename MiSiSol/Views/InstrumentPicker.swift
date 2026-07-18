//
//  InstrumentPicker.swift
//  MiSiSol
//

import SwiftUI

/// Selector de instrumento (guitarra / bajo / ukelele) como fila de chips de color.
struct InstrumentPicker: View {
    let selected: Instrument
    let onSelect: (Instrument) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Instrument.allCases) { instrument in
                Button {
                    onSelect(instrument)
                } label: {
                    TunerChip(label: instrument.displayName, isSelected: instrument == selected)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#Preview {
    InstrumentPicker(selected: .guitar) { _ in }
        .padding()
        .background(TunerTheme.background)
}
