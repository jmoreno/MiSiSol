Quiero crear una app de iOS desde cero llamada "MiSiSol", un afinador de guitarra, bajo y ukelele.

> **Nota:** este documento arrancó como el prompt inicial del proyecto y se ha ido actualizando
> para reflejar el estado real de la app a medida que se ha ido construyendo e iterando con
> feedback de pruebas en dispositivo real. Las secciones describen cómo funciona la app *ahora*,
> no solo la intención original.

## Setup inicial
- Proyecto Xcode (App, SwiftUI, Swift, sin storage/CoreData/SwiftData).
- Target mínimo: iOS 17.
- Bundle ID: `com.zinkinapps.MiSiSol`.
- `NSMicrophoneUsageDescription` en español, configurado como `INFOPLIST_KEY_NSMicrophoneUsageDescription`
  en los build settings del target (el proyecto no usa un `Info.plist` físico, `GENERATE_INFOPLIST_FILE = YES`).
- Target de tests unitarios con XCTest (no Swift Testing, pese a que ese es el default de plantilla
  en Xcode 26): la lógica de audio/pitch es testeable sin hardware real de micrófono porque
  `PitchDetector` y `ToneGenerator.generateSamples` son funciones puras sobre `[Float]`.

## Arquitectura y estructura de carpetas
```
MiSiSol/
├── MiSiSolApp.swift
├── Models/
│   ├── Instrument.swift        // enum guitarra/bajo/ukelele
│   ├── Tuning.swift             // afinación (estándar, transportada, custom)
│   └── Note.swift                // nota musical: frecuencia <-> nota, cents
├── Audio/
│   ├── AudioEngine.swift        // wrapper sobre AVAudioEngine, captura del micrófono
│   ├── PitchDetector.swift      // detección de pitch por autocorrelación
│   └── ToneGenerator.swift      // generador + reproductor de nota de referencia
├── ViewModels/
│   └── TunerViewModel.swift     // @Observable, conecta audio con la UI
├── Views/
│   ├── TunerView.swift          // pantalla principal
│   ├── TunerTheme.swift         // paleta de colores y componentes visuales reutilizables
│   ├── InstrumentPicker.swift   // selector de instrumento (chips)
│   └── TuningPicker.swift       // selector de afinación (sheet)
MiSiSolTests/
├── NoteTests.swift
├── TuningTests.swift
├── PitchDetectorTests.swift
├── ToneGeneratorTests.swift
└── TunerViewModelTests.swift
```

## Detalles de implementación

### Note.swift
- `Note`: nombre + octava + distancia en semitonos respecto a A4 (440Hz, temperamento igual).
- `Note.frequency(forSemitonesFromA4:)`: f = 440 · 2^(n/12).
- `Note.note(forSemitonesFromA4:)`: construye la nota a n semitonos de A4.
- `Note.make(name:octave:)`: construye una nota a partir de nombre + octava (falla si el nombre
  no es una de las 12 notas cromáticas).
- `Note.closest(to:)`: nota más cercana a una frecuencia dada + desviación en cents.

### Tuning.swift
- `Tuning`: nombre + instrumento + lista ordenada de `Note` (una por cuerda, de más grave a más aguda).
- Afinaciones estándar por instrumento (en `Instrument.standardTuningNoteNames`):
  guitarra E2 A2 D3 G3 B3 E4, bajo E1 A1 D2 G2, ukelele (reentrante) G4 C4 E4 A4.
- `Tuning.transposedStandard(for:bySemitones:)`: recalcula las frecuencias de la afinación
  estándar desplazada N semitonos, con etiqueta legible ("Media asta abajo", "Un tono abajo"...).
- `Tuning.custom(instrument:name:notes:)`: afinación custom como lista de notas, independiente
  de la estándar.
- `Tuning.alternates(for:)`: afinaciones alternativas predefinidas (Drop D para guitarra).

### PitchDetector.swift
- Autocorrelación (ACF) con ventana Hann sobre `[Float]` + `sampleRate`, sin depender de
  AVAudioEngine — testeable con señales sintéticas.
- Busca el primer máximo local de la correlación normalizada (tras dejar atrás la caída inicial
  por continuidad de la señal), no el máximo global: evita engancharse a un múltiplo del periodo
  (error de octava).
- La correlación se normaliza por la energía de cada segmento solapado (no por el número de
  muestras), para no sesgar el resultado por el efecto de la ventana de Hann sobre lags grandes.
