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
│   ├── PitchAnalysisGate.swift  // backpressure: descarta buffers si el análisis anterior sigue en curso
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
├── PitchAnalysisGateTests.swift
├── PitchDetectionCorpusTests.swift        // corpus de grabaciones reales, ver Fixtures/README.md
├── Fixtures/                              // 14 grabaciones reales + manifest.json (nota esperada, tolerancia)
├── ToneGeneratorTests.swift
├── TunerViewModelTests.swift
├── AudioEngineTests.swift                 // interrupciones/cambios de ruta, publicando las notificaciones reales
└── TunerViewModelAudioIntegrationTests.swift  // escuchar→referencia→parar→escuchar con AVAudioEngine real
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
- Autocorrelación (ACF) sobre `[Float]` + `sampleRate`, sin depender de AVAudioEngine — testeable
  con señales sintéticas.
- Busca el mejor máximo local de la correlación normalizada, recorriendo lags de menor a mayor
  (de frecuencia más aguda a más grave): salta la caída inicial por continuidad de la señal, y si
  un máximo local no cruza `clarityThreshold` no se rinde ahí — sigue buscando el siguiente,
  recordando el mejor visto por si ninguno llega a cruzarlo (ver "Historial de depuración" más abajo).
- **Corrección de octava** (`correctOctave`): una vez aceptado un candidato, comprueba la
  correlación al doble de su lag (la octava grave). Si es claramente mayor (margen > 0.05,
  calibrado con grabaciones reales), prefiere esa octava y repite mientras siga mejorando. El
  margen es necesario porque cualquier señal periódica también correlaciona bien en el doble de su
  propio periodo; sin margen, la corrección revertía fundamentales ya bien detectadas.
- **Diezmado previo** (`usesDecimation`, activado por defecto): antes de la ACF, filtra
  (paso-bajo, sinc + ventana de Hamming) y diezma la señal con `vDSP_desamp`.
  `decimationFactor(for:maxFrequency:)` calcula el mayor factor entero tal que la frecuencia de
  muestreo resultante siga siendo ≥10× `maxFrequency` (a 48kHz con `maxFrequency=1200Hz`, factor 4,
  hasta 12kHz). Reduce el coste de la ACF ~factor² sin perder precisión (verificado contra el
  corpus de grabaciones reales, ver Tests). Si el buffer es demasiado corto para el filtro, sigue
  sin diezmar en vez de fallar.
- La correlación se normaliza por la energía de cada segmento solapado (no por el número de
  muestras), para no sesgar el resultado a favor de lags grandes si los dos segmentos tuvieran
  energía distinta (p.ej. una señal con envolvente de ataque/decaimiento).
- Los productos internos de la correlación (cruzada y las dos autocorrelaciones de energía) se
  calculan con `vDSP_dotpr` (Accelerate), no con un bucle Swift escalar: rendimiento independiente
  del nivel de optimización del build, a diferencia de un bucle propio (mucho más lento en Debug
  sin optimizar).
- **Sin ventana de Hann**: se aplicaba antes de correlar, pero analizando el corpus de grabaciones
  reales quitarla no empeoró ninguna cuerda — la mejoró en la mayoría (más buffers cruzando el
  umbral de claridad, precisión en cents prácticamente igual). Tiene sentido: Hann es una técnica
  pensada para FFT (reduce fugas espectrales entre bins), no para ACF en dominio temporal, donde
  solo recortaba energía útil de los extremos del buffer.
- **Cálculo perezoso**: las correlaciones se calculan bajo demanda y se cachean por lag, en vez de
  precalcular todo el rango `[minLag, maxLag]` de antemano. La mayoría de sonidos reales tienen su
  periodo fundamental mucho antes de `maxLag`; precalcular todo el rango desperdiciaba trabajo en
  el caso común.
- Interpolación parabólica sobre el pico (ya corregido de octava si aplica) para una estimación de
  frecuencia sub-muestra.
- Rango por defecto: 30–1200Hz (cubre desde el Mi grave del bajo transportado varios semitonos
  abajo hasta el La agudo del ukelele/guitarra), `clarityThreshold = 0.5`.
