#!/usr/bin/env bash
# fix-my-grokbot: give your Grok Bot its hands back.
#
# Checks (read-only) that macOS lets apps like Grok Bot control Mail, Messages,
# Calendar, Contacts, Reminders, Notes and your browser through AppleScript,
# triggers the macOS "allow control" prompts, and tells you exactly what to fix.
#
# It never sends, deletes, or changes anything, and it never prints your data:
# only counts (accounts, calendars, tabs...) and PASS/FAIL.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/txchai/fix-my-grokbot/main/fix-my-grokbot.sh | bash
#   bash fix-my-grokbot.sh [--no-open] [--help]
#
# Unofficial, community-made. Not affiliated with SpaceXAI, xAI, or Grok.
# MIT License.

set -u

VERSION="1.0.0"
OPEN_SETTINGS=1
TIMEOUT_SECS=60   # hard cap per test (leaves time to click OK on a macOS prompt)

BOT_PROMPT="On my Mac, use osascript in a Shell command on that computer to drive my apps directly: Mail, Messages, Calendar, Contacts, Reminders, Notes, and my browser (list tabs and run page JavaScript to read pages, fill fields, and click). Read-only unless I ask for a change. Never read app databases directly. Always show me a preview before sending any message or email or submitting any form. If my main Mac is offline, use my other Mac. Try this before telling me something can't be done."

usage() {
  cat <<USAGE
fix-my-grokbot ${VERSION}: give your Grok Bot its hands back.

Runs harmless, read-only AppleScript checks so macOS asks you to allow
control of Mail, Messages, Calendar, Contacts, Reminders, Notes and your
browser (Brave, Chrome, Safari), then shows a PASS/FAIL table and the fixes.

Usage:
  bash fix-my-grokbot.sh [options]
  curl -fsSL https://raw.githubusercontent.com/txchai/fix-my-grokbot/main/fix-my-grokbot.sh | bash

Options:
  --no-open   Don't offer to open System Settings panes
  -h, --help  Show this help

Safe by design: nothing is sent, deleted, or changed, and no personal data
is printed (only counts).
USAGE
}

for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN_SETTINGS=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------- pretty output ----------
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  BOLD="$(tput bold)"; DIM="$(tput dim 2>/dev/null || true)"; RESET="$(tput sgr0)"
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"; CYAN="$(tput setaf 6)"
else
  BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""
fi

STEP=0
step() { STEP=$((STEP + 1)); printf '\n%s%s== Step %d: %s ==%s\n' "$BOLD" "$BLUE" "$STEP" "$1" "$RESET"; }
info() { printf '  %s\n' "$1"; }
ok()   { printf '  %s✔%s %s\n' "$GREEN" "$RESET" "$1"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }
bad()  { printf '  %s✘%s %s\n' "$RED" "$RESET" "$1"; }

# Ask a yes/no question. Works under `curl | bash` by reading from /dev/tty.
ask() {
  local prompt="$1" ans=""
  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf '  %s%s [y/N] %s' "$CYAN" "$prompt" "$RESET" > /dev/tty
    IFS= read -r ans < /dev/tty || ans=""
  else
    return 1
  fi
  case "$ans" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
}

# ---------- preflight ----------
if [ "$(uname -s)" != "Darwin" ]; then
  echo "fix-my-grokbot only works on macOS (this is $(uname -s))." >&2
  echo "Run it in Terminal on the Mac you want Grok Bot to control." >&2
  exit 1
fi
if ! command -v osascript >/dev/null 2>&1; then
  echo "osascript not found. This script needs macOS's built-in AppleScript." >&2
  exit 1
fi

printf '%s%sfix-my-grokbot%s %s\n' "$BOLD" "$CYAN" "$RESET" "$VERSION"
printf '%sYour Grok Bot didn'"'"'t get dumber. It lost its hands. Let'"'"'s give them back.%s\n' "$DIM" "$RESET"
info "Read-only checks. Nothing is sent, deleted, or changed. Only counts are shown."
info "macOS may pop up \"… wants to control …\" boxes. Click ${BOLD}OK${RESET} on each."
info "Note: these prompts are for Terminal. Grok Bot gets its own prompts the first"
info "time it uses each app; click OK on those too (or flip it on in Settings later)."

# ---------- helpers ----------
# Run osascript with a hard wall-clock cap (macOS has no `timeout`).
# Prints combined output; returns osascript's exit code, or 124 on timeout.
run_osa() {
  local script="$1" out pid waited=0 rc
  out="$(mktemp -t fixmygrokbot.XXXXXX)"
  osascript -e "$script" >"$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$TIMEOUT_SECS" ]; then
      kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null
      wait "$pid" 2>/dev/null
      rm -f "$out"
      echo "timed out after ${TIMEOUT_SECS}s"
      return 124
    fi
    sleep 1; waited=$((waited + 1))
  done
  wait "$pid"; rc=$?
  tr '\n' ' ' < "$out" | sed 's/[[:space:]]*$//'
  rm -f "$out"
  return "$rc"
}