- **Cálculo perezoso**: las correlaciones se calculan bajo demanda y se cachean por lag, en vez de
  precalcular todo el rango `[minLag, maxLag]` de antemano. La mayoría de sonidos reales tienen su
  periodo fundamental mucho antes de `maxLag`; precalcular todo el rango desperdiciaba trabajo en
  el caso común y, en una build de Debug sin optimizar, podía tardar más que la duración de un
  buffer de audio.
- Interpolación parabólica sobre el pico para una estimación de frecuencia sub-muestra.
- Rango por defecto: 30–1200Hz (cubre desde el Mi grave del bajo transportado varios semitonos
  abajo hasta el La agudo del ukelele/guitarra), `clarityThreshold = 0.5`.
- `PitchDetector.minimumBufferSize(sampleRate:minFrequency:)`: tamaño mínimo de buffer recomendado
  (2× el periodo de la frecuencia más grave a detectar).

### ToneGenerator.swift
- `ToneGenerator.generateSamples(...)`: función estática pura que genera una onda senoidal,
  testeable sin audio real (verificado con cruces por cero y con el algoritmo de Goertzel).
- `play(frequency:amplitude:)` / `stop()`: el `AVAudioEngine` interno arranca **una sola vez**,
  de forma perezosa, y se queda preparado; no se reinicia en cada nota (reiniciarlo enganchaba y
  desenganchaba la ruta de audio del hardware en cada uso, lo que se oía como un chasquido).
- Fundido de entrada/salida de ~15ms (rampa de amplitud) para evitar el salto brusco entre
  silencio y sonando, que también se oía como chasquido.
- El nodo se conecta con el formato real de `engine.mainMixerNode` (sample rate del hardware),
  no uno fijo a 44.1kHz: el simulador siempre usa 44.1kHz, pero muchos dispositivos reales operan
  a otro sample rate o lo cambian según la ruta de audio activa, y ese desajuste causaba fallos de
  arranque intermitentes en dispositivo real.
- Configura su propia `AVAudioSession` (`.playAndRecord`, modo `.measurement`) de forma
  idempotente al arrancar el engine, para que reproducir una nota funcione aunque la captura de
  micrófono no se haya llegado a arrancar todavía.
- El estado de fase/amplitud se aísla en una clase `nonisolated` aparte (`TonePhaseState`) para
  que el closure de render de audio, que corre en el hilo real-time, no dependa del aislamiento a
  `@MainActor` por defecto del módulo (ver "Notas de concurrencia" más abajo).

### AudioEngine.swift
- `AVAudioEngine` con tap en el input node, buffer configurable (4096 muestras por defecto, ~93ms
  a 44.1kHz — más del doble del periodo del Mi grave del bajo transportado, y latencia razonable).
- Sesión configurada como `.playAndRecord`, modo `.measurement`: el modo `.default` en
  `.playAndRecord` aplica procesado de voz (control automático de ganancia, cancelación de eco)
  pensado para llamadas, que distorsiona la señal real de un instrumento acústico.
- Expone los buffers vía closure (`onBuffer: ([Float], Double) -> Void`), invocado en el hilo
  real-time de captura; quien lo use es responsable de saltar a `@MainActor` para tocar UI.
- Maneja start/stop y expone el permiso de micrófono (`AVAudioApplication`, API de iOS 17+).

### TunerViewModel.swift
- `@Observable`, con instrumento, afinación activa, cuerda seleccionada, nota/frecuencia
  detectada, cents respecto a la cuerda objetivo, y estado (`afinado` / `sube` / `baja` / `sin señal`).
- **Modo manual/automático** (`TunerMode`): en manual, la cuerda objetivo la elige el usuario
  (`selectString(at:)`). En automático, se recalcula sola buscando la cuerda de la afinación
  actual más cercana en cents a lo que se está escuchando (no las 12 notas cromáticas, solo las
  cuerdas reales del instrumento), con histéresis de 10 cents para no parpadear entre dos cuerdas
  vecinas cuando la nota cae cerca del punto medio entre ambas.
- Suavizado por media móvil (`smoothingWindowSize`, 5 lecturas por defecto) sobre la frecuencia
  detectada, para evitar que el indicador tiemble.
- **Tolerancia a lecturas fallidas**: una lectura sin detección clara no resetea el estado a
  "sin señal" de inmediato; hacen falta `maxConsecutiveMissedReadings` (3 por defecto, ~¼s)
  lecturas fallidas seguidas. Antes, una sola lectura débil puntual borraba todo el historial de
  suavizado, y la siguiente detección buena parecía "aparecer de la nada".
- El procesado de pitch (`processPitch(_:)`) es directo y testeable sin AVAudioEngine real: se
  puede inyectar una frecuencia (o `nil`) y comprobar el resultado.
