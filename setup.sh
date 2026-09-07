#!/usr/bin/env bash
# ============================================================================
#  Manticora — instalador y configurador del entorno de desarrollo
#  Uso:   ./setup.sh              -> todo (toolchain + proyecto)
#         ./setup.sh toolchain    -> solo instalar/configurar Flutter+Android
#         ./setup.sh project      -> solo dependencias del proyecto
#         ./setup.sh doctor       -> diagnostico
#         ./setup.sh clean        -> limpia y restaura el proyecto
#         ./setup.sh test         -> ejecuta las pruebas
#         ./setup.sh corpus       -> descarga los documentos de prueba
#         ./setup.sh ocr          -> instala Tesseract en $HOME (OCR de escritorio)
#         ./setup.sh build        -> compilar los APK (quedan en dist/)
#         ./setup.sh run          -> ejecutar en el movil o emulador Android
#         ./setup.sh run linux    -> ejecutar en el escritorio (sin camara)
#         ./setup.sh install      -> instalar el APK en el dispositivo
#         ./setup.sh emulator     -> arrancar el emulador Android
#  NO NECESITA ROOT. Todo se instala en $HOME.
# ============================================================================
set -uo pipefail

FLUTTER_VERSION="3.47.2"
FLUTTER_ARCHIVE="flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${FLUTTER_ARCHIVE}"
FLUTTER_SHA256="447878859d01ca9bfdb99a85f245af07ed8a15fedcd9d189c4749e8e92d1f185"

INSTALL_ROOT="$HOME/Develoment"
FLUTTER_ROOT="$INSTALL_ROOT/flutter"
ANDROID_SDK="$HOME/Android/Sdk"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$PROJECT_DIR/.setup-logs"
mkdir -p "$LOG_DIR"

C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_B=$'\033[1;36m'; C_0=$'\033[0m'
ok()   { printf "%s  ✔ %s%s\n" "$C_G" "$*" "$C_0"; }
info() { printf "%s  → %s%s\n" "$C_B" "$*" "$C_0"; }
warn() { printf "%s  ! %s%s\n" "$C_Y" "$*" "$C_0"; }
err()  { printf "%s  ✘ %s%s\n" "$C_R" "$*" "$C_0"; }
step() { printf "\n%s┌─ %s%s\n" "$C_B" "$*" "$C_0"; }
die()  { err "$*"; exit 1; }

# ---------------------------------------------------------------- JDK
detect_java() {
  for cand in /usr/lib/jvm/java-21-openjdk /usr/lib/jvm/java-17-openjdk \
              /usr/lib/jvm/default /usr/lib/jvm/java-26-openjdk; do
    [ -x "$cand/bin/javac" ] && { echo "$cand"; return; }
  done
  command -v javac >/dev/null && dirname "$(dirname "$(readlink -f "$(command -v javac)")")"
}
JAVA_HOME_DETECTED="$(detect_java)"

export FLUTTER_ROOT ANDROID_SDK
export ANDROID_HOME="$ANDROID_SDK"
export ANDROID_SDK_ROOT="$ANDROID_SDK"
export JAVA_HOME="$JAVA_HOME_DETECTED"
export PATH="$FLUTTER_ROOT/bin:$ANDROID_SDK/platform-tools:$ANDROID_SDK/cmdline-tools/latest/bin:$ANDROID_SDK/emulator:$JAVA_HOME/bin:$PATH"
export PUB_CACHE="${PUB_CACHE:-$HOME/.pub-cache}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"

