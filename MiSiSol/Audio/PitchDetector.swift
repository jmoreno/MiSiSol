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

    /// Estima la frecuencia fundamental del buffer, o `nil` si no hay señal suficientemente clara
    /// (silencio, ruido, o buffer demasiado corto para el rango de frecuencias configurado).
    func detectPitch(in buffer: [Float], sampleRate: Double) -> Float? {
        guard maxFrequency > 0, minFrequency > 0 else { return nil }
        let minLag = max(1, Int((sampleRate / Double(maxFrequency)).rounded(.down)))
        let maxLag = Int((sampleRate / Double(minFrequency)).rounded(.up))
        guard buffer.count > maxLag, minLag < maxLag else { return nil }

        let windowed = hannWindowed(buffer)
        guard windowed.contains(where: { $0 != 0 }) else { return nil } // silencio: nada que correlar

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

        guard let peakLag = dominantPeakLag(minLag: minLag, maxLag: maxLag, correlation: correlation) else {
            return nil
        }

        let refinedLag = parabolicRefinement(around: peakLag, minLag: minLag, maxLag: maxLag, correlation: correlation)
        guard refinedLag > 0 else { return nil }

        return Float(sampleRate) / refinedLag
    }

    // MARK: - Búsqueda de pico

    /// Localiza el primer máximo local de la correlación (por lag) que supera `clarityThreshold`
    /// y representa la periodicidad fundamental.
    ///
    /// Cerca de lag pequeño la correlación es alta simplemente por la continuidad de la señal
    /// (dos muestras muy próximas de cualquier onda suave se parecen, sea o no periódica en ese lag),
    /// así que no basta con cruzar `clarityThreshold` en el primer máximo que aparezca: primero hay
    /// que dejar atrás esa caída inicial hasta su primer mínimo, y solo entonces mirar el siguiente
    /// máximo local. Para una señal periódica, el máximo del periodo fundamental es normalmente el
    /// más alto de toda la serie; los múltiplos del periodo (2x, 3x...) producen máximos igual de
    /// altos más adelante, pero al preferir el primero que cruza el umbral evitamos los errores de
    /// octava.
    ///
    /// Ahora bien, con una señal real (varios armónicos con fases relativas arbitrarias, no una
    /// sinusoide pura) ese primer máximo local puede no ser el del periodo fundamental: la
    /// interferencia entre armónicos puede producir mínimos y máximos intermedios *antes* de llegar
    /// al lag del periodo real, y esos máximos intermedios suelen tener una correlación baja (por
    /// debajo del umbral). Si nos rendimos ahí, la nota parece "no sonar" aunque el periodo
    /// fundamental, un poco más adelante, tenga una correlación alta y clara. Por eso, si un máximo
    /// local no cruza el umbral, no se descarta la señal entera: se continúa buscando el siguiente
    /// mínimo y máximo, hasta encontrar uno que sí lo cruce o agotar el rango de lags.
    private func dominantPeakLag(minLag: Int, maxLag: Int, correlation: (Int) -> Float) -> Int? {
        guard maxLag > minLag + 1 else { return nil }

        var lag = minLag
        while lag < maxLag {
            while lag < maxLag && correlation(lag + 1) < correlation(lag) {
                lag += 1
            }
            guard lag < maxLag else { return nil } // nunca remonta: no hay periodicidad clara

            var peakLag = lag
            while peakLag < maxLag && correlation(peakLag + 1) >= correlation(peakLag) {
                peakLag += 1
            }

            if correlation(peakLag) >= clarityThreshold {
                return peakLag
            }
            lag = peakLag // este máximo no basta: seguir buscando más allá
        }
        return nil
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
