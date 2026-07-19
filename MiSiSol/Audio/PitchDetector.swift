//
//  PitchDetector.swift
//  MiSiSol
//
//  Detección de tono mediante autocorrelación (ACF). No depende de AVAudioEngine:
//  trabaja sobre un [Float] con su sampleRate, para poder testearse con señales
//  sintéticas sin necesidad de micrófono real.
//

import Foundation

struct PitchDetector {

    /// Frecuencia mínima que el detector intentará reconocer. 30Hz deja margen por debajo
    /// del Mi grave del bajo (~41.2Hz) incluso con afinaciones transportadas varios semitonos abajo.
    let minFrequency: Float
    /// Frecuencia máxima a considerar; por encima de esto solo interesan armónicos, no la fundamental.
    let maxFrequency: Float
    /// Umbral (0...1) de claridad de la correlación normalizada para aceptar un resultado.
    /// Por debajo de este umbral se considera que no hay señal tonal suficientemente clara.
    let clarityThreshold: Float

    init(minFrequency: Float = 30.0, maxFrequency: Float = 1200.0, clarityThreshold: Float = 0.5) {
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
        self.clarityThreshold = clarityThreshold
    }

    /// Margen mínimo por el que la correlación al doble de un lag candidato debe superarlo para
    /// preferir esa octava más grave (ver `correctOctave`). Calibrado analizando grabaciones reales
    /// de guitarra, bajo y ukelele: separa con buena fiabilidad los errores de octava genuinos
    /// (margen típicamente > 0.15) de las fundamentales ya correctas (margen típicamente < 0, la
    /// mayoría de las veces claramente negativo).
    private static let octaveCorrectionMargin: Float = 0.05

    /// Tamaño mínimo de buffer recomendado para detectar de forma fiable `minFrequency` Hz
    /// a un `sampleRate` dado.
    ///
    /// La autocorrelación en el lag correspondiente al periodo de la señal (lag ≈ sampleRate/frecuencia)
    /// necesita al menos un periodo completo de solape entre la señal y su copia desplazada para dar
    /// una estimación estable del pico; por debajo de eso el pico queda enmascarado por el efecto de
    /// borde (cada vez menos muestras se solapan al crecer el lag). Por eso se pide el doble del periodo:
    /// minBufferSize = 2 * (sampleRate / minFrequency).
    static func minimumBufferSize(sampleRate: Double, minFrequency: Double) -> Int {
        Int((2.0 * sampleRate / minFrequency).rounded(.up))
    }

    /// Resultado detallado de un intento de detección: la frecuencia (`nil` si la claridad no
    /// superó `clarityThreshold`) y la claridad real conseguida (0...1). Pensado para depurar por
    /// qué una señal real no llega a superar el umbral, sin tener que adivinarlo a ciegas.
    struct DetectionResult {
        let frequency: Float?
        let clarity: Float
    }

    /// Estima la frecuencia fundamental del buffer, o `nil` si no hay señal suficientemente clara
    /// (silencio, ruido, o buffer demasiado corto para el rango de frecuencias configurado).
    func detectPitch(in buffer: [Float], sampleRate: Double) -> Float? {
        detectPitchWithDiagnostics(in: buffer, sampleRate: sampleRate).frequency
    }