# ============================================================ TOOLCHAIN
phase_toolchain() {
  step "1/5  Comprobando requisitos base"
  for b in curl tar git unzip; do command -v "$b" >/dev/null || die "Falta '$b'. Instala con: sudo pacman -S $b"; done
  ok "Herramientas base presentes"
  [ -n "$JAVA_HOME_DETECTED" ] || die "No se encontro un JDK. sudo pacman -S jdk21-openjdk"
  ok "JDK: $JAVA_HOME_DETECTED ($("$JAVA_HOME_DETECTED/bin/java" -version 2>&1 | head -1))"

  step "2/5  Android SDK"
  if [ -d "$ANDROID_SDK/platform-tools" ]; then
    ok "Android SDK detectado en $ANDROID_SDK"
    info "Plataformas: $(ls "$ANDROID_SDK/platforms" 2>/dev/null | tr '\n' ' ')"
    info "Build-tools : $(ls "$ANDROID_SDK/build-tools" 2>/dev/null | tr '\n' ' ')"
  else
    warn "No hay Android SDK en $ANDROID_SDK"
    info "Instalalo desde Android Studio (SDK Manager) y vuelve a ejecutar."
  fi

  step "3/5  Flutter $FLUTTER_VERSION"
  if [ -x "$FLUTTER_ROOT/bin/flutter" ]; then
    local cur; cur="$("$FLUTTER_ROOT/bin/flutter" --version 2>/dev/null | head -1 | awk '{print $2}')"
    ok "Flutter ya instalado (${cur:-desconocido}) en $FLUTTER_ROOT"
  else
    mkdir -p "$INSTALL_ROOT"
    local tmp="$INSTALL_ROOT/.dl"; mkdir -p "$tmp"
    # Evita que dos ejecuciones simultaneas corrompan el mismo archivo.
    exec 9>"$tmp/.lock"
    if ! flock -n 9; then
      die "Ya hay otra instalacion en curso (lock: $tmp/.lock). Espera a que termine."
    fi
    local tarball="$tmp/$FLUTTER_ARCHIVE"
    if [ ! -f "$tarball" ] || ! echo "$FLUTTER_SHA256  $tarball" | sha256sum -c - >/dev/null 2>&1; then
      info "Descargando Flutter (~1.2 GB, puede tardar varios minutos)..."
      curl -fL --retry 3 --retry-delay 5 -C - -o "$tarball" "$FLUTTER_URL" \
        || die "Fallo la descarga de Flutter"
      echo "$FLUTTER_SHA256  $tarball" | sha256sum -c - >/dev/null 2>&1 \
        || die "Checksum SHA256 incorrecto. Borra $tarball y reintenta."
    fi
    ok "Archivo verificado (SHA256)"
    info "Extrayendo en $INSTALL_ROOT ..."
    tar -xf "$tarball" -C "$INSTALL_ROOT" || die "Fallo al extraer"
    rm -rf "$tmp"
    [ -x "$FLUTTER_ROOT/bin/flutter" ] || die "Extraccion incompleta"
    ok "Flutter instalado en $FLUTTER_ROOT"
  fi

  git config --global --add safe.directory "$FLUTTER_ROOT" 2>/dev/null

  step "4/5  Variables de entorno persistentes"
  write_env_block "$HOME/.zshenv"
  write_env_block "$HOME/.bashrc"
  ok "Entorno escrito en ~/.zshenv y ~/.bashrc (bloque MANTICORA, idempotente)"

  step "5/5  Configuracion de Flutter"
  info "Desactivando telemetria y habilitando plataformas..."
  "$FLUTTER_ROOT/bin/flutter" config --no-analytics >/dev/null 2>&1
  "$FLUTTER_ROOT/bin/dart" --disable-analytics >/dev/null 2>&1
  "$FLUTTER_ROOT/bin/flutter" config --enable-android --no-enable-ios \
      --no-enable-web --enable-linux-desktop >/dev/null 2>&1
  ok "Flutter configurado (Android + Linux desktop)"

  info "Descargando artefactos de compilacion (precache android)..."
  "$FLUTTER_ROOT/bin/flutter" precache --android --linux >"$LOG_DIR/precache.log" 2>&1 \
      && ok "Artefactos listos" || warn "precache con avisos (ver $LOG_DIR/precache.log)"

  if [ -d "$ANDROID_SDK/cmdline-tools/latest/bin" ]; then
    info "Aceptando licencias del SDK de Android..."
    yes 2>/dev/null | "$ANDROID_SDK/cmdline-tools/latest/bin/sdkmanager" --licenses >/dev/null 2>&1
    yes 2>/dev/null | "$FLUTTER_ROOT/bin/flutter" doctor --android-licenses >/dev/null 2>&1
    ok "Licencias aceptadas"
  fi
}

write_env_block() {
  local f="$1" marker="# >>> MANTICORA dev env >>>" endm="# <<< MANTICORA dev env <<<"
  touch "$f"
  if grep -qF "$marker" "$f" 2>/dev/null; then
    python3 - "$f" "$marker" "$endm" <<'PY'
import sys,re
f,m,e=sys.argv[1],sys.argv[2],sys.argv[3]
s=open(f).read()
s=re.sub(re.escape(m)+r".*?"+re.escape(e)+r"\n?","",s,flags=re.S)
open(f,"w").write(s)
PY
  fi
  cat >>"$f" <<ENVB
$marker
export FLUTTER_ROOT="$FLUTTER_ROOT"
export ANDROID_HOME="$ANDROID_SDK"
export ANDROID_SDK_ROOT="$ANDROID_SDK"
export JAVA_HOME="$JAVA_HOME_DETECTED"
export CHROME_EXECUTABLE="\${CHROME_EXECUTABLE:-\$(command -v google-chrome-stable || command -v chromium || true)}"
case ":\$PATH:" in
  *":\$FLUTTER_ROOT/bin:"*) ;;
  *) export PATH="\$FLUTTER_ROOT/bin:\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/emulator:\$PATH" ;;