- `PitchDetector.minimumBufferSize(sampleRate:minFrequency:)`: tamaño mínimo de buffer recomendado
  (2× el periodo de la frecuencia más grave a detectar).
- `detectPitchWithDiagnostics(in:sampleRate:)`: además de la frecuencia, devuelve la claridad real
  conseguida (`DetectionResult.clarity`), aunque no llegue a superar el umbral — para poder mostrar
  en pantalla (en builds DEBUG) por qué una señal real se está quedando corta, sin adivinarlo.

### PitchAnalysisGate.swift
- Descarta buffers mientras el análisis del anterior sigue en curso, en vez de encolarlos: si la
  ACF tarda más que la duración de un buffer (~85ms, sobre todo en Debug sin optimizar antes de
  usar vDSP), la cola de análisis acumulaba retraso sin límite y la UI acababa mostrando una
  lectura de hace segundos.
- `tryEnter()`/`leave()` con `OSAllocatedUnfairLock.withLockIfAvailable` (intento de bloqueo que
  nunca espera): seguro de llamar desde el hilo real-time de captura, donde bloquear aunque sea
  brevemente puede hacer que se pierdan buffers de verdad.

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
- Configura su propia `AVAudioSession` (`.playback`, modo `.default`) en cada `play()`, para que
  reproducir una nota funcione aunque la captura de micrófono no se haya llegado a arrancar
  todavía. `.playback` (no `.playAndRecord`): no necesita capturar nada mientras suena la
  referencia, y así no compite con la categoría `.record` que usa `AudioEngine` al escuchar (solo
  una puede estar activa a la vez; ver el momento delicado documentado en
  `TunerViewModel.stopReferenceNote()`).
- El estado de fase/amplitud se aísla en una clase `nonisolated` aparte (`TonePhaseState`) para
  que el closure de render de audio, que corre en el hilo real-time, no dependa del aislamiento a
  `@MainActor` por defecto del módulo (ver "Notas de concurrencia" más abajo).

### AudioEngine.swift
- `AVAudioEngine` con tap en el input node, buffer configurable (4096 muestras por defecto, ~93ms
  a 44.1kHz o ~85ms a los 48kHz reales de la mayoría de dispositivos — más del doble del periodo
  del Mi grave del bajo transportado, y latencia razonable).
- Sesión configurada como **`.record`, modo `.measurement`**, sin `.allowBluetooth` (ver
  "Historial de depuración" más abajo para el porqué del cambio desde `.playAndRecord`/`.default`).
  Sube la ganancia de entrada al máximo con `setInputGain(1.0)` si `isInputGainSettable`, para
  compensar la falta de AGC de `.measurement`.
- Expone los buffers vía closure (`onBuffer: ([Float], Double) -> Void`), invocado en el hilo
  real-time de captura; quien lo use es responsable de saltar a `@MainActor` para tocar UI. El
  closure se recuerda internamente (no solo se pasa a `start`), para poder reinstalar el tap sin
  que quien llama tenga que invocar `start` de nuevo (ver el punto siguiente).
- Maneja start/stop y expone el permiso de micrófono (`AVAudioApplication`, API de iOS 17+).
- **Resiliencia a interrupciones y cambios de ruta**: observa
  `AVAudioSession.interruptionNotification` (reanuda al terminar si estaba escuchando y el sistema
  lo permite, respetando `.shouldResume`), `.routeChangeNotification` (reinstala el tap si el
  motivo es un cambio real de hardware — auriculares conectados/desconectados... — no el de
  categoría que dispara la propia `AudioEngine` al configurar la sesión) y
  `.AVAudioEngineConfigurationChange` (acotada al propio `engine`, para no reaccionar a la del
  `AVAudioEngine` interno de `ToneGenerator`). Los tres observers llegan en un hilo arbitrario y se
  despachan al principal antes de tocar estado, para serializarlos con `start()`/`stop()` (que en
  esta app siempre se llaman desde el hilo principal) sin necesitar un lock nuevo.
