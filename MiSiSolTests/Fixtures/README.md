# Corpus de grabaciones reales

Estas 14 grabaciones (6 cuerdas de guitarra acústica, 4 de bajo eléctrico, 4 de ukelele, todas al
aire) son las mismas que se usaron para diagnosticar y corregir el error de octava en `PitchDetector`
(ver el historial de depuración en `Docs/Specs.md`). `PitchDetectionCorpusTests.swift` las procesa
buffer a buffer (igual que en producción: 4096 muestras por buffer) a través de `PitchDetector` y
la mediana móvil de `TunerViewModel`, y comprueba que la nota final detectada coincide con la
esperada dentro de la tolerancia indicada en `manifest.json`.

Tres de las catorce (`guitar_B3.wav`, `bass_E1.wav`, `bass_A1.wav`) tienen la tolerancia ampliada a
propósito: esas cuerdas estaban desafinadas de origen al grabarlas (una desviación estable de
20-65 cents, no ruido de detección), según quedó documentado analizando estas mismas grabaciones.

## Si estos `.wav` no están presentes

El test correspondiente se salta con `XCTSkip` en vez de fallar (o de dar un falso positivo). Para
tenerlos:

1. Usa el botón de depuración "Grabar audio debug" de `TunerView` (solo en builds DEBUG) mientras
   tocas la cuerda correspondiente unos segundos, y comparte el `.wav` resultante.
2. Renómbralo siguiendo el patrón `<instrumento>_<nota>.wav` (p.ej. `guitar_E2.wav`) y colócalo en
   esta carpeta.
3. Si añades una cuerda/nota que no estaba en `manifest.json`, añade también su entrada ahí
   (`file`, `instrument`, `note`, `expectedFrequency` en Hz, `toleranceCents`; `comment` es
   opcional, para documentar por qué una tolerancia es más ancha de lo habitual).

## Formato

Mono, PCM float32, cualquier frecuencia de muestreo (el test la lee de cada `.wav`, no asume
44.1kHz ni 48kHz). Es el mismo formato que produce la función de grabación de depuración de
`AudioEngine`.
