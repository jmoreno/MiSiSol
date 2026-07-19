//
//  PitchDetector.swift
//  MiSiSol
//
//  Detección de tono mediante autocorrelación (ACF). No depende de AVAudioEngine:
//  trabaja sobre un [Float] con su sampleRate, para poder testearse con señales
//  sintéticas sin necesidad de micrófono real.
//

import Accelerate
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
    /// Si diezmar la señal antes de la autocorrelación (ver `decimationFactor(for:)`). Activado
    /// por defecto: reduce drásticamente el coste de la ACF sin perder precisión (verificado
    /// contra grabaciones reales, ver más abajo), a costa de un pequeño filtrado paso-bajo
    /// previo. Se puede desactivar para comparar o depurar sin diezmado.
    let usesDecimation: Bool

    init(
        minFrequency: Float = 30.0,
        maxFrequency: Float = 1200.0,
        clarityThreshold: Float = 0.5,
        usesDecimation: Bool = true
    ) {
        self.minFrequency = minFrequency
        self.maxFrequency = maxFrequency
        self.clarityThreshold = clarityThreshold
        self.usesDecimation = usesDecimation
    }

    /// Margen mínimo por el que la correlación al doble de un lag candidato debe superarlo para
    /// preferir esa octava más grave (ver `correctOctave`). Calibrado analizando grabaciones reales
    /// de guitarra, bajo y ukelele: separa con buena fiabilidad los errores de octava genuinos
    /// (margen típicamente > 0.15) de las fundamentales ya correctas (margen típicamente < 0, la
    /// mayoría de las veces claramente negativo).
    private static let octaveCorrectionMargin: Float = 0.05

    /// Cuántas veces más rápido que `maxFrequency` debe quedar la frecuencia de muestreo tras
    /// diezmar (ver `decimationFactor(for:)`). 10x deja de sobra el margen de Nyquist (que solo
    /// exige 2x) para que el filtro antialiasing tenga una banda de transición cómoda.
    private static let decimationSafetyMultiple: Double = 10.0

    /// Número de coeficientes del filtro paso-bajo antialiasing aplicado antes de diezmar (ver
    /// `decimatedSignal`). Impar, para que el filtro (sinc con ventana de Hamming) tenga fase
    /// lineal simétrica.
    private static let decimationFilterTapCount = 63

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

        // Diezmar antes de la ACF reduce el coste ~factor² (menos muestras en el buffer y menos
        // lags que recorrer), sin perder precisión: `maxFrequency` limita el rango de interés muy
        // por debajo del Nyquist real del hardware (48kHz), así que casi toda esa resolución se
        // desperdicia en la ACF. Si el buffer es demasiado corto para el filtro antialiasing
        // (`decimatedSignal` devuelve `nil`), se sigue sin diezmar en vez de fallar.
        let factor = usesDecimation ? Self.decimationFactor(for: sampleRate, maxFrequency: Double(maxFrequency)) : 1
        let workingBuffer: [Float]
        let effectiveSampleRate: Double
        if factor > 1, let decimated = Self.decimatedSignal(buffer, factor: factor) {
            workingBuffer = decimated
            effectiveSampleRate = sampleRate / Double(factor)
        } else {
            workingBuffer = buffer
            effectiveSampleRate = sampleRate
        }

        let minLag = max(1, Int((effectiveSampleRate / Double(maxFrequency)).rounded(.down)))
        let maxLag = Int((effectiveSampleRate / Double(minFrequency)).rounded(.up))
        guard workingBuffer.count > maxLag, minLag < maxLag else { return DetectionResult(frequency: nil, clarity: 0) }

        guard workingBuffer.contains(where: { $0 != 0 }) else { return DetectionResult(frequency: nil, clarity: 0) } // silencio

        // Las correlaciones se calculan bajo demanda y se cachean, en vez de calcular todo el
        // rango [minLag, maxLag] de antemano: la mayoría de sonidos reales tienen su periodo
        // fundamental mucho antes de maxLag, así que precalcular todo el rango desperdicia
        // trabajo justo en el caso más común (y en una build sin optimizar puede tardar más de
        // lo que dura un buffer de audio, acumulando retraso).
        var cache = [Float?](repeating: nil, count: maxLag - minLag + 1)
        func correlation(atLag lag: Int) -> Float {
            let index = lag - minLag
            if let cached = cache[index] { return cached }
            let value = normalizedCrossCorrelation(workingBuffer, lag: lag)
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

        return DetectionResult(frequency: Float(effectiveSampleRate) / refinedLag, clarity: corrected.value)
    }

    // MARK: - Diezmado

    /// Factor entero por el que diezmar `sampleRate` antes de la ACF: el mayor factor tal que la
    /// frecuencia de muestreo resultante siga siendo al menos `decimationSafetyMultiple` veces
    /// `maxFrequency` (con `maxFrequency = 1200Hz` y el multiplicador por defecto de 10x, un
    /// hardware a 48kHz diezma con factor 4, hasta 12kHz).
    ///
    /// No expuesto como `private` para poder testearlo directamente con el caso de 48kHz del
    /// historial de depuración, sin depender de generar audio real a esa frecuencia de muestreo.
    static func decimationFactor(for sampleRate: Double, maxFrequency: Double) -> Int {
        let targetMinimumRate = decimationSafetyMultiple * maxFrequency
        guard targetMinimumRate > 0 else { return 1 }
        let factor = Int((sampleRate / targetMinimumRate).rounded(.down))
        return max(1, factor)
    }

    /// Aplica un filtro paso-bajo antialiasing y diezma por `factor` (> 1) en un solo paso
    /// (`vDSP_desamp`, pensado exactamente para esto). Devuelve `nil` si `buffer` no tiene
    /// muestras suficientes para el filtro (`decimationFilterTapCount`), en cuyo caso quien llama
    /// debe seguir sin diezmar en vez de fallar.
    private static func decimatedSignal(_ buffer: [Float], factor: Int) -> [Float]? {
        let tapCount = decimationFilterTapCount
        // vDSP_desamp necesita, para producir `outputCount` muestras, al menos
        // (outputCount - 1) * factor + tapCount muestras de entrada.
        let outputCount = (buffer.count - tapCount) / factor + 1
        guard outputCount > 0 else { return nil }

        // Corte al 90% del nuevo Nyquist (el de la señal ya diezmada), dejando un 10% de banda de
        // transición para que el filtro atenúe lo que si no haría aliasing. Expresado como
        // fracción del Nyquist *original* (que es como lo espera `lowPassFilterTaps`): al diezmar
        // por `factor`, el nuevo Nyquist es 1/factor del original, así que el corte equivale a
        // 0.9 / factor de ese Nyquist original.
        let taps = lowPassFilterTaps(cutoffFraction: 0.9 / Double(factor), tapCount: tapCount)

        var output = [Float](repeating: 0, count: outputCount)
        buffer.withUnsafeBufferPointer { input in
            taps.withUnsafeBufferPointer { filter in
                output.withUnsafeMutableBufferPointer { result in
                    vDSP_desamp(
                        input.baseAddress!,
                        vDSP_Stride(factor),
                        filter.baseAddress!,
                        result.baseAddress!,
                        vDSP_Length(outputCount),
                        vDSP_Length(tapCount)
                    )
                }
            }
        }
        return output
    }

    /// Genera los coeficientes de un filtro FIR paso-bajo (sinc truncado con ventana de Hamming),
    /// normalizado a ganancia unitaria en continua. `cutoffFraction` es la frecuencia de corte
    /// como fracción del Nyquist de la señal *sin diezmar* (1.0 = Nyquist completo).
    private static func lowPassFilterTaps(cutoffFraction: Double, tapCount: Int) -> [Float] {
        let m = Double(tapCount - 1)
        var taps = [Double](repeating: 0, count: tapCount)
        for i in 0..<tapCount {
            let k = Double(i) - m / 2.0
            let sincValue = k == 0 ? cutoffFraction : sin(.pi * cutoffFraction * k) / (.pi * k)
            // Ventana de Hamming: atenúa los lóbulos laterales del sinc truncado (si se cortara
            // en seco, la respuesta en frecuencia tendría rizado notable cerca del corte).
            let window = 0.54 - 0.46 * cos(2 * .pi * Double(i) / m)
            taps[i] = sincValue * window
        }
        let sum = taps.reduce(0, +)
        guard sum != 0 else { return taps.map(Float.init) }
        return taps.map { Float($0 / sum) }
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

    // MARK: - Correlación cruzada normalizada

    /// Correlación cruzada de `buffer` con su copia desplazada `lag` muestras, normalizada por
    /// la energía de cada uno de los dos segmentos solapados (no por su recuento de muestras, que
    /// sesgaría el resultado a favor de lags grandes si los dos segmentos tuvieran energía
    /// distinta, como pasaría con una señal con envolvente de ataque/decaimiento). El resultado
    /// queda acotado en [-1, 1], donde 1 significa periodicidad perfecta en ese lag.
    ///
    /// Los tres productos internos (correlación cruzada y las dos autocorrelaciones de energía)
    /// se calculan con `vDSP_dotpr` (Accelerate) en vez de un bucle Swift escalar: es una rutina
    /// precompilada cuyo rendimiento no depende del nivel de optimización del build, a diferencia
    /// de un bucle propio que en una build de Debug sin optimizar puede tardar bastante más.
    ///
    /// Nota histórica: esta función aplicaba antes una ventana de Hann al buffer antes de
    /// correlar, para reducir fugas espectrales. Analizando las 14 grabaciones reales del corpus
    /// de depuración (ver Specs.md), quitar la ventana no solo no empeoró la precisión ni la
    /// claridad de ninguna cuerda: la mejoró en la mayoría (más buffers cruzando el umbral, cents
    /// de error prácticamente iguales). Tiene sentido: la ventana de Hann es una técnica pensada
    /// para FFT (reduce fugas espectrales entre bins de frecuencia), no para ACF en dominio
    /// temporal, donde solo recorta energía útil de los extremos del buffer sin necesidad.
    private func normalizedCrossCorrelation(_ buffer: [Float], lag: Int) -> Float {
        let count = buffer.count - lag
        guard count > 0 else { return 0 }
        var sum: Float = 0
        var energyA: Float = 0
        var energyB: Float = 0
        buffer.withUnsafeBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return }
            let a = base
            let b = base + lag
            vDSP_dotpr(a, 1, b, 1, &sum, vDSP_Length(count))
            vDSP_dotpr(a, 1, a, 1, &energyA, vDSP_Length(count))
            vDSP_dotpr(b, 1, b, 1, &energyB, vDSP_Length(count))
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
