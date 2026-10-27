# Interactive setup (`./mel setup`) and health check (`./mel doctor`). Sourced by ./mel, which defines
# ROOT, APP, DB and the build_* / start_server / setting helpers, and creates the database first. Every step checks first, so it can run again.

SETUP_LOG="$ROOT/setup.log"
HF="uvx --quiet --from huggingface_hub hf"
TERMS_URL="https://huggingface.co/pyannote/speaker-diarization-community-1"
TOKENS_URL="https://huggingface.co/settings/tokens"

if [[ -t 1 ]]; then
  BOLD=$'\e[1m' DIM=$'\e[2m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' RESET=$'\e[0m'
else
  BOLD="" DIM="" RED="" GREEN="" YELLOW="" RESET=""
fi
STEP=0 STEPS=7

step() { STEP=$((STEP + 1)); printf "\n${BOLD}[%d/%d] %s${RESET}\n" "$STEP" "$STEPS" "$1"; }
ok() { printf "  ${GREEN}✓${RESET} %s\n" "$1"; }
warn() { printf "  ${YELLOW}!${RESET} %s\n" "$1"; }
fail() { printf "  ${RED}✗${RESET} %s\n" "$1"; }
note() { printf "  ${DIM}%s${RESET}\n" "$1"; }
die() { fail "$1"; [[ -n "${2:-}" ]] && note "$2"; exit 1; }

# ask "Question" y|n → returns 0 for yes. The default is used when you just press Enter.
ask() {
  local hint="[Y/n]"; [[ $2 == n ]] && hint="[y/N]"
  read -r -p "  $1 $hint " reply </dev/tty || true
  reply="${reply:-$2}"
  [[ $reply =~ ^[Yy] ]]
}

# run "Label" command… → runs quietly with a spinner; on failure shows the end of setup.log.
run() {
  local label="$1"; shift
  printf "%s\n\$ %s\n" "--- $label" "$*" >>"$SETUP_LOG"
  "$@" >>"$SETUP_LOG" 2>&1 &
  local pid=$! frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  while kill -0 "$pid" 2>/dev/null; do
    [[ -t 1 ]] && printf "\r  ${DIM}%s${RESET} %s" "${frames:i++%${#frames}:1}" "$label"
    sleep 0.1
  done
  [[ -t 1 ]] && printf "\r\e[K"
  if wait "$pid"; then ok "$label"; else
    fail "$label"
    tail -15 "$SETUP_LOG" | sed 's/^/    /'
    die "Setup stopped." "Full log: $SETUP_LOG. Fix the error above and run ./mel setup again; finished steps are skipped."
  fi
}


find_uv() {
  command -v uv >/dev/null && return
  [[ -x "$HOME/.local/bin/uv" ]] && export PATH="$HOME/.local/bin:$PATH"
  command -v uv >/dev/null
}
hf_logged_in() { $HF auth whoami >/dev/null 2>&1; }
speakers_ready() { [[ -d "$ROOT/models/hub/models--pyannote--speaker-diarization-community-1/snapshots" ]]; }
models_ready() {
  local whisper; whisper="$(setting model)"
  [[ -d "$ROOT/models/hub/models--${whisper//\//--}/snapshots" ]]
}

