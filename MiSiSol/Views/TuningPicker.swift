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
    @AppStorage("gaugeStyle") private var gaugeStyle: GaugeStyle = .dial
    @AppStorage("noteNamingStyle") private var noteNamingStyle: NoteNamingStyle = .anglo

    @State private var customNotes: [Note]

    /// Todas las notas seleccionables en el desplegable de afinación personalizada, ordenadas
    /// de más grave a más aguda (octavas 0 a 7).
    private static let selectableNotes: [Note] = (0...7).flatMap { octave in
        Note.noteNames.compactMap { name in Note.make(name: name, octave: octave) }
    }
    private static let minSelectableSemitones = selectableNotes.first!.semitonesFromA4
    private static let maxSelectableSemitones = selectableNotes.last!.semitonesFromA4

    init(viewModel: TunerViewModel) {
        self.viewModel = viewModel
        _customNotes = State(initialValue: viewModel.tuning.strings)
    }

    /// La voz no tiene afinaciones estándar ni transposición: solo una nota objetivo elegible.
    private var isVoice: Bool { viewModel.instrument == .voice }

    var body: some View {
        NavigationStack {
            List {
                if !isVoice {
                    presetSection
                    transposeSection
                }
                customSection
                appearanceSection
                noteNamingSection
            }
            .scrollContentBackground(.hidden)
            .background(TunerTheme.background)
            .navigationTitle("Afinación")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                        .tint(TunerTheme.accent)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Estándar y alternativas

    private var presetSection: some View {
        Section {
            presetRow(Tuning.standard(for: viewModel.instrument))
            ForEach(Tuning.alternates(for: viewModel.instrument), id: \.name) { alternate in
                presetRow(alternate)
            }
        } header: {
            Text("Predefinidas").foregroundStyle(TunerTheme.textSecondary)
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
                        .foregroundStyle(TunerTheme.textPrimary)
                    Text(preset.strings.map { $0.fullName(using: noteNamingStyle) }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(TunerTheme.textSecondary)
                }
                Spacer()
                if viewModel.tuning.name == preset.name && viewModel.tuning.strings == preset.strings {
                    Image(systemName: "checkmark")
                        .foregroundStyle(TunerTheme.accent)
                }
            }
        }
        .listRowBackground(TunerTheme.surface)
    }

    // MARK: - Transposición rápida

    private var transposeSection: some View {
        Section {
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
            .tint(TunerTheme.accent)
            .font(.footnote)
            .listRowBackground(TunerTheme.surface)

            Stepper(
                "Semitonos: \(viewModel.tuning.transposeSemitones)",
                value: Binding(
                    get: { viewModel.tuning.transposeSemitones },
                    set: { viewModel.transpose(bySemitones: $0) }
                ),
                in: -12...12
            )
            .foregroundStyle(TunerTheme.textPrimary)
            .tint(TunerTheme.accent)
            .listRowBackground(TunerTheme.surface)
        } header: {
            Text("Transportar afinación estándar").foregroundStyle(TunerTheme.textSecondary)
        }
    }

    // MARK: - Personalizada

    private var customSection: some View {
        Section {
            ForEach(customNotes.indices, id: \.self) { index in
                HStack {
                    Text(isVoice ? "Nota objetivo" : "Cuerda \(index + 1)")
                        .foregroundStyle(TunerTheme.textPrimary)
                    Spacer()
                    Picker("Nota", selection: $customNotes[index]) {
                        ForEach(Self.selectableNotes, id: \.self) { note in
                            Text(note.fullName(using: noteNamingStyle)).tag(note)
                        }
                    }
                    .labelsHidden()
                    .tint(TunerTheme.accent)

                    // El stepper y el desplegable de arriba controlan la misma nota: subir/bajar
                    // el stepper mueve semitono a semitono, y el desplegable siempre refleja la
                    // nota resultante.
                    Stepper(
                        "Semitono",
                        value: Binding(
                            get: { customNotes[index].semitonesFromA4 },
                            set: { customNotes[index] = Note.note(forSemitonesFromA4: $0) }
                        ),
                        in: Self.minSelectableSemitones...Self.maxSelectableSemitones
                    )
                    .labelsHidden()
                    .tint(TunerTheme.accent)
                }
                .listRowBackground(TunerTheme.surface)
            }

            Button("Aplicar afinación personalizada") {
                applyCustomTuning()
            }
            .tint(TunerTheme.accent)
            .listRowBackground(TunerTheme.surface)
        } header: {
            Text("Personalizada").foregroundStyle(TunerTheme.textSecondary)
        }
    }

    // MARK: - Apariencia

    private var appearanceSection: some View {
        Section {
            HStack(spacing: 6) {
                ForEach(GaugeStyle.allCases) { style in
                    Button {
                        gaugeStyle = style
                    } label: {
                        TunerChip(label: style.displayName, isSelected: gaugeStyle == style)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowBackground(TunerTheme.surface)
        } header: {
            Text("Apariencia del indicador").foregroundStyle(TunerTheme.textSecondary)
        }
    }

    private var noteNamingSection: some View {
        Section {
            HStack(spacing: 6) {
                ForEach(NoteNamingStyle.allCases) { style in
                    Button {
                        noteNamingStyle = style
                    } label: {
                        TunerChip(label: style.displayName, isSelected: noteNamingStyle == style)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowBackground(TunerTheme.surface)
        } header: {
            Text("Nombres de las notas").foregroundStyle(TunerTheme.textSecondary)
        }
    }

    private func applyCustomTuning() {
        viewModel.selectTuning(.custom(instrument: viewModel.instrument, notes: customNotes))
    }

    private func resetCustomEditorState() {
        customNotes = viewModel.tuning.strings
    }
}

#Preview {
    TuningPicker(viewModel: TunerViewModel())
}
