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
│   ├── Note.swift                // nota musical: frecuencia <-> nota, cents
│   └── TuningStore.swift         // persistencia de la afinación activa por instrumento (UserDefaults)
├── Audio/
│   ├── AudioEngine.swift        // wrapper sobre AVAudioEngine, captura del micrófono
│   ├── PitchDetector.swift      // detección de pitch por autocorrelación
│   └── ToneGenerator.swift      // generador + reproductor de nota de referencia
├── ViewModels/
│   └── TunerViewModel.swift     // @Observable, conecta audio con la UI
├── Views/
│   ├── TunerView.swift          // pantalla principal
│   ├── TunerTheme.swift         // paleta de colores, componentes visuales reutilizables, GaugeStyle
│   ├── InstrumentPicker.swift   // selector de instrumento (chips)
│   └── TuningPicker.swift       // selector de afinación (sheet)
MiSiSolTests/
├── NoteTests.swift
├── TuningTests.swift
├── TuningStoreTests.swift
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
- Busca el mejor máximo local de la correlación normalizada, recorriendo lags de menor a mayor
  (de frecuencia más aguda a más grave): salta la caída inicial por continuidad de la señal, y si
  un máximo local no cruza `clarityThreshold` no se rinde ahí — sigue buscando el siguiente,
  recordando el mejor visto por si ninguno llega a cruzarlo (ver "Historial de depuración" más abajo).
- **Corrección de octava** (`correctOctave`): una vez aceptado un candidato, comprueba la
  correlación al doble de su lag (la octava grave). Si es claramente mayor (margen > 0.05,
  calibrado con grabaciones reales), prefiere esa octava y repite mientras siga mejorando. El
  margen es necesario porque cualquier señal periódica también correlaciona bien en el doble de su
  propio periodo; sin margen, la corrección revertía fundamentales ya bien detectadas.
- La correlación se normaliza por la energía de cada segmento solapado (no por el número de
  muestras), para no sesgar el resultado por el efecto de la ventana de Hann sobre lags grandes.
- **Cálculo perezoso**: las correlaciones se calculan bajo demanda y se cachean por lag, en vez de
  precalcular todo el rango `[minLag, maxLag]` de antemano. La mayoría de sonidos reales tienen su
  periodo fundamental mucho antes de `maxLag`; precalcular todo el rango desperdiciaba trabajo en
  el caso común y, en una build de Debug sin optimizar, podía tardar más que la duración de un
  buffer de audio.
- Interpolación parabólica sobre el pico (ya corregido de octava si aplica) para una estimación de
  frecuencia sub-muestra.
- Rango por defecto: 30–1200Hz (cubre desde el Mi grave del bajo transportado varios semitonos
  abajo hasta el La agudo del ukelele/guitarra), `clarityThreshold = 0.5`.
- `PitchDetector.minimumBufferSize(sampleRate:minFrequency:)`: tamaño mínimo de buffer recomendado
  (2× el periodo de la frecuencia más grave a detectar).
- `detectPitchWithDiagnostics(in:sampleRate:)`: además de la frecuencia, devuelve la claridad real
  conseguida (`DetectionResult.clarity`), aunque no llegue a superar el umbral — para poder mostrar
  en pantalla (en builds DEBUG) por qué una señal real se está quedando corta, sin adivinarlo.

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
- Configura su propia `AVAudioSession` (`.playAndRecord`, modo `.default`, igual que `AudioEngine`)
  de forma idempotente al arrancar el engine, para que reproducir una nota funcione aunque la
  captura de micrófono no se haya llegado a arrancar todavía.
- El estado de fase/amplitud se aísla en una clase `nonisolated` aparte (`TonePhaseState`) para
  que el closure de render de audio, que corre en el hilo real-time, no dependa del aislamiento a
  `@MainActor` por defecto del módulo (ver "Notas de concurrencia" más abajo).

### AudioEngine.swift
- `AVAudioEngine` con tap en el input node, buffer configurable (4096 muestras por defecto, ~93ms
  a 44.1kHz o ~85ms a los 48kHz reales de la mayoría de dispositivos — más del doble del periodo
  del Mi grave del bajo transportado, y latencia razonable).
- Sesión configurada como `.playAndRecord`, modo **`.default`** (no `.measurement`: se probó y se
  revirtió, ver "Historial de depuración" más abajo). `.default` aplica control automático de
  ganancia de entrada, que da una señal más fuerte sin tocar el móvil pegado al instrumento; el
  procesado de voz que también aplica (pensado para llamadas) es el coste a cambio.
- Expone los buffers vía closure (`onBuffer: ([Float], Double) -> Void`), invocado en el hilo
  real-time de captura; quien lo use es responsable de saltar a `@MainActor` para tocar UI.