setup() {
  : >"$SETUP_LOG"
  printf "\n${BOLD}Mel${RESET} records your meetings and transcribes them on this Mac.\n"
  note "This takes about 10 minutes, most of it downloading models (~4 GB). Nothing you record leaves your Mac."

  step "Checking your Mac"
  [[ "$(uname -m)" == arm64 ]] || die "Mel needs an Apple Silicon Mac (M1 or later): it runs the models on the Apple GPU."
  local macos; macos="$(sw_vers -productVersion)"
  (( ${macos%%.*} >= 15 )) || die "Mel needs macOS 15 Sequoia or later (this Mac has $macos)." "Update in System Settings › General › Software Update."
  ok "Apple Silicon, macOS $macos"

  step "Developer tools"
  if xcode-select -p >/dev/null 2>&1 && command -v swift >/dev/null; then
    ok "Xcode Command Line Tools"
  else
    note "Mel's recorder and app are built from source with Swift, from Apple's Command Line Tools."
    xcode-select --install >/dev/null 2>&1 || true
    note "A macOS window asks to install them. Click Install and wait; this continues by itself."
    until xcode-select -p >/dev/null 2>&1 && command -v swift >/dev/null; do sleep 5; done
    ok "Xcode Command Line Tools"
  fi
  if find_uv; then
    ok "uv $(uv --version | cut -d' ' -f2)"
  else
    note "uv runs Mel's Python parts, each with its own dependencies (https://docs.astral.sh/uv/)."
    ask "Install uv now?" y || die "Mel needs uv." "Install it yourself (https://docs.astral.sh/uv/getting-started/installation/), then run ./mel setup again."
    run "Installing uv" sh -c "curl -LsSf https://astral.sh/uv/install.sh | sh"
    find_uv || die "uv was installed but isn't on your PATH." "Open a new terminal and run ./mel setup again."
  fi

  step "Languages"
  local current; current="$(setting languages)"
  note "Mel detects the language of every sentence among the ones spoken in your meetings,"
  note "so a meeting can switch between them. Use language codes: en, es, pt, fr, de, it…"
  read -r -p "  Languages in your meetings [$current]: " langs </dev/tty || true
  langs="$(tr -d ' ' <<<"${langs:-$current}" | tr 'A-Z' 'a-z')"
  [[ $langs =~ ^[a-z]{2,3}(,[a-z]{2,3})*$ ]] || { warn "\"$langs\" doesn't look like codes such as en,es; keeping $current."; langs="$current"; }
  set_setting languages "$langs"
  ok "Languages: $langs (change them later in Mel's Settings)"

  step "Building Mel"
  run "Building the recorder" build_capture
  security find-certificate -c "$IDENTITY" >/dev/null 2>&1 ||
    note "Creating a local signing certificate in your keychain so macOS remembers Mel's permissions. macOS may ask for your password."
  run "Building the app" build_app
  ok "Installed $APP"

  step "Models"
  if models_ready; then
    ok "Transcription and title models already downloaded"
  else
    note "Whisper large-v3-turbo transcribes (1.6 GB); Qwen3 4B names your meetings (2.3 GB)."
    note "They're saved in $ROOT/models and run offline from then on."
    ask "Download them now?" y || die "Mel can't transcribe without them." "Run ./mel setup again when you're ready."
    printf "\n"
    "$ROOT/mel" download || die "Download failed." "Check your connection and run ./mel setup again; downloads resume."
    ok "Models downloaded"
  fi

  step "Telling speakers apart (optional)"
  if speakers_ready; then
    ok "Speaker detection ready"
  else
    note "Without this, everyone else in a call is \"Them\". With it, Mel tells them apart (\"Speaker 1\", \"Speaker 2\"…)"
    note "and recognizes voices you've named. It uses pyannote, whose model needs a free Hugging Face account."
    if ask "Set it up now? (about 2 minutes)" y; then
      setup_speakers
    else
      warn "Skipped. Run ./mel setup again any time to add it."
    fi
  fi

  step "Done"
  start_server
  ok "Mel is installed in ~/Applications and ready."
  printf "\n  ${BOLD}First recording:${RESET} click ${BOLD}+${RESET}. macOS asks for two permissions, Microphone and\n"
  printf "  Screen & System Audio Recording (that's how Mel hears the call). Allow both, choose\n"
  printf "  ${BOLD}Quit & Reopen${RESET}, and record again.\n\n"
  note "Tip: use headphones, so the call isn't picked up by your microphone too."
  note "Problems? ./mel doctor checks everything. How it works: docs/README.md"
  printf "\n"
  ask "Open Mel now?" y && open "$APP"
  return 0
}

setup_speakers() {
  if hf_logged_in; then
    ok "Logged in to Hugging Face"
  else
    note "1. Create a free account (or log in) and make a token with the \"Read\" role:"
    note "   $TOKENS_URL"
    open "$TOKENS_URL"
    read -r -p "  Press Enter when you've copied the token… " </dev/tty || true
    note "2. Paste it below (it's stored by Hugging Face's tool in ~/.cache/huggingface, not by Mel)."
    $HF auth login </dev/tty || { warn "Login failed. Skipped; run ./mel setup again to retry."; return; }
  fi
  note "3. Accept the model's terms: open the page, fill in the short form and click Agree."
  note "   $TERMS_URL"
  open "$TERMS_URL"
  while true; do
    read -r -p "  Press Enter once you've accepted… " </dev/tty || true
    if "$ROOT/mel" download --speakers >>"$SETUP_LOG" 2>&1; then
      ok "Speaker detection ready"
      return
    fi
    fail "Hugging Face still refuses access to the model."
    ask "Try again?" y || { warn "Skipped. Run ./mel setup again any time to add it."; return; }
  done
}

doctor() {
  local problems=0
  check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else fail "$1"; note "→ $3"; problems=$((problems + 1)); fi; }
  printf "\n${BOLD}Mel doctor${RESET}\n\n"
  check "Apple Silicon" '[[ "$(uname -m)" == arm64 ]]' "Mel needs an M1 or later."
  check "macOS 15 or later ($(sw_vers -productVersion))" '(( $(sw_vers -productVersion | cut -d. -f1) >= 15 ))' "Update macOS."
  check "Xcode Command Line Tools" 'command -v swift' "Run xcode-select --install."
  check "uv" 'find_uv' "Run ./mel setup, or see https://docs.astral.sh/uv/."
  check "Recorder built" '[[ -x "$BIN" ]]' "Run ./mel setup."
  check "App installed ($APP)" '[[ -d "$APP" ]]' "Run ./mel setup."
  check "Signing certificate" 'security find-certificate -c "$IDENTITY"' "Run ./mel setup."
  check "Models downloaded" 'models_ready' "Run ./mel setup."
  if speakers_ready; then ok "Speaker detection"; else warn "Speaker detection not set up (optional): run ./mel setup."; fi
  check "Transcription server" 'curl -sf http://127.0.0.1:8765/health' "Start it with ./mel server; see ./mel logs if it doesn't come up."
  check "Database ($DB)" '[[ "$(sqlite3 "$DB" "PRAGMA user_version")" -gt 0 ]]' "Run ./mel init."
  note "$(sqlite3 "$DB" "SELECT (SELECT count(*) FROM meetings) || ' meetings, ' || (SELECT count(*) FROM people) || ' people; languages ' || (SELECT value FROM settings WHERE key = 'languages')")"
  note "Recording permissions can only be checked by recording: if Mel hears nothing, allow it in"
  note "System Settings › Privacy & Security › Microphone and › Screen & System Audio Recording, then reopen it."
  printf "\n"
  (( problems == 0 )) && ok "Everything looks good." || fail "$problems problem(s) found."
  return "$problems"
}
