#!/usr/bin/env bash
# ============================================================================
#  Manticora — instalador y configurador del entorno de desarrollo
#  Uso:   ./setup.sh              -> todo (toolchain + proyecto)
#         ./setup.sh toolchain    -> solo instalar/configurar Flutter+Android
#         ./setup.sh project      -> solo dependencias del proyecto
#         ./setup.sh doctor       -> diagnostico
#         ./setup.sh build        -> compilar APK release
#         ./setup.sh run          -> ejecutar en dispositivo/emulador
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

# ============================================================== PROYECTO
phase_project() {
  step "Proyecto Flutter: dependencias"
  command -v flutter >/dev/null || export PATH="$FLUTTER_ROOT/bin:$PATH"
  cd "$PROJECT_DIR" || die "No puedo entrar a $PROJECT_DIR"

  # El codigo vive en NTFS/FUSE: los artefactos de build van a ext4 (mucho mas rapido y sin
  # problemas de bloqueo de ficheros de Gradle).
  local fstype; fstype="$(findmnt -no FSTYPE --target "$PROJECT_DIR" 2>/dev/null)"
  if [ "$fstype" = "fuseblk" ] || [ "$fstype" = "ntfs" ] || [ "$fstype" = "ntfs3" ]; then
    local cache="$HOME/.cache/manticora/build"
    mkdir -p "$cache"
    if [ ! -L "$PROJECT_DIR/build" ]; then
      rm -rf "$PROJECT_DIR/build"
      ln -s "$cache" "$PROJECT_DIR/build"
    fi
    warn "Proyecto en $fstype: 'build/' redirigido a $cache (ext4) para acelerar compilaciones"
  fi

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
phase_build()  { step "Compilando APK release"; cd "$PROJECT_DIR" && flutter build apk --release --split-per-abi \
                   && ok "APK en: $PROJECT_DIR/build/app/outputs/flutter-apk/"; }
phase_run()    { step "Ejecutando"; cd "$PROJECT_DIR" && flutter run; }
phase_emu()    { step "Arrancando emulador"; "$ANDROID_SDK/emulator/emulator" -avd \
                   "$(ls "$HOME/.android/avd" 2>/dev/null | grep -m1 '\.ini$' | sed 's/\.ini//')" \
                   -gpu host -no-snapshot-load & disown; ok "Emulador lanzado en segundo plano"; }

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
  build)     phase_build ;;
  run)       phase_run ;;
  emulator|emu) phase_emu ;;
  all)       phase_toolchain; phase_project; phase_doctor ;;
  *) die "Fase desconocida: $1 (usa: toolchain|project|doctor|build|run|emulator)" ;;
esac

printf "\n%s  Listo. Abre una terminal NUEVA (o: source ~/.zshenv) para tener flutter en el PATH.%s\n" "$C_G" "$C_0"
