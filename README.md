# Manticora

Escáner de documentos para Android hecho con Flutter. Cubre el flujo completo
de CamScanner —capturar, enderezar, realzar, reconocer texto y exportar— pero
**todo el procesamiento ocurre en el dispositivo**: no hay servidor, ni cuenta,
ni conexión necesaria.

---

## Puesta en marcha

Todo el entorno se instala con un único script. **No necesita root**: Flutter va
a `$HOME` y el SDK de Android es el que ya tienes.

```bash
chmod +x setup.sh     # (en NTFS ya viene ejecutable)
./setup.sh            # toolchain + dependencias + diagnóstico
```

Fases sueltas, si prefieres ir paso a paso:

| Comando | Qué hace |
|---|---|
| `./setup.sh toolchain` | Descarga y configura Flutter 3.47.2, ajusta el entorno, acepta licencias |
| `./setup.sh project` | Redirige `build/`, resuelve dependencias |
| `./setup.sh doctor` | `flutter doctor -v` |
| `./setup.sh clean` | Limpia el proyecto y restaura el enlace de `build/` |
| `./setup.sh test` | Ejecuta las pruebas |
| `./setup.sh build` | Compila los APK y los deja en `dist/` |
| `./setup.sh run` | Ejecuta en el móvil o, si no hay ninguno, arranca el emulador |
| `./setup.sh run linux` | Ejecuta en el escritorio (para iterar rápido en la interfaz) |
| `./setup.sh install` | Instala el APK ya compilado en el dispositivo conectado |
| `./setup.sh emulator` | Arranca el AVD instalado y espera a que termine de iniciarse |

El script escribe un bloque delimitado (`# >>> MANTICORA dev env >>>`) en
`~/.zshenv` y `~/.bashrc`; es idempotente, puedes ejecutarlo las veces que
quieras. Abre una terminal nueva —o `source ~/.zshenv`— para tener `flutter` en
el `PATH`.

### Detalles del equipo

- El proyecto vive en una partición **NTFS** (`SSD500`), donde Gradle va lento y
  puede tropezar con bloqueos de ficheros. Por eso `setup.sh` sustituye `build/`
  por un enlace simbólico a `~/.cache/manticora/build`, que está en ext4.
- `~/.gradle` y `~/.pub-cache` ya estaban en ext4, así que se dejan como están.
- NDK fijado a `28.2.13676358`, que es el que exigen los plugins y el que ya
  tienes instalado.
- En `android/gradle.properties` están desactivadas la compilación incremental
  de Kotlin y la vigilancia del sistema de ficheros de Gradle: sobre FUSE ambas
  fallan con errores del tipo *"Failed to create MD5 hash"* o *"input file was
  expected to be present"* sobre ficheros que sí existen.

### Instalar en el móvil

```bash
./setup.sh build      # deja los APK en dist/
./setup.sh install    # o: adb install -r dist/manticora-<fecha>-universal.apk
```

Se generan tres:

| Fichero | Tamaño | Cuándo usarlo |
|---|---|---|
| `…-arm64.apk` | 37 MB | Cualquier móvil de los últimos años. **El habitual.** |
| `…-arm32.apk` | 32 MB | Móviles antiguos o muy básicos (32 bits) |
| `…-universal.apk` | 101 MB | Si no sabes cuál toca: funciona en todos |

`dist/` está fuera del repositorio: los APK se regeneran cuando hagan falta.

### Ejecutar en el escritorio

`./setup.sh run linux` levanta la app en Linux. Ahí **no hay cámara ni OCR** (son
plugins de móvil): la app lo tiene en cuenta —el botón principal pasa a ser
*Importar*, y la pantalla de escaneo ofrece traer imágenes del disco—, así que el
resto del flujo —recorte, filtros, PDF, Word, audio y vídeo— funciona igual. La
base de datos usa el motor FFI de SQLite, que se activa solo en escritorio.

Dos detalles propios del escritorio:

