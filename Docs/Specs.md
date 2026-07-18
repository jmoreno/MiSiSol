Quiero crear una app de iOS desde cero llamada "MiSiSol", un afinador de guitarra, bajo y ukelele.

## Setup inicial
- Crea un nuevo proyecto Xcode (App, SwiftUI, Swift, sin storage/CoreData/SwiftData).
- Target mínimo: iOS 17.
- Bundle ID sugerido: com.saltodemata.misisol (ajústalo si detectas otro patrón en mis proyectos).
- Configura NSMicrophoneUsageDescription en Info.plist con un texto en español explicando que se necesita el micrófono para detectar el tono del instrumento.
- Añade un target de tests unitarios (XCTest) si no se crea por defecto, y configúralo para que pueda testear la lógica de audio/pitch sin depender del hardware real de micrófono.

## Arquitectura y estructura de carpetas
MiSiSol/
├── MiSiSolApp.swift
├── Models/
│   ├── Instrument.swift        // enum con guitarra, bajo, ukelele
│   ├── Tuning.swift            // modelo de afinación (estándar, transportada, custom)
│   └── Note.swift              // representación de nota musical + utilidades (frecuencia <-> nota, cents)
├── Audio/
│   ├── AudioEngine.swift       // wrapper sobre AVAudioEngine, captura de buffers del micrófono
│   ├── PitchDetector.swift     // algoritmo de detección de pitch
│   └── ToneGenerator.swift     // generador de onda senoidal para reproducir nota de referencia
├── ViewModels/
│   └── TunerViewModel.swift    // usa @Observable, conecta todo con la UI
├── Views/
│   ├── TunerView.swift         // pantalla principal con indicador visual
│   ├── InstrumentPicker.swift  // selector de instrumento
│   └── TuningPicker.swift      // selector de afinación (estándar/transportada/custom) + botón de reproducir nota
MiSiSolTests/
├── PitchDetectorTests.swift
├── NoteTests.swift
├── TuningTests.swift
├── ToneGeneratorTests.swift
└── TunerViewModelTests.swift

## Detalles de implementación

### Note.swift
- Estructura/enum que representa una nota musical (ej. E2, A2, D3...) con su frecuencia de referencia en Hz (usando A4 = 440Hz como referencia estándar, en temperamento igual).
- Función para calcular la frecuencia de cualquier nota a partir de su distancia en semitonos respecto a A4 (fórmula estándar: f = 440 * 2^(n/12)).
- Función para encontrar la nota más cercana a una frecuencia dada y calcular la desviación en cents.

### Tuning.swift
- Modelo `Tuning` que representa un conjunto de cuerdas, cada una con su nota base.
- Afinaciones estándar predefinidas por instrumento:
  - Guitarra: E2, A2, D3, G3, B3, E4
  - Bajo: E1, A1, D2, G2
  - Ukelele (reentrante): G4, C4, E4, A4
- Soporte para TRANSPOSICIÓN: cualquier afinación estándar se puede desplazar N semitonos arriba o abajo (ej. "media asta abajo" = -1 semitono, "un tono abajo" = -2 semitonos). Esto debe recalcular las frecuencias de cada cuerda automáticamente a partir de la afinación estándar + offset.
- Soporte para afinaciones CUSTOM: el usuario puede definir manualmente la nota de cada cuerda (ej. DGCGCD para ukelele, o cualquier combinación). Modélalo de forma que una afinación custom sea simplemente una lista de notas, sin depender de la estándar.
- Incluye algunas afinaciones alternativas predefinidas comunes como ejemplo (además de la custom libre), por ejemplo Drop D en guitarra (D2, A2, D3, G3, B3, E4).

### PitchDetector.swift
- Implementa detección de pitch mediante autocorrelación (ACF) sobre un buffer de audio (Float array).
- Debe manejar bien frecuencias graves (el Mi grave del bajo, ~41Hz, o incluso más grave si hay transposición hacia abajo), lo que implica un buffer de tamaño suficiente (calcula el tamaño mínimo necesario y coméntalo en el código).
- Aplica una ventana (Hann window) antes de la autocorrelación para reducir artefactos.
- Devuelve la frecuencia fundamental estimada en Hz, o nil si no hay señal suficientemente clara (usa un umbral de confianza/claridad).
- Esta clase NO debe depender de AVAudioEngine directamente: debe recibir un [Float] y un sampleRate, y devolver Float?. Esto es clave para poder testearla sin hardware real.

