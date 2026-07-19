//
//  PitchAnalysisGate.swift
//  MiSiSol
//
//  Evita que el análisis de pitch acumule retraso cuando tarda más que la duración de un buffer.
//

import os

/// Serializa el análisis de pitch descartando los buffers que llegan mientras el anterior sigue
/// en curso, en vez de encolarlos. Un afinador quiere siempre la lectura más reciente del
/// micrófono, no procesar con retraso todo lo que se haya acumulado mientras tanto: si
/// `detectPitchWithDiagnostics` tarda más que un buffer (~85ms), sin este descarte la cola de
/// análisis crece sin límite y la UI acaba mostrando una lectura de hace segundos, como si la app
/// se hubiera quedado sorda.
///
/// `tryEnter()` está pensado para llamarse desde el hilo real-time de captura de audio, así que
/// usa un intento de bloqueo que nunca espera (`withLockIfAvailable`) en vez de un lock normal:
/// bloquear ese hilo, aunque fuera brevemente, puede hacer que se pierdan buffers de verdad.
final class PitchAnalysisGate {
    private let isBusy = OSAllocatedUnfairLock(initialState: false)

    /// Intenta marcar "análisis en curso". Devuelve `true` si lo consigue (no había ninguno en
    /// curso: procesar este buffer) o `false` si hay que descartarlo porque el anterior sigue sin
    /// terminar.
    func tryEnter() -> Bool {
        isBusy.withLockIfAvailable { busy -> Bool in
            guard !busy else { return false }
            busy = true
            return true
        } ?? false
    }

    /// Marca el análisis en curso como terminado, permitiendo que el siguiente buffer se acepte.
    func leave() {
        isBusy.withLock { $0 = false }
    }
}