- **Compartir**: Linux no tiene panel de compartir con adjuntos, así que un
  fichero se guarda con el selector del sistema y varios se empaquetan antes en
  un ZIP. En Android sale el panel de siempre, con WhatsApp incluido.
- **Audio y vídeo**: en el móvil se usan el motor de voz del teléfono y FFmpegKit;
  en Linux hacen falta `ffmpeg` y `espeak-ng` instalados en el sistema
  (`sudo pacman -S ffmpeg espeak-ng`). Si faltan, la app lo dice con ese mismo
  mensaje en vez de fallar sin explicación.

### Estado verificado

```
flutter analyze   ->  No issues found
flutter test      ->  267 pruebas, todas pasan
flutter doctor    ->  No issues found
APK release       ->  arm64 37 MB · arm32 32 MB · universal 101 MB
Arranque en Linux ->  sin errores en el registro
```

Entre esas pruebas hay tres conversiones **reales** de extremo a extremo (Word a
M4A y PowerPoint a MP4, con voz de `espeak-ng` y codificación de FFmpeg, luego
comprobadas con `ffprobe`). Si el equipo no tiene esas herramientas, esas tres
se saltan diciendo cuál falta.

El release va minificado con R8 (`isMinifyEnabled`, `isShrinkResources`) y
reglas propias en `android/app/proguard-rules.pro`. Está firmado con la clave de
depuración para que `--release` funcione de inmediato; **para publicar hay que
generar un keystore propio**.

---

## Qué sabe hacer

**Capturar**
- Detección del documento en vivo sobre el flujo de la cámara, a ~5 análisis por
  segundo, trabajando sobre el plano de luminancia (sin convertir a RGB).
- Disparo automático cuando el encuadre se estabiliza.
- Captura por lotes, flash, e importación desde la galería.

**Enderezar y realzar**
- Ajuste manual de las cuatro esquinas con lupa.
- Corrección de perspectiva por homografía con muestreo bilineal.
- Filtros: Original, Magic Color, Sin sombras, Grises, Blanco y negro
  (binarización de Sauvola) y Aclarar. Más brillo, contraste y saturación.
- Reedición no destructiva: siempre se reprocesa desde el original.

**Reconocer texto (OCR)**
- ML Kit sin conexión, con el modelo empaquetado en la instalación.
- Búsqueda de texto completo con FTS5 sobre títulos y texto reconocido.

**Exportar**
- **PDF** con tamaño (A4, Carta, Oficio, A5 o ajustado), tres niveles de
  calidad, marca de agua, contraseña AES-256 y **capa de texto invisible** que
  lo hace buscable y seleccionable.
- **Word (.docx)** generando OOXML real: texto, imágenes o ambos.
- Texto plano, imágenes sueltas, impresión y compartir.

**Convertir a audio o vídeo** (menú principal, o menú del documento)
- Entrada: un documento escaneado, un **PDF**, un **Word (.docx)** o unas
  **diapositivas (.pptx)**. El formato se reconoce por el contenido, no por la
  extensión.
- **Audio M4A** en AAC mono a 32 kbit/s: ligero de sobra para mandarlo por
  WhatsApp.
- **Vídeo MP4** con una imagen por página —las páginas de Word y PowerPoint se
  dibujan como láminas legibles—, narrado con voz o mudo con los segundos por
  página que elijas.
- Si al documento escaneado le falta el OCR, se reconoce antes de narrarlo y
  queda guardado. Un PDF escaneado (sin texto interno) se rasteriza y se
  reconoce igual.
- Todo ocurre en el aparato: la voz es la del sistema y la mezcla es de FFmpeg.

**Herramientas PDF** (sobre ficheros que ya tengas)
- Unir, dividir, extraer páginas, eliminar páginas, reordenar, girar.
- Comprimir de verdad (rasterizando con pdfium a los ppp que elijas).
- Proteger y desproteger con contraseña.
- PDF a Word, PDF a imágenes, imágenes a PDF.

