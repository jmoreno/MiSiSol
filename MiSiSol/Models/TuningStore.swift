//
//  TuningStore.swift
//  MiSiSol
//
//  Persiste la última afinación elegida para cada instrumento, para recuperarla entre sesiones.
//

import Foundation

struct TuningStore {
    private let defaults: UserDefaults

    /// `defaults` es inyectable (no siempre `.standard`) para que los tests puedan usar un
    /// dominio de UserDefaults aislado, sin tocar ni depender de las preferencias reales de la app.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadTuning(for instrument: Instrument) -> Tuning? {
        guard let data = defaults.data(forKey: key(for: instrument)) else { return nil }
        return try? JSONDecoder().decode(Tuning.self, from: data)
    }

    func saveTuning(_ tuning: Tuning, for instrument: Instrument) {
        guard let data = try? JSONEncoder().encode(tuning) else { return }
        defaults.set(data, forKey: key(for: instrument))
    }

    private func key(for instrument: Instrument) -> String {
        "com.zinkinapps.misisol.tuning.\(instrument.rawValue)"
    }
}
