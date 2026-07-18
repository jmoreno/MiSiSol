//
//  TuningPicker.swift
//  MiSiSol
//
//  Selector de afinación: estándar/alternativas predefinidas, transposición rápida
//  y afinación personalizada cuerda a cuerda.
//

import SwiftUI

struct TuningPicker: View {
    let viewModel: TunerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var customNoteNames: [String]
    @State private var customOctaves: [Int]

    init(viewModel: TunerViewModel) {
        self.viewModel = viewModel
        _customNoteNames = State(initialValue: viewModel.tuning.strings.map(\.name))
        _customOctaves = State(initialValue: viewModel.tuning.strings.map(\.octave))
    }

    var body: some View {
        NavigationStack {
            List {
                presetSection
                transposeSection
                customSection
            }
            .navigationTitle("Afinación")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
            }
        }
    }

    // MARK: - Estándar y alternativas

    private var presetSection: some View {
        Section("Predefinidas") {
            presetRow(Tuning.standard(for: viewModel.instrument))
            ForEach(Tuning.alternates(for: viewModel.instrument), id: \.name) { alternate in
                presetRow(alternate)
            }
        }
    }

    private func presetRow(_ preset: Tuning) -> some View {
        Button {
            viewModel.selectTuning(preset)
            resetCustomEditorState()
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(preset.name)
                    Text(preset.strings.map(\.fullName).joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if viewModel.tuning.name == preset.name && viewModel.tuning.strings == preset.strings {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .tint(.primary)
    }

    // MARK: - Transposición rápida

    private var transposeSection: some View {
        Section("Transportar afinación estándar") {
            HStack {
                Button("−1 tono") { viewModel.transpose(bySemitones: -2) }
                Spacer()
                Button("−½ tono") { viewModel.transpose(bySemitones: -1) }
                Spacer()
                Button("Estándar") { viewModel.transpose(bySemitones: 0) }
                Spacer()
                Button("+½ tono") { viewModel.transpose(bySemitones: 1) }
                Spacer()
                Button("+1 tono") { viewModel.transpose(bySemitones: 2) }
            }
            .buttonStyle(.borderless)
            .font(.footnote)

            Stepper(
                "Semitonos: \(viewModel.tuning.transposeSemitones)",
                value: Binding(
                    get: { viewModel.tuning.transposeSemitones },
                    set: { viewModel.transpose(bySemitones: $0) }
                ),
                in: -12...12
            )
        }
    }

    // MARK: - Personalizada

    private var customSection: some View {
        Section("Personalizada") {
            ForEach(customNoteNames.indices, id: \.self) { index in
                HStack {
                    Text("Cuerda \(index + 1)")
                    Spacer()
                    Picker("Nota", selection: $customNoteNames[index]) {
                        ForEach(Note.noteNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .labelsHidden()

                    Stepper(value: $customOctaves[index], in: 0...7) {
                        Text("\(customOctaves[index])")
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
            }

            Button("Aplicar afinación personalizada") {
                applyCustomTuning()
            }
        }
    }

    private func applyCustomTuning() {
        let notes = zip(customNoteNames, customOctaves).compactMap { Note.make(name: $0, octave: $1) }
        guard notes.count == customNoteNames.count else { return }
        viewModel.selectTuning(.custom(instrument: viewModel.instrument, notes: notes))
    }

    private func resetCustomEditorState() {
        customNoteNames = viewModel.tuning.strings.map(\.name)
        customOctaves = viewModel.tuning.strings.map(\.octave)
    }
}

#Preview {
    TuningPicker(viewModel: TunerViewModel())
}