- `onRestartError: ((Error) -> Void)?`: se invoca si un reintento automático (tras interrupción o
  cambio de ruta) falla, para que ese fallo no quede en silencio igual que el de un `start()`
  inicial fallido.
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
- `audioErrorMessage: String?`: mensaje si la captura no pudo arrancar (o un reintento automático
  de `AudioEngine` falló), para que `TunerView` avise con opción de reintentar en vez de dejar la
  app "muda" sin explicación. Se limpia al arrancar con éxito.
- La afinación activa se persiste por instrumento entre sesiones vía `TuningStore` (envuelve
  `UserDefaults`, codificando `Tuning` como JSON); se recupera al elegir instrumento y se guarda
  cada vez que se cambia de afinación (preset, transposición o custom).
- El procesado de pitch (`processPitch(_:)`) es directo y testeable sin AVAudioEngine real: se
  puede inyectar una frecuencia (o `nil`) y comprobar el resultado.
- El pitch se calcula en una cola serial en background (`pitchQueue`), no en el hilo real-time de
  captura de audio: la autocorrelación es demasiado costosa para ese hilo (bloquearlo acumula
  retraso o pierde buffers). Serial (no la cola global concurrente) para que los buffers no se
  procesen fuera de orden. Antes de encolar, `PitchAnalysisGate.tryEnter()` descarta el buffer
  (sin tocar `pitchQueue`) si el análisis del anterior sigue en curso.
- `playReferenceNote()` / `stopReferenceNote()`: paran la escucha del micrófono mientras suena la
  nota de referencia y la reanudan al terminar (solo si estaba activa antes), para no confundir
  el tono reproducido con la señal capturada. `stopReferenceNote()` espera
  `ToneGenerator.rampDuration` (el fundido de salida) antes de llamar a `startListening()`: como
  `AudioEngine` y `ToneGenerator` ya usan categorías de sesión distintas (`.record` vs.
  `.playback`), reclamar la sesión mientras el fundido de `ToneGenerator` todavía suena es el
  momento más delicado de la transición entre ambas.

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
- Aviso discreto (con botón "Reintentar") cuando `viewModel.audioErrorMessage` no es `nil`, justo
  debajo del header: el usuario nunca debería ver un afinador que simplemente no detecta nada sin
  ninguna explicación.
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
  41.20Hz, 36.7Hz transportada), silencio y ruido blanco (esperan `nil`), buffer demasiado corto,
  el error de octava con fundamental débil + 2º armónico dominante, `decimationFactor` (caso de
  referencia 48kHz→4), y que diezmar no cambie la frecuencia detectada frente a no diezmar.
- **PitchAnalysisGateTests**: `tryEnter()`/`leave()` básico, y un escenario con semáforos que
  simula un análisis lento mientras llegan varios buffers más (los intermedios se descartan; tras
  liberarse, el siguiente sí se procesa) — determinista, sin sleeps.
- **PitchDetectionCorpusTests**: corre el corpus de 14 grabaciones reales (`MiSiSolTests/Fixtures/`)
  a través de `PitchDetector` + la mediana móvil de `TunerViewModel`, comparando contra la nota
  esperada de `manifest.json` dentro de su tolerancia. Se salta con `XCTSkip` si el corpus no está
  presente.
- **ToneGeneratorTests**: periodicidad de los samples generados (cruces por cero, frecuencia
  dominante vía Goertzel), amplitud dentro de rango, y transición de estado play/stop real
  (arranca el engine de verdad en el simulador).
- **TunerViewModelTests**: suavizado, estado afinado/sube/baja, cambio de instrumento/afinación/
  cuerda, modo automático (selección de cuerda más cercana, histéresis), y tolerancia a lecturas
  fallidas puntuales — todo inyectando frecuencias directamente, sin AVAudioEngine real.
- **AudioEngineTests**: interrupciones y cambios de ruta publicando en `NotificationCenter` las
  mismas notificaciones reales que dispararía el sistema (`AVAudioSession.interruptionNotification`,
  `.routeChangeNotification`), con `AVAudioEngine` real arrancado de verdad. No sustituye a probarlo
  con hardware real (una llamada entrante de verdad, un auricular Bluetooth real), pero ejercita
  exactamente el mismo código de observers/reintento — encontró un crash real (ver punto 7 del
  historial). Son tests `async` con `Task.sleep` para dar margen a que el `DispatchQueue.main.async`
  de los observers se procese.