esac
$endm
ENVB
}

# El codigo vive en NTFS/FUSE: los artefactos de build van a ext4, que es mucho
# mas rapido y evita los fallos de bloqueo/instantaneas de Gradle.
link_build_dir() {
  local fstype; fstype="$(findmnt -no FSTYPE --target "$PROJECT_DIR" 2>/dev/null)"
  case "$fstype" in
    fuseblk|ntfs|ntfs3|exfat|vfat) ;;
    *) return 0 ;;
  esac
  local cache="$HOME/.cache/manticora/build"
  mkdir -p "$cache"
  if [ ! -L "$PROJECT_DIR/build" ]; then
    rm -rf "$PROJECT_DIR/build"
    ln -s "$cache" "$PROJECT_DIR/build"
  fi
  warn "Proyecto en $fstype: 'build/' redirigido a $cache (ext4)"
}

# ============================================================== PROYECTO
phase_project() {
  step "Proyecto Flutter: dependencias"
  command -v flutter >/dev/null || export PATH="$FLUTTER_ROOT/bin:$PATH"
  cd "$PROJECT_DIR" || die "No puedo entrar a $PROJECT_DIR"

  link_build_dir

  if [ ! -d "$PROJECT_DIR/android" ]; then
    info "Generando andamiaje nativo (android/, linux/)..."
    flutter create --project-name manticora --org com.manticora \
      --platforms=android,linux --empty . >"$LOG_DIR/create.log" 2>&1 \
      || die "flutter create fallo (ver $LOG_DIR/create.log)"
    ok "Andamiaje generado"
  else
    ok "Andamiaje nativo ya presente"
  fi

  info "Resolviendo dependencias (flutter pub get)..."
  flutter pub get 2>&1 | tee "$LOG_DIR/pubget.log" | tail -5
  [ "${PIPESTATUS[0]}" -eq 0 ] && ok "Dependencias listas" || die "pub get fallo (ver $LOG_DIR/pubget.log)"
}

phase_doctor() { step "flutter doctor"; flutter doctor -v; }

phase_clean() {
  step "Limpiando"
  cd "$PROJECT_DIR" || return 1
  flutter clean >/dev/null 2>&1
  rm -rf "$HOME/.cache/manticora/build"
  link_build_dir
  flutter pub get >/dev/null 2>&1 && ok "Proyecto limpio y dependencias restauradas"
}

# --------------------------------------------------------------- dispositivos

first_avd() {
  ls "$HOME/.android/avd" 2>/dev/null | grep -m1 '\.ini$' | sed 's/\.ini$//'
}

android_device() {
  "$ANDROID_SDK/platform-tools/adb" devices 2>/dev/null \
    | awk '$2 == "device" { print $1; exit }'
}

