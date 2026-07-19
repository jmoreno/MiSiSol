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
    @AppStorage("gaugeStyle") private var gaugeStyle: GaugeStyle = .dial

    var body: some View {
        ZStack {
            TunerTheme.background.ignoresSafeArea()

            VStack(spacing: 20) {
                header

                if let message = viewModel.audioErrorMessage {
                    audioErrorBanner(message: message)
                }

                InstrumentPicker(selected: viewModel.instrument) { newInstrument in
                    viewModel.selectInstrument(newInstrument)
                }

                Spacer(minLength: 0)

                Group {
                    switch gaugeStyle {
                    case .dial:
                        DialGaugeView(
                            cents: viewModel.centsOffset,
                            status: viewModel.status,
                            margin: viewModel.inTuneCentsMargin
                        )
                        .frame(height: 150)
                    case .bar:
                        BarGaugeView(
                            cents: viewModel.centsOffset,
                            status: viewModel.status,
                            margin: viewModel.inTuneCentsMargin
                        )
                        .frame(height: 28)
                    }
                }
                .padding(.horizontal, 12)

                detectedNoteDisplay

                #if DEBUG
                debugDiagnostics
                #endif

                Spacer(minLength: 0)

                stringSelector

                modePicker

                referenceNoteButton
            }
            .padding(20)
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
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("MiSiSol")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(TunerTheme.textPrimary)
            Spacer()
            Button {
                showingTuningPicker = true
            } label: {
                Image(systemName: "tuningfork")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(TunerTheme.textSecondary)
                    .frame(width: 32, height: 32)
                    .background(TunerTheme.surface)
                    .clipShape(Circle())
            }
        }
    }

    /// Aviso discreto cuando la captura de audio no ha podido arrancar (o un reintento automático
    /// tras una interrupción/cambio de ruta ha fallado), con opción de reintentar. El usuario
    /// nunca debería ver un afinador que simplemente no detecta nada sin ninguna explicación.
    private func audioErrorBanner(message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(TunerTheme.warning)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(TunerTheme.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Reintentar") {
                viewModel.startListening()
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(TunerTheme.accent)
        }
        .padding(10)
        .background(TunerTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    #if DEBUG
    /// Claridad de la última lectura y un botón para grabar el audio crudo del micrófono a un
    /// .wav compartible (AirDrop/Mensajes/Archivos), para depurar un caso real sin tener que
    /// describirlo de palabra.
    private var debugDiagnostics: some View {
        VStack(spacing: 6) {
            Text(String(format: "claridad: %.2f", viewModel.lastClarity))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(TunerTheme.textSecondary)

            HStack(spacing: 8) {
                Button {
                    if viewModel.isDebugRecording {
                        viewModel.stopDebugRecording()
                    } else {
                        viewModel.startDebugRecording()
                    }
                } label: {
                    Text(viewModel.isDebugRecording ? "Detener grabación debug" : "Grabar audio debug")
                        .font(.system(size: 11, design: .monospaced))
                }
                .buttonStyle(.plain)
                .foregroundStyle(TunerTheme.accent)

                if !viewModel.isDebugRecording, let url = viewModel.debugRecordingURL {
                    ShareLink(item: url) {
                        Text("Compartir .wav")
                            .font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundStyle(TunerTheme.accent)
                }
            }
        }
    }
    #endif

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(TunerMode.allCases) { mode in
                Button {
                    viewModel.setMode(mode)
                } label: {
                    Text(mode.displayName)
                        .font(.system(size: 13, weight: viewModel.mode == mode ? .semibold : .regular))
                        .foregroundStyle(viewModel.mode == mode ? TunerTheme.textPrimary : TunerTheme.textSecondary)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background(viewModel.mode == mode ? TunerTheme.background : Color.clear)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(TunerTheme.surface)
        .clipShape(Capsule())
    }

    private var stringSelector: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                ForEach(Array(viewModel.tuning.strings.enumerated()), id: \.offset) { index, note in
                    Button {
                        viewModel.selectString(at: index)
                    } label: {
                        TunerChip(label: note.fullName, isSelected: index == viewModel.selectedStringIndex)
                    }
                    .buttonStyle(.plain)
                }
            }
            .disabled(viewModel.mode == .automatic)
            .opacity(viewModel.mode == .automatic ? 0.5 : 1)

            if viewModel.mode == .automatic {
                Text("Detectando la cuerda automáticamente")
                    .font(.system(size: 11))
                    .foregroundStyle(TunerTheme.textSecondary)
            }
        }
    }

    private var detectedNoteDisplay: some View {
        VStack(spacing: 6) {
            Text(viewModel.detectedNote?.fullName ?? "–")
                .font(.system(size: 56, weight: .semibold, design: .rounded))
                .foregroundStyle(TunerTheme.textPrimary)
                .contentTransition(.numericText())
            if let frequency = viewModel.detectedFrequency {
                Text(frequencyAndCentsText(frequency: frequency))
                    .font(.system(size: 13))
                    .foregroundStyle(viewModel.status.color)
            } else {
                Text("Toca la cuerda \(viewModel.targetNote?.fullName ?? "")")
                    .font(.system(size: 13))
                    .foregroundStyle(TunerTheme.textSecondary)
            }
        }
    }

    private func frequencyAndCentsText(frequency: Float) -> String {
        let cents = Int(viewModel.centsOffset.rounded())
        let centsText = cents >= 0 ? "+\(cents)" : "\(cents)"
        return String(format: "%.1f Hz · %@ cents", frequency, centsText)
    }

    private var referenceNoteButton: some View {
        Button {
            if viewModel.isPlayingReferenceNote {
                viewModel.stopReferenceNote()
            } else {
                viewModel.playReferenceNote()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: viewModel.isPlayingReferenceNote ? "speaker.slash.fill" : "play.fill")
                Text(viewModel.isPlayingReferenceNote ? "Detener" : "Reproducir \(viewModel.targetNote?.fullName ?? "")")
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(TunerTheme.accentText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(TunerTheme.accent)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
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

// MARK: - Indicador de cents: dial circular

/// Dial en forma de arco semicircular: el centro (arriba) representa la nota objetivo exacta,
/// la zona verde el margen de "afinado" configurado, y la aguja la desviación actual
/// (recortada a ±50 cents).
private struct DialGaugeView: View {
    let cents: Double
    let status: TuningStatus
    let margin: Double

    private let displayRange: Double = 50

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height
            let center = CGPoint(x: width / 2, y: height * 0.92)
            let radius = min(width / 2 - 12, height * 0.85)

            ZStack {
                arcPath(center: center, radius: radius, fromDegrees: 180, toDegrees: 0)
                    .stroke(TunerTheme.surface, style: StrokeStyle(lineWidth: 12, lineCap: .round))

                arcPath(
                    center: center,
                    radius: radius,
                    fromDegrees: 90 + (margin / displayRange) * 90,
                    toDegrees: 90 - (margin / displayRange) * 90
                )
                .stroke(TunerTheme.success, style: StrokeStyle(lineWidth: 12, lineCap: .round))

                needlePath(center: center, radius: radius - 18)
                    .stroke(status.color, style: StrokeStyle(lineWidth: 4, lineCap: .round))

                Circle()
                    .fill(status.color)
                    .frame(width: 14, height: 14)
                    .position(center)
            }
        }
    }

    private func needleAngleDegrees() -> Double {
        let clamped = min(max(cents, -displayRange), displayRange)
        let fraction = (clamped + displayRange) / (2 * displayRange)
        return 180 - fraction * 180
    }

    private func point(center: CGPoint, radius: CGFloat, degrees: Double) -> CGPoint {
        let rad = degrees * .pi / 180
        return CGPoint(
            x: center.x + radius * CGFloat(cos(rad)),
            y: center.y - radius * CGFloat(sin(rad))
        )
    }

    private func arcPath(center: CGPoint, radius: CGFloat, fromDegrees: Double, toDegrees: Double, steps: Int = 48) -> Path {
        var path = Path()
        for i in 0...steps {
            let t = Double(i) / Double(steps)
            let deg = fromDegrees + (toDegrees - fromDegrees) * t
            let p = point(center: center, radius: radius, degrees: deg)
            if i == 0 {
                path.move(to: p)
            } else {
                path.addLine(to: p)
            }
        }
        return path
    }

    private func needlePath(center: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        path.move(to: center)
        path.addLine(to: point(center: center, radius: radius, degrees: needleAngleDegrees()))
        return path
    }
}

// MARK: - Indicador de cents: barra horizontal

/// Línea horizontal centrada en la nota objetivo: la marca central representa la nota exacta,
/// la zona verde el margen de "afinado" configurado, y la bolita la desviación actual
/// (recortada a ±50 cents), moviéndose a la izquierda o la derecha del centro.
private struct BarGaugeView: View {
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
                    .fill(TunerTheme.surface)

                Capsule()
                    .fill(TunerTheme.success.opacity(0.35))
                    .frame(width: marginWidth)
                    .offset(x: width / 2 - marginWidth / 2)

                Rectangle()
                    .fill(TunerTheme.textPrimary.opacity(0.6))
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