    /// Igual que `detectPitch`, pero además informa de la claridad real conseguida aunque no
    /// llegue a superar `clarityThreshold` (en ese caso `frequency` es `nil` pero `clarity` sigue
    /// siendo el mejor valor encontrado).
    func detectPitchWithDiagnostics(in buffer: [Float], sampleRate: Double) -> DetectionResult {
        guard maxFrequency > 0, minFrequency > 0 else { return DetectionResult(frequency: nil, clarity: 0) }
        let minLag = max(1, Int((sampleRate / Double(maxFrequency)).rounded(.down)))
        let maxLag = Int((sampleRate / Double(minFrequency)).rounded(.up))
        guard buffer.count > maxLag, minLag < maxLag else { return DetectionResult(frequency: nil, clarity: 0) }

        let windowed = hannWindowed(buffer)
        guard windowed.contains(where: { $0 != 0 }) else { return DetectionResult(frequency: nil, clarity: 0) } // silencio

        // Las correlaciones se calculan bajo demanda y se cachean, en vez de calcular todo el
        // rango [minLag, maxLag] de antemano: la mayoría de sonidos reales tienen su periodo
        // fundamental mucho antes de maxLag, así que precalcular todo el rango desperdicia
        // trabajo justo en el caso más común (y en una build sin optimizar puede tardar más de
        // lo que dura un buffer de audio, acumulando retraso).
        var cache = [Float?](repeating: nil, count: maxLag - minLag + 1)
        func correlation(atLag lag: Int) -> Float {
            let index = lag - minLag
            if let cached = cache[index] { return cached }
            let value = normalizedCrossCorrelation(windowed, lag: lag)
            cache[index] = value
            return value
        }

        guard let peak = dominantPeak(minLag: minLag, maxLag: maxLag, correlation: correlation) else {
            return DetectionResult(frequency: nil, clarity: 0)
        }
        guard peak.value >= clarityThreshold else {
            return DetectionResult(frequency: nil, clarity: peak.value)
        }

        let corrected = correctOctave(lag: peak.lag, value: peak.value, maxLag: maxLag, correlation: correlation)

        let refinedLag = parabolicRefinement(around: corrected.lag, minLag: minLag, maxLag: maxLag, correlation: correlation)
        guard refinedLag > 0 else { return DetectionResult(frequency: nil, clarity: corrected.value) }

        return DetectionResult(frequency: Float(sampleRate) / refinedLag, clarity: corrected.value)
    }

    // MARK: - Búsqueda de pico

    /// Localiza el mejor máximo local de la correlación (por lag) que representa la periodicidad
    /// fundamental, junto con su valor.
    ///
    /// Cerca de lag pequeño la correlación es alta simplemente por la continuidad de la señal
    /// (dos muestras muy próximas de cualquier onda suave se parecen, sea o no periódica en ese lag),
    /// así que no basta con mirar el primer valor alto: primero hay que dejar atrás esa caída
    /// inicial hasta su primer mínimo, y solo entonces buscar el siguiente máximo local. Para una
    /// señal periódica, ese máximo cae en el periodo fundamental; los múltiplos del periodo (2x,
    /// 3x...) producen máximos igual de altos más adelante, pero al preferir el primero que cruza
    /// `clarityThreshold` evitamos los errores de octava.
    ///
    /// Ahora bien, con una señal real (varios armónicos con fases relativas arbitrarias, no una
    /// sinusoide pura) ese primer máximo local puede no ser el del periodo fundamental: la
    /// interferencia entre armónicos puede producir mínimos y máximos intermedios *antes* de llegar
    /// al lag del periodo real, y esos máximos intermedios suelen tener una correlación baja (por
    /// debajo del umbral). Si nos rendimos ahí, la nota parece "no sonar" aunque el periodo
    /// fundamental, un poco más adelante, tenga una correlación alta y clara. Por eso, si un máximo
    /// local no cruza el umbral, no se descarta la señal entera: se continúa buscando el siguiente
    /// mínimo y máximo, recordando el mejor visto hasta ahora. Si ninguno llega a cruzar el umbral
    /// en todo el rango, se devuelve igualmente ese mejor candidato (con su valor real, aunque bajo)
    /// para que quien llama pueda diagnosticar la claridad conseguida en vez de recibir un `nil` sin
    /// más información.
    private func dominantPeak(minLag: Int, maxLag: Int, correlation: (Int) -> Float) -> (lag: Int, value: Float)? {
        guard maxLag > minLag + 1 else { return nil }

        var lag = minLag
        var best: (lag: Int, value: Float)?
        while lag < maxLag {
            while lag < maxLag && correlation(lag + 1) < correlation(lag) {
                lag += 1
            }
            guard lag < maxLag else { break } // nunca remonta: no hay más periodicidad que explorar

            var peakLag = lag
            while peakLag < maxLag && correlation(peakLag + 1) >= correlation(peakLag) {
                peakLag += 1
            }

            let value = correlation(peakLag)
            if value >= clarityThreshold {
                return (peakLag, value)
            }
            if best == nil || value > best!.value {
                best = (peakLag, value)
            }
            lag = peakLag // este máximo no basta: seguir buscando más allá
        }
        return best
    }