- Maneja start/stop y expone el permiso de micrófono (`AVAudioApplication`, API de iOS 17+).
- **Grabación de depuración (solo DEBUG)**: `startDebugRecording(to:)` / `stopDebugRecording()`
  escriben en paralelo, a un `.wav`, el mismo audio crudo que recibe `PitchDetector` (antes de
  cualquier suavizado). Pensado para capturar un caso real que falla y analizarlo fuera del
  dispositivo en vez de depurarlo a ciegas por descripción.

### TunerViewModel.swift
- `@Observable`, con instrumento, afinación activa, cuerda seleccionada, nota/frecuencia
  detectada, cents respecto a la cuerda objetivo, y estado (`afinado` / `sube` / `baja` / `sin señal`).
- **Modo manual/automático** (`TunerMode`): en manual, la cuerda objetivo la elige el usuario
  (`selectString(at:)`). En automático, se recalcula sola buscando la cuerda de la afinación
  actual más cercana en cents a lo que se está escuchando (no las 12 notas cromáticas, solo las
  cuerdas reales del instrumento), con histéresis de 10 cents para no parpadear entre dos cuerdas
  vecinas cuando la nota cae cerca del punto medio entre ambas.
- Suavizado por **mediana móvil** (`smoothingWindowSize`, 5 lecturas por defecto, no media) sobre
  la frecuencia detectada: un pico de ruido puntual que por casualidad supere el umbral de claridad
  queda como un valor suelto dentro de la ventana y la mediana lo ignora por completo, mientras que
  una media lo dejaría desplazar el resultado mostrado en cada lectura suelta.
- **Tolerancia a lecturas fallidas**: una lectura sin detección clara no resetea el estado a
  "sin señal" de inmediato; hacen falta `maxConsecutiveMissedReadings` (3 por defecto, ~¼s)
  lecturas fallidas seguidas. Antes, una sola lectura débil puntual borraba todo el historial de
  suavizado, y la siguiente detección buena parecía "aparecer de la nada".
- `lastClarity`: claridad (0...1) de la última lectura vía `detectPitchWithDiagnostics`, expuesta
  para mostrarla en pantalla en builds DEBUG.
- La afinación activa se persiste por instrumento entre sesiones vía `TuningStore` (envuelve
  `UserDefaults`, codificando `Tuning` como JSON); se recupera al elegir instrumento y se guarda
  cada vez que se cambia de afinación (preset, transposición o custom).
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
- Indicador de afinación: dos estilos intercambiables (`GaugeStyle`, persistido en `@AppStorage`) —
  dial en forma de arco semicircular con aguja, o barra horizontal con una bolita que se mueve a
  los lados. Ambos con zona verde para el margen de "afinado", coloreados según el estado.
- En builds DEBUG: claridad de la última lectura en pantalla, y un botón para grabar/compartir el
  audio crudo del micrófono a un `.wav` (ver `AudioEngine`).
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

## Historial de depuración de detección de pitch en dispositivo real

La lógica de `PitchDetector` (autocorrelación + ventana Hann + interpolación parabólica) se
diseñó y testeó inicialmente solo con señales sintéticas (senoidales puras). Al probarla con
instrumento real han ido apareciendo, uno tras otro, varios problemas que las señales sintéticas
no exponían. Orden cronológico real (no solo el orden "bonito" con el que se explicaría a
posteriori):

1. **Cuerda B3 de guitarra sin detectarse, E4 sí.** `dominantPeakLag` se rendía (devolvía `nil`)
   en el primer máximo local de la correlación si no cruzaba `clarityThreshold`, sin seguir
   buscando. Con una sinusoide pura eso no pasa nunca, pero un instrumento real tiene armónicos
   con fases relativas arbitrarias que crean máximos intermedios de correlación baja *antes* del
   periodo fundamental real. Se reprodujo matemáticamente sin necesidad de la guitarra (fundamental
   + un armónico con fases variadas) y se corrigió: si un máximo no cruza el umbral, se sigue
   buscando el siguiente en vez de rendirse.
2. **Instrumento real vs. sintético en general.** Se detectó que `.playAndRecord` en modo
   `.default` aplica AGC/cancelación de eco (procesado pensado para llamadas) que puede distorsionar
   la señal de un instrumento; se cambió a `.measurement`. Por separado, se descubrió que el cálculo
   de autocorrelación precalculaba todo el rango de lags de antemano, lo que en una build de Debug
   sin optimizar podía tardar más que la duración de un buffer y acumular retraso.
3. **`.measurement` empeoró el volumen capturado.** Sin AGC de entrada, la señal quedaba floja salvo
   pegando el móvil al instrumento, bajando la claridad de la autocorrelación en general (no solo en
   cuerdas graves). Se revirtió a `.default`.