**Privacidad**
- Se elimina del manifiesto el permiso de micrófono que arrastra el plugin de
  cámara: aquí solo se hacen fotos. El permiso de almacenamiento queda acotado a
  Android 12 y anteriores; desde Android 13 se usan el selector de fotos y el
  SAF, que no requieren permisos.

**Organizar**
- Carpetas, favoritos, etiquetas, papelera con restauración, selección múltiple.
- Bloqueo de la app con huella o PIN del dispositivo.

---

## Cómo está montado

```
lib/
  core/          orquestador de errores, registro, perfil de dispositivo,
                 validaciones, tema, ajustes, proveedores Riverpod
  data/          modelos, SQLite (+FTS5), repositorio y almacenamiento en disco
  imaging/       geometría, operaciones de píxel, detector, filtros, OCR,
                 isolates y trabajador persistente de detección
  export/        PDF, DOCX, herramientas PDF, guardado de ficheros
  features/      pantallas: home, scan, crop, edit, viewer, pdftools,
                 settings, lock, diagnostics
  widgets/       piezas compartidas
```

### Errores: un solo camino

Nada falla en silencio y nada revienta la pantalla.

- **`ErrorOrchestrator`** captura los cuatro sitios por los que se escapa un
  error en Flutter: el árbol de widgets (`FlutterError.onError`), el motor
  (`PlatformDispatcher.onError`), los isolates y la zona raíz. Toda la app
  corre dentro de `runZonedGuarded`.
- **`AppFailure`** traduce cualquier excepción a un mensaje en castellano que
  dice qué pasó y qué hacer: sin memoria, sin espacio, PDF protegido, permiso
  de cámara, Servicios de Play desactualizados… Conserva la causa técnica para
  el registro y marca si tiene sentido reintentar.
- **`guard` / `attempt` / `retry`** envuelven toda operación que toque disco,
  base de datos, plugins o isolates. Las lecturas devuelven vacío ante un fallo
  (la pantalla no se queda en blanco); las escrituras propagan el error, porque
  quien guarda necesita saber que no se guardó.
- Los procesos por lotes (guardar un escaneo, OCR, exportar) **aíslan cada
  página**: si una falla, las demás se completan y al final se dice cuáles
  quedaron fuera.
- El registro (`Log`) guarda los últimos 400 eventos en memoria y los vuelca a
  un fichero rotativo de 256 KB. **Ajustes → Registro de la aplicación** lo
  muestra en pantalla, con filtro por nivel, y permite copiarlo o compartirlo.
  Ahí mismo están la revisión de integridad y el compactado de la base.

### Que funcione en un móvil de gama baja

`DeviceProfile` lee la RAM de `/proc/meminfo` y los núcleos al arrancar, y de
ahí salen todos los parámetros pesados. No es un adorno: cambia lo que de
verdad consume memoria.

| | Gama baja | Gama media | Gama alta |
|---|---|---|---|
| Lado de trabajo | 1600 px | 2100 px | 2600 px |
| Techo al decodificar | 8 MP | 16 MP | 32 MP |
| Detección en vivo | cada 450 ms · 288 px | 280 ms · 384 px | 180 ms · 448 px |
| Caché de imágenes | 24 MB | 56 MB | 100 MB |
| Páginas por exportación | 60 | 150 | 400 |
| Captura | 1080p | máxima | máxima |

Además:

- Las capturas **no se acumulan en RAM**: cada foto va a un fichero temporal en
  cuanto llega. Veinte fotos de 12 MP en memoria cierran cualquier móvil
  modesto.
- Las vistas previas del editor se generan **de una en una** con una cola, no
  todas a la vez.
- Una imagen enorme se reduce con el **decodificador nativo** antes de tocarla,
  que sabe escalar sin materializar la imagen completa.
- La detección en vivo usa **un isolate persistente** que descarta fotogramas
  si está ocupado, en lugar de crear uno por fotograma.
