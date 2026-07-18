//
//  TunerView.swift
//  MiSiSol
//
//  Pantalla principal del afinador.
//

import AVFAudio
import SwiftUI

struct TunerView: View {
    @State private var viewModel = TunerViewModel()
    @State private var showingTuningPicker = false
    @State private var showingMicrophoneAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                InstrumentPicker(selected: viewModel.instrument) { newInstrument in
                    viewModel.selectInstrument(newInstrument)
                }

                modePicker

                stringSelector

                Spacer(minLength: 0)

                detectedNoteDisplay

                CentsGaugeView(
                    cents: viewModel.centsOffset,
                    status: viewModel.status,
                    margin: viewModel.inTuneCentsMargin
                )
                .frame(height: 28)
                .padding(.horizontal)

                Text(viewModel.status.label)
                    .font(.headline)
                    .foregroundStyle(viewModel.status.color)

                Spacer(minLength: 0)

                referenceNoteButton
            }
            .padding()
            .navigationTitle("MiSiSol")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingTuningPicker = true
                    } label: {
                        Label("Afinación", systemImage: "tuningfork")
                    }
                }
            }
            .sheet(isPresented: $showingTuningPicker) {
                TuningPicker(viewModel: viewModel)
            }
            .task {
                await requestMicrophoneAccessIfNeeded()
            }
            .onDisappear {
                viewModel.stopListening()
            }
            .alert("Micrófono desactivado", isPresented: $showingMicrophoneAlert) {
                Button("Vale", role: .cancel) {}
            } message: {
                Text("MiSiSol necesita acceso al micrófono para detectar el tono de tu instrumento. Actívalo en Ajustes.")
            }
        }
    }

    private var modePicker: some View {
        Picker("Modo", selection: Binding(get: { viewModel.mode }, set: { viewModel.setMode($0) })) {
            ForEach(TunerMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .pickerStyle(.segmented)
    }

    private var stringSelector: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ForEach(Array(viewModel.tuning.strings.enumerated()), id: \.offset) { index, note in
                    Button(note.fullName) {
                        viewModel.selectString(at: index)
                    }
                    .buttonStyle(.bordered)
                    .tint(index == viewModel.selectedStringIndex ? .accentColor : .secondary)
                }
            }
            .disabled(viewModel.mode == .automatic)
            .opacity(viewModel.mode == .automatic ? 0.5 : 1)

            if viewModel.mode == .automatic {
                Text("Detectando la cuerda automáticamente")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var detectedNoteDisplay: some View {
        VStack(spacing: 4) {
            Text(viewModel.detectedNote?.fullName ?? "–")
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            if let frequency = viewModel.detectedFrequency {
                Text(String(format: "%.1f Hz", frequency))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                Text("Toca la cuerda \(viewModel.targetNote?.fullName ?? "")")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var referenceNoteButton: some View {
        Button {
            if viewModel.isPlayingReferenceNote {
                viewModel.stopReferenceNote()
            } else {
                viewModel.playReferenceNote()
            }
        } label: {
            Label(
                viewModel.isPlayingReferenceNote ? "Detener" : "Reproducir \(viewModel.targetNote?.fullName ?? "")",
                systemImage: viewModel.isPlayingReferenceNote ? "speaker.slash.fill" : "speaker.wave.2.fill"
            )
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func requestMicrophoneAccessIfNeeded() async {
        switch AudioEngine.microphonePermission {
        case .granted:
            viewModel.startListening()
        case .undetermined:
            let granted = await AudioEngine.requestMicrophonePermission()
            if granted {
                viewModel.startListening()
            } else {
                showingMicrophoneAlert = true
            }
        case .denied:
            showingMicrophoneAlert = true
        @unknown default:
            showingMicrophoneAlert = true
        }
    }
}

// MARK: - Presentación del estado de afinación

private extension TuningStatus {
    var color: Color {
        switch self {
        case .inTune: return .green
        case .tooLow: return .orange
        case .tooHigh: return .red
        case .noSignal: return .secondary
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

// MARK: - Indicador de cents

/// Barra horizontal de cents: el centro representa la nota objetivo exacta, el área verde
/// el margen de "afinado" configurado, y el punto la desviación actual (recortada a ±50 cents).
private struct CentsGaugeView: View {
    let cents: Double
    let status: TuningStatus
    let margin: Double

    private let displayRange: Double = 50

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let clampedCents = min(max(cents, -displayRange), displayRange)
            let fraction = (clampedCents + displayRange) / (2 * displayRange)
            let marginWidth = width * (margin / displayRange)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.2))

                Capsule()
                    .fill(Color.green.opacity(0.3))
                    .frame(width: marginWidth)
                    .offset(x: width / 2 - marginWidth / 2)

                Rectangle()
                    .fill(Color.primary.opacity(0.5))
                    .frame(width: 2)
                    .offset(x: width / 2)

                Circle()
                    .fill(status.color)
                    .frame(width: 18, height: 18)
                    .offset(x: width * fraction - 9)
            }
        }
    }
}

#Preview {
    TunerView()
}