4. **E2 rasgueado a bajo volumen no se detectaba** (claridad fluctuando 0.15–0.5) y en algún momento
   se confundió con G2 pese a estar bien afinado en E2 — un error de un tercio menor, no de octava,
   así que no encajaba con el bug ya corregido en el punto 1. Sin poder escuchar la señal real, se
   añadió una función de grabación de depuración (`AudioEngine.startDebugRecording`, botón en
   `TunerView` solo en DEBUG) para capturar el audio crudo tal cual llega a `PitchDetector` y
   analizarlo fuera del dispositivo.
5. **Análisis de 14 grabaciones reales** (las 6 cuerdas de una guitarra acústica, las 4 de un bajo
   eléctrico y las 4 de un ukelele, todas al aire) reveló un **error de octava sistemático y
   reproducible**: G3 de guitarra se detectaba consistentemente como G4, y D2 de bajo como D3, con
   correlación alta y estable (no ruido) — el segundo armónico de esas cuerdas cruzaba el umbral de
   claridad *antes* que el periodo real, y el algoritmo se quedaba con ese primer candidato sin
   comprobar que el periodo real (el doble del lag) tenía correlación todavía más alta. Se corrigió
   con `correctOctave`: compara la correlación al doble del lag candidato y prefiere esa octava
   grave solo si la mejora es clara (margen > 0.05, calibrado contra las 14 grabaciones para no
   romper las cuerdas que ya se detectaban bien). Las mismas grabaciones mostraron que B3, E1 y A1
   tenían una desviación de 20–65 cents muy estable (no ruido): probablemente esas cuerdas
   simplemente no estaban afinadas con precisión al grabar, no un bug de detección.

**Estado tras el punto 5, según el usuario probando en dispositivo real: "está igual".** El fix del
error de octava está verificado (con script en Python que replica el algoritmo) contra las 14
grabaciones sin regresiones, pero la sensación de uso real no ha mejorado perceptiblemente. No está
confirmado si eso significa que persiste el mismo problema (quizás el build probado no incluía aún
el fix), si hay otro problema no capturado en las grabaciones analizadas, o si el problema real es
de una naturaleza que el enfoque actual (ACF por buffer, con validaciones a posteriori) no puede
resolver con más parches puntuales.

## Estado actual y preguntas abiertas para revisión de arquitectura

El patrón de esta depuración ha sido: probar en dispositivo → encontrar un síntoma nuevo → analizar
(matemáticamente o con grabaciones reales) → añadir una corrección puntual al mismo pipeline ACF
(threshold, corrección de octava, tolerancia a fallos, sesión de audio...). Cada corrección ha
sido válida y verificada para el caso que la motivó, pero el usuario no percibe mejora global, lo
que sugiere que quizás el problema no es una serie de bugs puntuales sino algo más estructural del
enfoque. Preguntas concretas para quien revise la arquitectura:

- **¿Es la autocorrelación por buffer independiente el enfoque correcto?** Cada buffer de ~4096
  muestras se analiza de forma aislada; el único estado entre buffers vive en `TunerViewModel`
  (mediana de 5 lecturas, histéresis). ¿Compensaría más usar información entre buffers dentro del
  propio detector (p.ej. ventanas solapadas, seguimiento de fase, o un método como YIN/HPS/cepstrum
  en vez de ACF pura), en lugar de seguir ajustando umbrales y correcciones sobre ACF?
- **¿El tamaño de buffer (4096 muestras, ~85-93ms) y la falta de solape entre buffers consecutivos
  son limitantes?** Para notas graves (bajo) el periodo ocupa una fracción grande del buffer;
  ¿ventanas más largas y solapadas (con más coste de CPU/latencia) darían estimaciones más estables?
- **¿La sesión de audio (`.default` con AGC) es la mejor opción disponible, o hay un punto intermedio
  no probado** (p.ej. `.measurement` + ganancia de entrada manual, o normalización de nivel en
  software antes de la autocorrelación) que combine señal fuerte sin el procesado de voz?
- **¿Los transitorios de ataque (rasgueo/pulsación) necesitan un tratamiento explícito** (ignorar
  los primeros ~100-200ms de una nota nueva, detectar el ataque y descartarlo) en vez de confiar en
  que el umbral de claridad y la tolerancia a fallos los absorban?
- **¿Tiene sentido seguir calibrando constantes (`clarityThreshold`, `octaveCorrectionMargin`,
  tamaño de buffer...) a mano contra grabaciones puntuales,** o el proyecto necesitaría un paso de
  calibración/test más sistemático (un corpus de grabaciones de referencia con nota esperada
  conocida, corrido automáticamente en CI) para no depender de "probar y ver qué tal"?
- Aparte de pitch: no hay UI para editar/eliminar afinaciones personalizadas ya guardadas (solo
  crearlas); la persistencia (`TuningStore`) guarda la última afinación por instrumento, pero no
  hay gestión de varias afinaciones custom guardadas.