### ToneGenerator.swift
- Genera una onda senoidal pura a una frecuencia dada y la reproduce por el altavoz, usando AVAudioEngine con un AVAudioSourceNode (o AVAudioPlayerNode con buffer generado, lo que resulte más simple de testear).
- Debe poder empezar/parar la reproducción de una nota concreta (por frecuencia en Hz).
- Pensado para poder testear la generación de la forma de onda (valores del buffer) sin necesidad de reproducir audio real en los tests, separando "generar samples" de "reproducir por el altavoz".
- Ten en cuenta que este engine de reproducción y el de captura del micrófono (AudioEngine.swift) pueden necesitar coexistir o desactivarse mutuamente (no capturar el propio tono reproducido como si fuera la señal de afinación).

### AudioEngine.swift
- Configura AVAudioEngine con un tap en el input node.
- Tamaño de buffer configurable (pensado para poder capturar suficiente señal para notas graves, incluyendo afinaciones transportadas hacia abajo).
- Expone los buffers de audio (por ejemplo, mediante un closure o Combine/AsyncStream) para que TunerViewModel los pase a PitchDetector.
- Maneja el ciclo de vida (start/stop) y el permiso de micrófono.

### TunerViewModel.swift
- @Observable, con propiedades: instrumento seleccionado, afinación activa (estándar/transportada/custom), cuerda/nota objetivo, nota detectada, frecuencia detectada, desviación en cents, estado (afinado / sube / baja / sin señal).
- Aplica un suavizado simple (media móvil o similar) sobre las frecuencias detectadas para evitar que el indicador tiemble, sin introducir demasiada latencia.
- Lógica para considerar "afinado" cuando la desviación esté dentro de un margen de cents configurable (por ejemplo ±5 cents).
- Método para reproducir la nota de referencia de la cuerda seleccionada usando ToneGenerator, pausando temporalmente la escucha del micrófono mientras suena (o filtrando para no confundir la señal).

### TunerView.swift
- Indicador visual claro de afinado/desafinado (aguja, barra de cents, o similar) usando SwiftUI nativo.
- Selector de instrumento visible (guitarra/bajo/ukelele).
- Muestra la nota detectada y frecuencia en Hz.
- Colores: verde si está afinado, rojo/naranja si hay que subir o bajar.
- Botón para reproducir la nota de referencia de la cuerda seleccionada (icono de altavoz).

### TuningPicker.swift
- Selector de afinación: estándar, afinaciones alternativas predefinidas (ej. Drop D), transposición rápida (botones +/- semitono o selector de "medio tono abajo", "un tono abajo", etc.), y opción de afinación custom (permite al usuario asignar manualmente la nota de cada cuerda).
- Al cambiar de afinación, se debe reflejar inmediatamente en TunerView (nuevas frecuencias objetivo por cuerda).

## Tests (importante, quiero cobertura desde el inicio)
- PitchDetectorTests: genera señales sintéticas (senoidales puras) a frecuencias conocidas (ej. 82.41Hz, 110Hz, 440Hz, 41.20Hz, y alguna transportada hacia abajo tipo 36.7Hz) y verifica que el detector devuelve la frecuencia correcta dentro de un margen de tolerancia. Incluye también un test con silencio/ruido blanco donde se espera nil o baja confianza.
- NoteTests: verifica el cálculo de frecuencia a partir de semitonos respecto a A4, y el cálculo de nota más cercana + cents de desviación para varios casos (nota exacta, desafinada por arriba, por abajo).
- TuningTests: verifica que la transposición de una afinación estándar (ej. guitarra -2 semitonos) calcula bien las frecuencias resultantes, y que una afinación custom (ej. ukelele DGCGCD... ajusta al número de cuerdas real del instrumento) se construye correctamente.
- ToneGeneratorTests: verifica que los samples generados para una frecuencia dada tienen la periodicidad esperada (ej. comprobando cruces por cero o la frecuencia dominante mediante FFT simple sobre el buffer generado).
- TunerViewModelTests: verifica la lógica de suavizado y el estado (afinado/sube/baja) dado un conjunto de frecuencias de entrada simuladas, y que cambiar de afinación actualiza correctamente la nota objetivo, sin depender de AVAudioEngine real (usa un mock o inyecta el pitch directamente).

## Instrucciones de trabajo
- Ve paso a paso: primero el proyecto y estructura, luego Models (Note, Tuning), luego Audio (PitchDetector y ToneGenerator, con sus tests), luego ViewModels (con tests), y al final la UI.
- Después de cada bloque, compila y corre los tests antes de seguir al siguiente.
- Usa nombres y comentarios en español para el dominio (afinación, cuerdas, notas), pero el código en sí (nombres de variables/funciones) en inglés, siguiendo convenciones estándar de Swift.
- Si tienes que tomar una decisión de diseño no especificada aquí, toma la opción más simple y coméntala brevemente.