- El pitch se calcula en una cola serial en background (`pitchQueue`), no en el hilo real-time de
  captura de audio: la autocorrelación es demasiado costosa para ese hilo (bloquearlo acumula
  retraso o pierde buffers). Serial (no la cola global concurrente) para que los buffers no se
  procesen fuera de orden.
- `playReferenceNote()` / `stopReferenceNote()`: paran la escucha del micrófono mientras suena la
  nota de referencia y la reanudan al terminar (solo si estaba activa antes), para no confundir
  el tono reproducido con la señal capturada.

### TunerView.swift / TunerTheme.swift
- Tema oscuro cálido **fijo** (no se adapta al modo claro/oscuro del sistema, como muchas apps de
  audio/instrumentos): fondo, superficie de chips, texto primario/secundario, acento naranja
  quemado, y colores de estado verde/ámbar/coral definidos en `TunerTheme.swift`.
- Header propio (sin navigation bar estándar de iOS): título + botón circular con icono
  `tuningfork` que abre el selector de afinación.
- Selector de instrumento y de cuerda como chips de color (cápsulas), no segmented controls
  nativos.
- Indicador de afinación: dial en forma de arco semicircular (no una barra horizontal), con zona
  verde para el margen de "afinado" y una aguja coloreada según el estado.
- Toggle Manual/Automático como píldora de dos segmentos con estilo propio.
- Botón de reproducir nota de referencia como cápsula acentuada, con icono play/stop según el
  estado (`isPlayingReferenceNote`).
- Pide permiso de micrófono al aparecer y empieza a escuchar si se concede; si se deniega, muestra
  una alerta explicando que hace falta activarlo en Ajustes.

### TuningPicker.swift
- Sheet con lista: afinaciones predefinidas (estándar + alternativas como Drop D), transposición
  rápida (botones de medio tono/un tono + stepper de semitonos libre), y afinación personalizada.
- Afinación personalizada: por cada cuerda, un `Picker` (desplegable con la nota completa, p.ej.
  "E2") y un `Stepper` que **comparten el mismo estado** — el stepper mueve la nota semitono a
  semitono (`Note.note(forSemitonesFromA4:)`) y el desplegable siempre refleja la nota resultante,
  en vez de ser dos controles independientes (nombre de nota + octava por separado).
- Reskin de colores (fondo, filas, texto) para combinar con el tema oscuro de `TunerView` al
  abrirse como sheet.

## Notas de concurrencia
El proyecto tiene `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: cualquier tipo sin anotación
explícita queda aislado a `@MainActor` por defecto. Esto es correcto para `TunerViewModel` en
general, pero rompe el uso de `AVAudioEngine`/`AVAudioSourceNode` con closures de render que se
invocan en el hilo real-time de audio: el runtime de concurrencia generaba un `deinit` con salto
de actor que crasheaba de forma intermitente en Xcode 26.5. `ToneGenerator`, `AudioEngine` y
`TunerViewModel` están marcados `nonisolated` explícitamente por esto; los saltos a `@MainActor`
necesarios para tocar estado observable se hacen a mano donde corresponde (`Task { @MainActor in ... }`).

## Tests
- **NoteTests**: cálculo de frecuencia a partir de semitonos, nota más cercana + cents para varios
  casos (exacta, desafinada por arriba/abajo).
- **TuningTests**: transposición de afinación estándar (frecuencias resultantes), afinación custom,
  afinaciones alternativas.
- **PitchDetectorTests**: señales sintéticas a frecuencias conocidas (82.41Hz, 110Hz, 440Hz,
  41.20Hz, 36.7Hz transportada), silencio y ruido blanco (esperan `nil`), buffer demasiado corto.
- **ToneGeneratorTests**: periodicidad de los samples generados (cruces por cero, frecuencia
  dominante vía Goertzel), amplitud dentro de rango, y transición de estado play/stop real
  (arranca el engine de verdad en el simulador).
- **TunerViewModelTests**: suavizado, estado afinado/sube/baja, cambio de instrumento/afinación/
  cuerda, modo automático (selección de cuerda más cercana, histéresis), y tolerancia a lecturas
  fallidas puntuales — todo inyectando frecuencias directamente, sin AVAudioEngine real.

## Pendiente / posibles siguientes pasos
- Ajustar `clarityThreshold` de `PitchDetector` con datos reales de instrumento acústico si, tras
  los cambios de sesión de audio y rendimiento, la detección sigue siendo poco sensible en
  dispositivo real (en desarrollo activo a fecha de esta actualización).
- No hay UI para editar/eliminar afinaciones personalizadas guardadas entre sesiones (no hay
  persistencia; toda afinación personalizada vive solo en memoria mientras la app está abierta).