# Arranca el emulador y espera a que el sistema termine de iniciarse.
boot_emulator() {
  local avd; avd="$(first_avd)"
  [ -n "$avd" ] || { err "No hay ningun emulador creado. Crealo desde Android Studio."; return 1; }

  info "Arrancando el emulador '$avd'..."
  nohup "$ANDROID_SDK/emulator/emulator" -avd "$avd" -gpu host -no-snapshot-save \
        >"$LOG_DIR/emulator.log" 2>&1 &
  disown 2>/dev/null

  info "Esperando a que arranque (puede tardar un minuto)..."
  local adb="$ANDROID_SDK/platform-tools/adb"
  "$adb" wait-for-device >/dev/null 2>&1
  local i=0
  while [ "$i" -lt 90 ]; do
    if [ "$("$adb" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then
      ok "Emulador listo"
      return 0
    fi
    sleep 2
    i=$((i + 1))
  done
  err "El emulador no termino de arrancar (ver $LOG_DIR/emulator.log)"
  return 1
}

phase_emu() {
  step "Emulador Android"
  if [ -n "$(android_device)" ]; then
    ok "Ya hay un dispositivo conectado: $(android_device)"
    return 0
  fi
  boot_emulator
}

phase_run() {
  step "Ejecutando Manticora"
  cd "$PROJECT_DIR" || return 1

  # 'run linux' fuerza el escritorio; util para iterar rapido en la interfaz.
  if [ "${2:-}" = "linux" ] || [ "${RUN_TARGET:-}" = "linux" ]; then
    warn "Ejecutando en Linux: no hay camara ni OCR (son plugins de movil)"
    info "Se puede importar desde la galeria para probar el resto del flujo"
    flutter run -d linux
    return $?
  fi

  local device; device="$(android_device)"
  if [ -z "$device" ]; then
    warn "No hay ningun movil ni emulador Android conectado"
    if [ -n "$(first_avd)" ]; then
      boot_emulator || return 1
      device="$(android_device)"
    else
      err "Conecta un movil con depuracion USB activada, o crea un emulador"
      info "Para probar solo la interfaz en el escritorio: ./setup.sh run linux"
      return 1
    fi
  fi

  ok "Dispositivo: $device"
  flutter run -d "$device"
}

phase_build() {
  step "Compilando APK de release"
  cd "$PROJECT_DIR" || return 1

  local dist="$PROJECT_DIR/dist"
  mkdir -p "$dist"

  info "APK por arquitectura (mas pequenos, para publicar)..."
  flutter build apk --release --split-per-abi || return 1

  info "APK universal (uno solo, instalable en cualquier movil)..."
  flutter build apk --release || return 1

  local out="$PROJECT_DIR/build/app/outputs/flutter-apk"
  local stamp; stamp="$(date +%Y%m%d)"
  cp -f "$out/app-release.apk"            "$dist/manticora-$stamp-universal.apk" 2>/dev/null
  cp -f "$out/app-arm64-v8a-release.apk"  "$dist/manticora-$stamp-arm64.apk"     2>/dev/null
  cp -f "$out/app-armeabi-v7a-release.apk" "$dist/manticora-$stamp-arm32.apk"    2>/dev/null

  ok "APK listos en $dist"
  ls -lh "$dist"/*.apk 2>/dev/null | awk '{printf "     %s  %s\n", $5, $9}'
  printf "\n%s  Para instalarlo por cable: adb install -r dist/manticora-%s-universal.apk%s\n" \
    "$C_B" "$stamp" "$C_0"
}

# Documentos reales de dominio publico usados por las pruebas de calidad.
# No se versionan: pesan y se pueden volver a bajar cuando haga falta.
phase_corpus() {
  step "Descargando documentos de prueba"
  local dir="$PROJECT_DIR/test/corpus"
  mkdir -p "$dir"

  local base="https://upload.wikimedia.org/wikipedia/commons/thumb"
  fetch() { # destino  url
    if [ -s "$dir/$1" ]; then ok "$1 (ya estaba)"; return 0; fi
    if curl -sL --max-time 90 -o "$dir/$1" "$2" && [ -s "$dir/$1" ]; then
      ok "$1 ($(du -h "$dir/$1" | cut -f1))"
    else
      warn "No se pudo descargar $1"
      rm -f "$dir/$1"
    fi
  }

  fetch factura-sichuan.jpg \
    "$base/1/12/Common_Printed_Invoice_from_Sichuan.jpg/1280px-Common_Printed_Invoice_from_Sichuan.jpg"
  fetch factura-1849.jpg \
    "$base/b/bb/Document%2C_Invoice%2C_Charles_A._Baudo%2C_before_1849_%28CH_18634673%29.jpg/1280px-Document%2C_Invoice%2C_Charles_A._Baudo%2C_before_1849_%28CH_18634673%29.jpg"
  fetch tabla-sharon-1854.jpg \
    "$base/6/60/Invoice_and_valuations_of_the_rateable_polls_and_estates_within_the_town_of_Sharon%2C_May_1%2C_1854_%28IA_invoicevaluation00shar%29.pdf/page1-1280px-Invoice_and_valuations_of_the_rateable_polls_and_estates_within_the_town_of_Sharon%2C_May_1%2C_1854_%28IA_invoicevaluation00shar%29.pdf.jpg"
  fetch instrucciones.jpg \
    "$base/e/e1/Black_Lunch_Table_DIY_Photo_Booth_Instructions_%28FINAL%29.pdf/page1-960px-Black_Lunch_Table_DIY_Photo_Booth_Instructions_%28FINAL%29.pdf.jpg"

  info "Las pruebas que los usan se saltan solas si faltan."
}

# Motor de OCR para el escritorio. ML Kit solo existe en el movil, asi que en
# Linux se usa Tesseract; se instala en $HOME (sin root) igual que Flutter.
phase_ocr() {
  step "Instalando el motor de texto del escritorio (Tesseract)"

  if command -v tesseract >/dev/null 2>&1; then
    ok "Tesseract del sistema: $(tesseract --version 2>&1 | head -1)"
    return 0
  fi

  local prefix="$HOME/.local/manticora-ocr"
  if [ -x "$prefix/usr/bin/tesseract" ]; then
    ok "Ya estaba instalado en $prefix"
  else
    command -v curl >/dev/null 2>&1 || { err "Hace falta curl"; return 1; }
    command -v zstd >/dev/null 2>&1 || command -v bsdtar >/dev/null 2>&1 || \
      { err "Hace falta zstd para descomprimir los paquetes"; return 1; }

    local mirror="https://fastly.mirror.pkgbuild.com/extra/os/x86_64"
    local tmp; tmp="$(mktemp -d)"
    mkdir -p "$prefix"

    info "Buscando los paquetes en el repositorio de Arch..."
    local indice; indice="$(curl -sL --max-time 60 "$mirror/")" || {
      err "No se pudo consultar $mirror"; rm -rf "$tmp"; return 1; }

    local nombre paquete
    for paquete in "tesseract-[0-9][^\"]*x86_64" "leptonica-[0-9][^\"]*x86_64" \
                   "tesseract-data-spa-[^\"]*any" "tesseract-data-eng-[^\"]*any"; do
      nombre="$(printf '%s' "$indice" | grep -oE "${paquete}\.pkg\.tar\.zst" | sort -u | tail -1)"
      [ -n "$nombre" ] || { warn "No se encontro un paquete ($paquete)"; continue; }
      info "Descargando $nombre"
      curl -sL --max-time 300 -o "$tmp/paquete.zst" "$mirror/$nombre" || {
        warn "Fallo la descarga de $nombre"; continue; }
      tar -I zstd -xf "$tmp/paquete.zst" -C "$prefix" 2>/dev/null || \
        bsdtar -xf "$tmp/paquete.zst" -C "$prefix" || warn "No se pudo extraer $nombre"
    done
    rm -rf "$tmp"

    [ -x "$prefix/usr/bin/tesseract" ] || { err "La instalacion no dejo el binario"; return 1; }
    ok "Instalado en $prefix"
  fi

  # El bloque del entorno ya lo escribe phase_toolchain; aqui solo se avisa.
  cat <<EOF

  Anade esto a tu ~/.zshenv (o ~/.bashrc) para que la app y las pruebas lo vean:

    export PATH="$prefix/usr/bin:\$PATH"
    export LD_LIBRARY_PATH="$prefix/usr/lib:\${LD_LIBRARY_PATH:-}"
    export TESSDATA_PREFIX="$prefix/usr/share/tessdata"

  Para quitarlo: rm -rf $prefix

EOF
}

phase_install() {
  step "Instalando en el dispositivo"
  local device; device="$(android_device)"
  [ -n "$device" ] || { err "No hay ningun dispositivo conectado"; return 1; }
  local apk; apk="$(ls -t "$PROJECT_DIR"/dist/*universal*.apk 2>/dev/null | head -1)"
  [ -n "$apk" ] || { err "No hay APK. Ejecuta primero: ./setup.sh build"; return 1; }
  "$ANDROID_SDK/platform-tools/adb" -s "$device" install -r "$apk" && ok "Instalado: $(basename "$apk")"
}

banner() {
cat <<'B'
  ┌───────────────────────────────────────────────┐
  │   MANTICORA · escaner de documentos           │
  │   configuracion del entorno (sin root)        │
  └───────────────────────────────────────────────┘
B
}

banner
case "${1:-all}" in
  toolchain) phase_toolchain ;;
  project)   phase_project ;;
  doctor)    phase_doctor ;;
  clean)     phase_clean ;;
  build)     phase_build ;;
  run)       phase_run "$@" ;;
  emulator|emu) phase_emu ;;
  install)   phase_install ;;
  corpus)    phase_corpus ;;
  ocr)       phase_ocr ;;
  apk)       phase_build ;;
  all)       phase_toolchain; phase_project; phase_doctor ;;
  test)      step "Pruebas"; cd "$PROJECT_DIR" && flutter test ;;
  *) die "Fase desconocida: $1 (usa: toolchain|project|doctor|clean|test|build|run|install|corpus|ocr|emulator)" ;;
esac

printf "\n%s  Listo. Abre una terminal NUEVA (o: source ~/.zshenv) para tener flutter en el PATH.%s\n" "$C_G" "$C_0"