- **TunerViewModelAudioIntegrationTests**: la secuencia completa escuchar → reproducir nota de
  referencia → parar → seguir escuchando, con `AudioEngine`/`ToneGenerator` reales (no las
  dependencias por defecto de `TunerViewModelTests`). A diferencia de `AudioEngineTests`, son tests
  **síncronos** que bombean el run loop a mano con `RunLoop.current.run(until:)`: este flujo depende
  de un `DispatchQueue.main.asyncAfter` (un timer, no un `.async` inmediato), que no se dispara
  durante un `Task.sleep` dentro de un test `async` — ver punto 7 del historial para el porqué.

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
error de octava estaba verificado (con script en Python que replica el algoritmo) contra las 14
grabaciones sin regresiones, pero la sensación de uso real no había mejorado perceptiblemente.

6. **Revisión de arquitectura (Fable) y corrección estructural.** Con la lógica de `PitchDetector`
   ya validada contra grabaciones reales, una revisión de arquitectura señaló que el síntoma
   ("no detecta nada en dispositivo real") probablemente no estaba en el algoritmo de pitch en sí,
   sino alrededor: falta de backpressure en el procesado (una ACF lenta en Debug sin optimizar
   podía acumular retraso sin límite), coste de la ACF, configuración de la sesión de audio, y
   ausencia total de manejo de interrupciones/cambios de ruta. Se abordaron los cuatro a la vez,
   sin tocar el algoritmo de detección (ACF + `correctOctave` + interpolación parabólica):
   - **Backpressure** (`PitchAnalysisGate`): descarta buffers mientras el análisis del anterior
     sigue en curso, en vez de dejar que `pitchQueue` acumule retraso sin límite.
   - **Rendimiento de la ACF**: `vDSP_dotpr` (Accelerate) en vez de bucles Swift escalares
     (rendimiento independiente del nivel de optimización del build), diezmado previo con
     `vDSP_desamp` (reduce el coste ~factor², factor 4 a 48kHz), y se quitó la ventana de Hann
     (analizando el corpus, no aportaba nada a una ACF en dominio temporal — ver `PitchDetector.swift`).
   - **Sesión de audio dedicada**: `.record`/`.measurement` (no `.playAndRecord`/`.default`) al
     escuchar, sin `.allowBluetooth`, con `setInputGain` al máximo para compensar la falta de AGC.
     La prueba anterior de `.measurement` (punto 3) se hizo sin el diezmado ni el backpressure de
     esta ronda, así que probablemente estaba contaminada por el atasco de la cola de análisis, no
     por la ausencia de AGC en sí.
   - **Robustez de sesión**: `AudioEngine` ahora reacciona a interrupciones (llamadas, Siri) y
     cambios de ruta (auriculares conectados/desconectados), reanudando o reinstalando el tap en
     vez de quedarse "sordo" hasta reabrir la app; los fallos de arranque (antes con `try?`
     silencioso) se muestran en `TunerView` con opción de reintentar.
   - **Corpus de grabaciones en CI** (`PitchDetectionCorpusTests`): la validación manual con script
     en Python de los puntos 1 y 5 pasa a ser un test XCTest reproducible contra las mismas 14
     grabaciones, para que futuros cambios en el pipeline de audio se verifiquen automáticamente en
     vez de a mano.

   Cada pieza se verificó de la forma más rigurosa posible sin acceso a Xcode/dispositivo real
   desde este entorno: la lógica de diezmado/sin-Hann se validó replicando el algoritmo exacto en
   Python contra las 14 grabaciones (sin regresiones, varias cuerdas mejoran en claridad), y los
   tests nuevos (`PitchAnalysisGateTests`, ampliaciones de `PitchDetectorTests`,
   `PitchDetectionCorpusTests`) se diseñaron para poder razonar sobre su corrección leyendo el
   código, pero **no se ha podido compilar el proyecto ni ejecutar `xcodebuild test` ni probar en
   un dispositivo real** en esta ronda de cambios. La resiliencia a interrupciones/cambios de ruta
   y el aviso de error en `TunerView`, en particular, solo se han podido verificar por lectura de
   código: son exactamente el tipo de comportamiento que requiere probarse en un dispositivo real
   (provocar una llamada entrante, conectar/desconectar auriculares, etc.) antes de darlos por
   buenos.