app_installed() { osascript -e "id of application \"$1\"" >/dev/null 2>&1; }
app_running()   { [ "$(osascript -e "application \"$1\" is running" 2>/dev/null)" = "true" ]; }

# Results table (parallel arrays; macOS ships bash 3.2, no associative arrays)
R_NAME=(); R_STATUS=(); R_DETAIL=()
NEED_AUTOMATION=0; NEED_JS_CHROMIUM=""; NEED_JS_SAFARI=0
record() {
  R_NAME+=("$1"); R_STATUS+=("$2"); R_DETAIL+=("$3")
  case "$3" in *"Automation permission"*) NEED_AUTOMATION=1 ;; esac
}

# Classify an osascript failure into a short human reason.
classify() {
  local out="$1" rc="$2"
  if [ "$rc" -eq 124 ]; then echo "timed out (prompt left open? app busy?)"; return; fi
  case "$out" in
    *-1743*|*"Not authorized"*|*"not allowed"*) echo "blocked: Automation permission is off" ;;
    *-1712*) echo "timed out waiting for the app" ;;
    *-600*|*"isn't running"*) echo "app not running / couldn't start" ;;
    *-1728*|*"Can't get"*) echo "app has nothing to read yet" ;;
    *) echo "error: $(printf '%s' "$out" | cut -c1-80)" ;;
  esac
}

# test_app LABEL APP APPLESCRIPT_BODY  (body must return a number)
test_app() {
  local label="$1" app="$2" body="$3" out rc
  if ! app_installed "$app"; then
    record "$label" "SKIP" "not installed"; warn "$label: not installed, skipped"; return
  fi
  printf '  … %s (may open the app / show a prompt)\n' "$label"
  out="$(run_osa "with timeout of 20 seconds
tell application \"$app\"
$body
end tell
end timeout")"; rc=$?
  if [ "$rc" -eq 0 ]; then
    record "$label" "PASS" "$out"; ok "$label: $out"
  else
    local why; why="$(classify "$out" "$rc")"
    record "$label" "FAIL" "$why"; bad "$label: $why"
  fi
}

# Browser tests: tab count + page JavaScript. Never launches the browser.
test_browser() {
  local app="$1" kind="$2" out rc why
  if ! app_installed "$app"; then
    record "$app tabs" "SKIP" "not installed"; return
  fi
  if ! app_running "$app"; then
    record "$app tabs" "SKIP" "not running (open it and re-run)"
    record "$app page JS" "SKIP" "not running"
    warn "$app: installed but not running. Open it with a normal web page and re-run."
    return
  fi

  out="$(run_osa "with timeout of 20 seconds
tell application \"$app\"
set n to 0
repeat with w in windows
set n to n + (count of tabs of w)
end repeat
return (n as text) & \" tab(s) in \" & ((count of windows) as text) & \" window(s)\"
end tell
end timeout")"; rc=$?
  if [ "$rc" -eq 0 ]; then
    record "$app tabs" "PASS" "$out"; ok "$app tabs: $out"
  else
    why="$(classify "$out" "$rc")"; record "$app tabs" "FAIL" "$why"; bad "$app tabs: $why"
    record "$app page JS" "SKIP" "fix tabs access first"; return
  fi

  local js
  if [ "$kind" = "safari" ]; then
    js="with timeout of 20 seconds
tell application \"$app\"
if (count of documents) = 0 then return \"NOWINDOW\"
set t to do JavaScript \"document.title\" in front document
end tell
end timeout
return \"ok\""
  else
    js="with timeout of 20 seconds
tell application \"$app\"
if (count of windows) = 0 then return \"NOWINDOW\"
set t to execute active tab of front window javascript \"document.title\"
end tell
end timeout
return \"ok\""
  fi
  out="$(run_osa "$js")"; rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "NOWINDOW" ]; then
    record "$app page JS" "SKIP" "no open window"; warn "$app page JS: no window open, skipped"
  elif [ "$rc" -eq 0 ]; then
    record "$app page JS" "PASS" "page scripting works"; ok "$app page JS: works"
  else
    case "$out" in
      *JavaScript*|*"Apple Events"*|*"Apple events"*)
        why="'Allow JavaScript from Apple Events' is off"
        if [ "$kind" = "safari" ]; then NEED_JS_SAFARI=1; else NEED_JS_CHROMIUM="${NEED_JS_CHROMIUM}${NEED_JS_CHROMIUM:+, }$app"; fi ;;
      *) why="$(classify "$out" "$rc")" ;;
    esac
    record "$app page JS" "FAIL" "$why"; bad "$app page JS: $why"
  fi
}