    /// Si la correlación al doble de `lag` es notablemente mayor que la del propio `lag`, el
    /// periodo real es más probablemente el doble (la mitad de la frecuencia) y `lag` no es más
    /// que su segundo armónico. Repite la comprobación (el doble del doble...) mientras seguir
    /// bajando de octava siga mejorando claramente la correlación.
    ///
    /// No basta con "igual o mayor": cualquier señal genuinamente periódica de periodo T también
    /// correlaciona fuerte en 2T (dos periodos completos encajan igual de bien que uno), así que
    /// una fundamental ya bien detectada casi siempre tiene una correlación en 2T parecida o algo
    /// menor, nunca claramente mayor. Analizando grabaciones reales de guitarra/bajo/ukelele
    /// (incluido el caso que motivó esto: la cuerda Sol de una guitarra detectada una octava por
    /// encima de la real, con correlación en 2T sistemáticamente más alta que en T) se confirma
    /// que un margen claro y positivo sí distingue de forma fiable un error de octava genuino de
    /// una fundamental correcta; ver `octaveCorrectionMargin`.
    private func correctOctave(lag: Int, value: Float, maxLag: Int, correlation: (Int) -> Float) -> (lag: Int, value: Float) {
        var lag = lag
        var value = value
        while true {
            let doubledLag = lag * 2
            guard doubledLag <= maxLag else { break }
            let doubledValue = correlation(doubledLag)
            guard doubledValue > value + Self.octaveCorrectionMargin else { break }
            lag = doubledLag
            value = doubledValue
        }
        return (lag, value)
    }

    // MARK: - Ventana de Hann

    /// Aplica una ventana de Hann para atenuar los bordes del buffer y reducir artefactos
    /// (fugas espectrales) antes de calcular la autocorrelación.
    private func hannWindowed(_ buffer: [Float]) -> [Float] {
        let n = buffer.count
        guard n > 1 else { return buffer }
        var result = [Float](repeating: 0, count: n)
        let denominator = Float(n - 1)
        for i in 0..<n {
            let w = 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / denominator)
            result[i] = buffer[i] * w
        }
        return result
    }

    // MARK: - Correlación cruzada normalizada

    /// Correlación cruzada de `buffer` con su copia desplazada `lag` muestras, normalizada por
    /// la energía de cada uno de los dos segmentos solapados (no por su recuento de muestras).
    ///
    /// Se normaliza así, en vez de dividir por el recuento de muestras solapadas, porque la ventana
    /// de Hann hace que la energía de la señal no sea uniforme a lo largo del buffer: dividir solo
    /// por el número de muestras sesgaría el resultado a favor de lags grandes (la parte del buffer
    /// que queda fuera de la zona atenuada por la ventana). El resultado queda acotado en [-1, 1],
    /// donde 1 significa periodicidad perfecta en ese lag.
    private func normalizedCrossCorrelation(_ buffer: [Float], lag: Int) -> Float {
        let count = buffer.count - lag
        guard count > 0 else { return 0 }
        var sum: Float = 0
        var energyA: Float = 0
        var energyB: Float = 0
        for i in 0..<count {
            let a = buffer[i]
            let b = buffer[i + lag]
            sum += a * b
            energyA += a * a
            energyB += b * b
        }
        let denominator = sqrt(energyA * energyB)
        guard denominator > 0 else { return 0 }
        return sum / denominator
    }

    /// Refina la posición del pico con interpolación parabólica sobre los tres puntos vecinos,
    /// para obtener una estimación de frecuencia sub-muestra más precisa que el lag entero.
    private func parabolicRefinement(around lag: Int, minLag: Int, maxLag: Int, correlation: (Int) -> Float) -> Float {
        guard lag - 1 >= minLag, lag + 1 <= maxLag else { return Float(lag) }
        let yBefore = correlation(lag - 1)
        let yAt = correlation(lag)
        let yAfter = correlation(lag + 1)
        let denominator = yBefore - 2 * yAt + yAfter
        guard denominator != 0 else { return Float(lag) }
        let delta = 0.5 * (yBefore - yAfter) / denominator
        return Float(lag) + delta
    }
}