7. **Primera compilación real de todo lo anterior (con Xcode disponible) y dos bugs que la lectura
   de código no había detectado.** `xcodebuild test` reveló dos problemas reales en cuanto se pudo
   ejecutar:
   - **`PitchAnalysisGate` sin `nonisolated`**: la misma familia de crash de concurrencia que ya
     había aparecido con `AudioEngine`/`ToneGenerator`/`TunerViewModel` (aislamiento a `@MainActor`
     por defecto del módulo + `deinit` con salto de actor, que crashea en este toolchain). Al ser
     una clase nueva, no se le había puesto el marcador — hacía fallar prácticamente todos los
     tests de `TunerViewModelTests` con `___BUG_IN_CLIENT_OF_LIBMALLOC_POINTER_BEING_FREED_WAS_NOT_ALLOCATED`.
   - **Crash real en `AudioEngine.handleInterruption`**: al empezar una interrupción, el código
     solo hacía `isRunning = false` sin quitar el tap de verdad (el comentario asumía que el
     sistema lo hacía por su cuenta al parar el motor; no es así). Al terminar la interrupción,
     `beginCapture()` intentaba instalar un tap nuevo encima del que seguía registrado, y
     `AVAudioEngine` lanza una excepción ObjC sin capturar → crash. Se encontró con un test que
     publica la notificación real de interrupción (`AudioEngineTests`) y se corrigió llamando a
     `stop()` (que sí quita el tap) en vez de solo tocar la propiedad.
   - Con ambos arreglados, la suite completa pasa: 78 tests, incluidos los dos nuevos ficheros
     (`AudioEngineTests`, `TunerViewModelAudioIntegrationTests`) que ejercitan interrupciones,
     cambios de ruta, y la secuencia escuchar→referencia→parar→escuchar con audio real (no mocks).
   - Nota sobre metodología: la primera versión de `TunerViewModelAudioIntegrationTests` daba un
     falso positivo (parecía que la escucha no se reanudaba tras la nota de referencia) porque
     usaba tests `async` con `Task.sleep`, que no bombean el run loop real del hilo principal — y
     `stopReferenceNote()` depende de un `DispatchQueue.main.asyncAfter` (un timer) para reanudar.
     Reescribiendo el test como síncrono con `RunLoop.current.run(until:)` (más fiel a cómo corre
     la app real, con `UIApplicationMain` bombeando el run loop de verdad) el test pasa limpio: la
     secuencia sí funciona, el problema era del arnés de test, no del código de producción.
   - Lo que sigue sin poder verificarse desde aquí, ni con estos trucos: Bluetooth real (el
     simulador no tiene pila Bluetooth de audio) y una interrupción/cambio de ruta genuinamente
     disparados por el sistema (llamada entrante real, auriculares físicos). Ver la sección
     siguiente para el detalle actualizado.

## Estado actual y preguntas abiertas

El patrón de esta depuración fue, durante un tiempo: probar en dispositivo → encontrar un síntoma
nuevo → analizar → añadir una corrección puntual al pipeline ACF. La revisión de arquitectura del
punto 6 cambió de nivel: en vez de seguir parcheando la detección, atacó el pipeline de captura y
procesado alrededor de ella. Preguntas que quedaban abiertas en la revisión anterior y cómo quedan
tras el punto 6:

- ~~¿La sesión de audio es la mejor opción disponible?~~ **Resuelto** (a falta de confirmación en
  dispositivo real): `.record`/`.measurement` + `setInputGain`, ver punto 6.
- ~~¿Tiene sentido seguir calibrando constantes a mano, o hace falta un corpus en CI?~~
  **Resuelto**: `PitchDetectionCorpusTests` corre las 14 grabaciones en cada test run.
- **¿El tamaño de buffer (4096 muestras) y la falta de solape entre buffers son limitantes?**
  Parcialmente abordado: el diezmado reduce el coste de procesar ese buffer, pero no cambia su
  duración (~85-93ms) ni introduce solape entre buffers consecutivos. Sigue abierto si eso importa
  en la práctica.