# ---------- Step 1: apps ----------
step "Mac apps (Mail, Messages, Calendar, Contacts, Reminders, Notes)"
test_app "Mail"      "Mail"      'return ((count of every account) as text) & " account(s)"'
test_app "Messages"  "Messages"  'try
return ((count of every account) as text) & " account(s)"
on error
return ((count of every service) as text) & " service(s)"
end try'
test_app "Calendar"  "Calendar"  'return ((count of every calendar) as text) & " calendar(s)"'
test_app "Contacts"  "Contacts"  'return ((count of every person) as text) & " contact(s)"'
test_app "Reminders" "Reminders" 'return ((count of every list) as text) & " list(s)"'
test_app "Notes"     "Notes"     'return ((count of every note) as text) & " note(s)"'

# ---------- Step 2: browsers ----------
step "Browsers (tabs + page JavaScript)"
info "Browsers are only tested if they're already open. Nothing new is launched."
test_browser "Brave Browser" chromium
test_browser "Google Chrome" chromium
test_browser "Safari"        safari

# ---------- Step 3: results ----------
step "Results"
PASS=0; FAIL=0; SKIP=0
printf '  %s%-22s %-6s %s%s\n' "$BOLD" "CHECK" "RESULT" "DETAIL" "$RESET"
i=0
while [ "$i" -lt "${#R_NAME[@]}" ]; do
  s="${R_STATUS[$i]}"
  case "$s" in
    PASS) c="$GREEN"; PASS=$((PASS + 1)) ;;
    FAIL) c="$RED";   FAIL=$((FAIL + 1)) ;;
    *)    c="$YELLOW"; SKIP=$((SKIP + 1)) ;;
  esac
  printf '  %-22s %s%-6s%s %s\n' "${R_NAME[$i]}" "$c" "$s" "$RESET" "${R_DETAIL[$i]}"
  i=$((i + 1))
done
printf '\n  %s%d passed%s, %s%d failed%s, %s%d skipped%s\n' \
  "$GREEN" "$PASS" "$RESET" "$RED" "$FAIL" "$RESET" "$YELLOW" "$SKIP" "$RESET"

# ---------- Step 4: fixes ----------
step "Fixes"
if [ "$FAIL" -eq 0 ]; then ok "Nothing failed on this Mac."; fi
if [ "$NEED_AUTOMATION" -eq 1 ]; then
  bad "Automation is off for at least one app."
  info "System Settings > Privacy & Security > Automation: under Terminal AND Grok Bot.app,"
  info "turn on Mail, Messages, Calendar, Contacts, Reminders, Notes, and your browser."
fi
if [ -n "$NEED_JS_CHROMIUM" ]; then
  bad "Page scripting is off in: $NEED_JS_CHROMIUM"
  info "In that browser's menu bar: View > Developer > Allow JavaScript from Apple Events"
  info "(make sure it has a check mark), then re-run this script."
fi
if [ "$NEED_JS_SAFARI" -eq 1 ]; then
  bad "Page scripting is off in Safari."
  info "Safari > Settings > Advanced > turn on 'Show features for web developers',"
  info "then in the menu bar: Develop > Allow JavaScript from Apple Events."
fi
info "Grok Bot app: Settings (Cmd+,) > Computer > 'Execution on this computer' = Always allow."
info "Do the same for each Mac under 'Manage devices'. Keep Auto-Review on in Settings > Permissions."

# ---------- Step 5: open settings ----------
if [ "$OPEN_SETTINGS" -eq 1 ]; then
  step "Open System Settings (optional)"
  if ask "Open Privacy & Security > Automation?"; then
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
  fi
  if ask "Open Screen Recording (lets the bot take screenshots)?"; then
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
  fi
  if ask "Open Accessibility (lets the bot press keys / open menus)?"; then
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
  fi
fi

# ---------- Step 6: bot prompt ----------
step "Tell your bot how to work"
info "Paste this into your Grok Bot chat:"
printf '\n%s%s%s\n\n' "$BOLD" "$BOT_PROMPT" "$RESET"
if command -v pbcopy >/dev/null 2>&1 && printf '%s' "$BOT_PROMPT" | pbcopy 2>/dev/null; then
  ok "Copied to your clipboard. Just press Cmd+V in the Grok Bot chat."
fi
info "Keep this Mac awake during long tasks:  caffeinate -d"
printf '\n%sDone. Your bot has its hands back.%s\n' "$BOLD$GREEN" "$RESET"
exit 0
