//
//  InstrumentPicker.swift
//  MiSiSol
//

import SwiftUI

/// Selector de instrumento (guitarra / bajo / ukelele).
struct InstrumentPicker: View {
    let selected: Instrument
    let onSelect: (Instrument) -> Void

    var body: some View {
        Picker("Instrumento", selection: Binding(get: { selected }, set: onSelect)) {
            ForEach(Instrument.allCases) { instrument in
                Text(instrument.displayName).tag(instrument)
            }
        }
        .pickerStyle(.segmented)
    }
}

#Preview {
    InstrumentPicker(selected: .guitar) { _ in }
        .padding()
}