- **¿Es la autocorrelación en sí (frente a YIN/HPS/cepstrum) el enfoque correcto?** Sigue
  completamente abierto — explícitamente fuera de alcance en la ronda de cambios del punto 6, que
  se centró en el pipeline alrededor del algoritmo, no en el algoritmo.
- **¿Los transitorios de ataque (rasgueo/pulsación) necesitan un tratamiento explícito** (ignorar
  los primeros ~100-200ms de una nota nueva)? Sigue abierto; no se ha tocado.
- **La pregunta más importante sigue sin respuesta: ¿esto arregla lo que el usuario percibe en
  dispositivo real?** Todo lo del punto 6 está razonado y verificado hasta donde es posible sin
  Xcode ni dispositivo desde este entorno, pero ninguna cantidad de análisis fuera del dispositivo
  sustituye a probarlo ahí. Ver la sección de verificación final más abajo.
- Aparte de pitch: no hay UI para editar/eliminar afinaciones personalizadas ya guardadas (solo
  crearlas); la persistencia (`TuningStore`) guarda la última afinación por instrumento, pero no
  hay gestión de varias afinaciones custom guardadas.

## Verificación pendiente en dispositivo real

Los seis puntos siguientes se plantearon cuando esta ronda de cambios no se había podido ni
compilar. Ya hay acceso a Xcode (aunque no a un iPhone físico): esto es lo que se ha podido
verificar desde ahí y lo que sigue dependiendo genuinamente de un dispositivo real (ver punto 7
del historial para el detalle de cómo se verificó cada uno).

1. ~~`xcodebuild test` en verde~~ **Verificado.** 78 tests en verde, incluido el corpus
   (`PitchDetectionCorpusTests` se ejecuta de verdad, no se salta). Se encontraron y corrigieron
   dos bugs reales en el proceso (`PitchAnalysisGate` sin `nonisolated`, tap no retirado en
   `handleInterruption`) que la lectura de código no había detectado.
2. ~~Claridad fluida, sin congelarse; nota en <0.5s al tocar~~ **Parcialmente verificado.**
   Con una build de Debug optimizada (`-O`, para conservar la UI de DEBUG), la claridad se
   actualiza en directo sin congelarse (confirmado con capturas separadas en el tiempo). El
   requisito de "<0.5s al tocar una cuerda" no se ha podido verificar porque el simulador no tiene
   una guitarra real que tocar — sigue pendiente de confirmar con instrumento real.
3. **Bluetooth: sigue sin poder verificarse desde aquí.** El simulador de iOS no tiene pila
   Bluetooth de audio real; no hay forma de emparejar unos AirPods simulados. Genuinamente
   pendiente de dispositivo real.
4. ~~Secuencia escuchar → referencia → parar → seguir afinando~~ **Verificado**, con
   `TunerViewModelAudioIntegrationTests` (`AudioEngine`/`ToneGenerator` reales, no mocks): tras
   parar la nota de referencia, la escucha se reanuda sola. La primera versión del test dio un
   falso positivo por un problema del arnés de test (ver punto 7), no del código de producción.
5. ~~Interrupción real (llamada/Siri)~~ **Verificado por aproximación**, publicando la notificación
   real de `AVAudioSession` que el sistema mandaría (`AudioEngineTests`) — no es una llamada
   entrante genuina, pero ejercita el mismo código de observers/reintento. Encontró el crash del
   tap no retirado (punto 7), ya corregido. Una interrupción disparada por el sistema de verdad
   sigue sin poder confirmarse desde aquí.
6. ~~Conectar/desconectar auriculares~~ **Verificado por aproximación**, mismo mecanismo que el
   punto 5 (notificación de cambio de ruta publicada a mano). El comportamiento con auriculares
   físicos reales sigue pendiente de confirmar.

En resumen: de los seis, el 1 está verificado sin matices, el 2 y el 4 están verificados hasta
donde el simulador lo permite, y el 3/5/6 tienen verificación por aproximación o nula porque
dependen de hardware que el simulador no puede reproducir fielmente — seguirá haciendo falta
probarlos en un iPhone real antes de darlos por completamente resueltos.
