# MiSiSol

Afinador para iOS de guitarra, bajo y ukelele, escrito en SwiftUI.

## Qué hace

- Detecta el tono de la nota que estás tocando a través del micrófono (autocorrelación sobre el audio capturado) y muestra la nota, la frecuencia en Hz y la desviación en cents respecto a la cuerda objetivo, con indicador visual de afinado / sube / baja.
- Soporta guitarra, bajo y ukelele, con afinaciones estándar predefinidas para cada uno.
- Permite transportar cualquier afinación estándar N semitonos arriba o abajo (media asta, un tono, etc.), y definir afinaciones alternativas (ej. Drop D) o completamente personalizadas cuerda a cuerda.
- Reproduce la nota de referencia de la cuerda seleccionada (tono senoidal generado por la app) para afinar de oído, pausando la escucha del micrófono mientras suena.

## Estructura

- `MiSiSol/Models` — `Note`, `Instrument`, `Tuning`: representación de notas musicales y afinaciones.
- `MiSiSol/Audio` — `PitchDetector` (detección de tono por autocorrelación, sin dependencias de hardware), `ToneGenerator` (generación y reproducción de la nota de referencia) y `AudioEngine` (captura de micrófono).
- `MiSiSol/ViewModels` — `TunerViewModel`: conecta audio y UI, con suavizado de la lectura de frecuencia.
- `MiSiSol/Views` — pantalla principal del afinador y selectores de instrumento/afinación.
- `MiSiSolTests` — tests unitarios (XCTest) de la lógica de notas, afinaciones, detección de tono y generador de onda, incluyendo señales sintéticas para no depender de micrófono real.

## Requisitos

- Xcode con SDK de iOS 17 o superior.
- Target mínimo: iOS 17.