- Se responde a `didHaveMemoryPressure` vaciando la caché de imágenes antes de
  que sea el sistema quien cierre la app.
- Las miniaturas se decodifican al tamaño en que se muestran (`cacheWidth`), no
  al original.

### Otras defensas

- Escrituras **atómicas** (a temporal y luego renombrar): un corte de corriente
  no deja imágenes a medias.
- Si guardar una página falla, se **borran las imágenes ya escritas** para no
  dejar basura ocupando espacio.
- Base de datos **corrupta**: se aparta a `manticora.db.corrupta` y se arranca
  de cero en lugar de dejar la app inservible para siempre.
- Los campos JSON guardados (recorte, ajustes) se leen de forma **tolerante**:
  un valor dañado no impide abrir el documento entero.
- Se comprueba el **espacio libre** antes de exportar y se validan los ficheros
  por su firma real, no por la extensión.
- Rutas relativas verificadas: nada puede escribir fuera de la carpeta de la app.

Decisiones que conviene conocer:

- **Todo el trabajo pesado va en isolates** (`ImagePipeline`), así que la
  interfaz nunca pierde fotogramas. La detección corre sobre una reducción a
  384 px; el recorte final sobre la imagen completa.
- **Nada de OpenCV.** El detector es Dart puro: Sobel → Otsu → dilatación →
  componentes conexas → contorno de Moore → Douglas-Peucker hasta cuatro
  vértices, con el cuadrilátero de área máxima en la envolvente convexa como
  respaldo. Sin dependencias nativas que compilar ni 30 MB extra de `.so`.
- **Los mapas caros se calculan a baja resolución y se interpolan.** El mapa de
  iluminación se estima a 96 px y los umbrales de Sauvola a un cuarto de
  resolución: varían suavemente, así que no se pierde calidad y se evita
  construir imágenes integrales de cientos de MB en un móvil.
- **En la base de datos solo hay rutas relativas.** La carpeta de la app puede
  cambiar entre versiones del sistema, así que se resuelve en tiempo de ejecución.
- **FTS5 con degradación elegante:** si el dispositivo trae SQLite sin FTS5, la
  búsqueda cae automáticamente a `LIKE`.

---

## Pruebas

```bash
flutter test        # o: ./setup.sh test
```

110 pruebas sobre lo que se puede romper en silencio:

- **Visión**: homografías, envolvente convexa, Douglas-Peucker, el detector
  sobre documentos sintéticos (de frente y en perspectiva), filtros y
  corrección de perspectiva.
- **Formatos**: empaquetado OOXML del `.docx` (partes obligatorias, escapado
  XML, imágenes incrustadas, saltos de página, ajuste al ancho útil).
- **Errores**: que cada tipo de excepción se clasifique en el fallo correcto y
  con el mensaje adecuado.
- **Validaciones**: títulos, contraseñas, nombres de fichero, firmas de PDF e
  imagen, límites de páginas, rangos tipo `1-3,5`.
- **Robustez**: modelos con datos corruptos en la base, el registro y sus
  límites, y los parámetros por gama de dispositivo.
- **Interfaz**: el ciclo de vida del diálogo de progreso, incluido el caso en
  que la tarea termina antes de que llegue a pintarse.

Dos de esas pruebas encontraron fallos reales durante el desarrollo: un
desbordamiento en el mapa de iluminación con imágenes pequeñas, y un uso de un
`ValueNotifier` ya liberado que cerraba la app cuando una tarea terminaba
demasiado rápido.

---

## Licencias de terceros

`syncfusion_flutter_pdf` (unir, dividir, cifrar y comprimir PDF) se distribuye
bajo la **licencia comunitaria de Syncfusion**: gratuita para particulares y
para empresas con menos de 1 M USD de ingresos y menos de 5 desarrolladores.
Si el proyecto crece por encima de eso, hay que sacar licencia o sustituir esa
dependencia. El resto del árbol es MIT/BSD/Apache.
