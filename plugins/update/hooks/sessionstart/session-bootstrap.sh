#!/usr/bin/env bash
set -uo pipefail

# session-bootstrap.sh — Thin bash wrapper for the Python bootstrap engine.
#
# Resolves paths, ensures Python + uv, creates/updates venv via uv sync,
# then calls the bootstrap-engine console script installed in the venv.
#
# NOTE: We intentionally do NOT use set -e. With -e, any unexpected command
# failure causes silent exit with no JSON output, and Claude Code shows nothing.
# Instead, we handle errors explicitly and ensure JSON is always emitted.

# Safety net: if the script exits without producing output, emit minimal JSON
HOOK_OUTPUT_EMITTED=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Parse flags ---
FLAG_VERBOSE=""
FLAG_CONSOLE=""
ENGINE_FLAGS=()
for arg in "$@"; do
    case "$arg" in
        --verbose) FLAG_VERBOSE=1; ENGINE_FLAGS+=(--verbose) ;;
        --console) FLAG_CONSOLE=1; ENGINE_FLAGS+=(--console) ;;
    esac
done

# Derive marketplace name from plugin root path.
# Works for both dev layout (~/Dev/<marketplace>/plugins/update/)
# and cache layout (~/.claude/plugins/cache/<marketplace>/update/<version>/).
MARKETPLACE_NAME="$(basename "$(cd "$PLUGIN_ROOT/../.." && pwd)")"
BOOTSTRAP_LABEL="${MARKETPLACE_NAME}:update"
PLUGIN_DATA="${HOME}/.claude/plugins/data/${MARKETPLACE_NAME}/update"

# Set trap after BOOTSTRAP_LABEL is defined so variable expands correctly
# In console mode, no JSON safety net needed — plain text output.
if [ -z "$FLAG_CONSOLE" ]; then
    trap '[ -z "$HOOK_OUTPUT_EMITTED" ] && mkdir -p "$PLUGIN_DATA" && printf "{\"continue\": true, \"suppressOutput\": false, \"systemMessage\": \"%s: shell error\"}" "'"${BOOTSTRAP_LABEL}"'" > "$PLUGIN_DATA/bootstrap_display.pending"' EXIT
fi

# --- Capture hook input from stdin and record start time ---
if [ -n "$FLAG_CONSOLE" ]; then
    HOOK_INPUT=""
else
    HOOK_INPUT=$(cat)
fi
HOOK_START_EPOCH=$(date +%s 2>/dev/null || echo "0")

# --- Session guard: prevent double invocation in same session ---
if [ -n "$HOOK_INPUT" ]; then
    _GUARD_SID=$(echo "$HOOK_INPUT" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"' || true)
fi
if [ -n "${_GUARD_SID:-}" ]; then
    _GUARD_FILE="$PLUGIN_DATA/last_session_id"
    if [ -f "$_GUARD_FILE" ] && [ "$(cat "$_GUARD_FILE" 2>/dev/null)" = "$_GUARD_SID" ]; then
        HOOK_OUTPUT_EMITTED=1
        exit 0
    fi
    mkdir -p "$PLUGIN_DATA"
    printf '%s' "$_GUARD_SID" > "$_GUARD_FILE"
fi

# --- Emit hook JSON immediately (fire-and-forget) ---
if [ -z "$FLAG_CONSOLE" ]; then
    echo '{"continue": true, "suppressOutput": true}'
    HOOK_OUTPUT_EMITTED=1
fi

# --- Logging ---
SHELL_LOG_ENTRIES=()

log_entry() {
    local msg="$1"
    SHELL_LOG_ENTRIES+=("$msg")
    if [ -n "$FLAG_CONSOLE" ]; then
        echo "$msg"
    fi
}

flush_log() {
    if [ ${#SHELL_LOG_ENTRIES[@]} -eq 0 ]; then
        return
    fi
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "unknown-time")"
    mkdir -p "$PLUGIN_DATA"
    {
        echo "--- Shell $ts ---"
        for entry in "${SHELL_LOG_ENTRIES[@]}"; do
            echo "$entry"
        done
    } >> "$PLUGIN_DATA/bootstrap.log"
}

# --- Read log_success_shell from config ---
LOG_SUCCESS_SHELL="false"
CONFIG_FILE="$PLUGIN_DATA/config.json"
if [ -f "$CONFIG_FILE" ]; then
    val=$(grep -o '"log_success_shell"[[:space:]]*:[[:space:]]*[a-z]*' "$CONFIG_FILE" 2>/dev/null | grep -o '[a-z]*$' || echo "false")
    if [ "$val" = "true" ]; then
        LOG_SUCCESS_SHELL="true"
    fi
fi
if [ -n "$FLAG_VERBOSE" ] || [ -n "$FLAG_CONSOLE" ]; then
    LOG_SUCCESS_SHELL="true"
fi

# --- Ensure required dirs are at front of PATH ---
LOCAL_BIN="${HOME}/.local/bin"
STANDALONE_PYTHON_BIN="${HOME}/.local/share/python-standalone/python"
case ":${PATH}:" in
    *":${LOCAL_BIN}:"*) ;;
    *) export PATH="${LOCAL_BIN}:${PATH}" ;;
esac
case ":${PATH}:" in
    *":${STANDALONE_PYTHON_BIN}:"*) ;;
    *) export PATH="${STANDALONE_PYTHON_BIN}:${PATH}" ;;
esac

# --- Ensure Python is installed ---
PYTHON=""
OS="$(uname -s)"
STANDALONE_DIR="${HOME}/.local/share/python-standalone"

if [[ "$OS" == MINGW* ]] || [[ "$OS" == MSYS* ]]; then
    WANT_PYTHON="${STANDALONE_DIR}/python/python.exe"
    STANDALONE_PYTHON="${STANDALONE_DIR}/python/python.exe"
else
    WANT_PYTHON="${LOCAL_BIN}/python3"
    STANDALONE_PYTHON="${STANDALONE_DIR}/python/install/bin/python3"
fi

if [ -x "$WANT_PYTHON" ] && "$WANT_PYTHON" -c "import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)" 2>/dev/null; then
    PYTHON="$WANT_PYTHON"
    if [ "$LOG_SUCCESS_SHELL" = "true" ]; then
        log_entry "python3: ok - found at $WANT_PYTHON"
    fi
elif [[ "$OS" != MINGW* ]] && [[ "$OS" != MSYS* ]] && [ -x "$STANDALONE_PYTHON" ] && "$STANDALONE_PYTHON" -c "import sys; sys.exit(0 if sys.version_info[0] >= 3 else 1)" 2>/dev/null; then
    mkdir -p "$LOCAL_BIN"
    ln -sf "$STANDALONE_PYTHON" "$WANT_PYTHON"
    log_entry "python3: restored symlink $WANT_PYTHON -> $STANDALONE_PYTHON"
    PYTHON="$WANT_PYTHON"
fi

if [ -z "$PYTHON" ]; then
    log_entry "python3: not installed, downloading standalone"

    PY_VERSION="3.12.9"
    RELEASE_TAG="20250317"
    ARCH="$(uname -m)"

    if [[ "$OS" == "Darwin" ]]; then
        [[ "$ARCH" == "arm64" ]] && TRIPLE="aarch64-apple-darwin" || TRIPLE="x86_64-apple-darwin"
    elif [[ "$OS" == "Linux" ]]; then
        [[ "$ARCH" == "aarch64" ]] && TRIPLE="aarch64-unknown-linux-gnu" || TRIPLE="x86_64-unknown-linux-gnu"
    elif [[ "$OS" == MINGW* ]] || [[ "$OS" == MSYS* ]]; then
        TRIPLE="x86_64-pc-windows-msvc"
    else
        log_entry "python3: FAILED - unsupported platform for auto-install ($OS)"
        flush_log
        mkdir -p "$PLUGIN_DATA"
        printf '{"continue": true, "suppressOutput": false, "systemMessage": "%s -> python3 not found and platform not supported for auto-install. Install Python 3 manually."}\n' "${BOOTSTRAP_LABEL}" > "$PLUGIN_DATA/bootstrap_display.pending"
        exit 0
    fi

    ARCHIVE="cpython-${PY_VERSION}+${RELEASE_TAG}-${TRIPLE}-install_only_stripped.tar.gz"
    URL="https://github.com/indygreg/python-build-standalone/releases/download/${RELEASE_TAG}/${ARCHIVE}"

    log_entry "python3: downloading $ARCHIVE"
    mkdir -p "$STANDALONE_DIR"
    if ! curl -LsSf "$URL" | tar xz -C "$STANDALONE_DIR" 2>/dev/null; then
        log_entry "python3: FAILED - download error"
        flush_log
        mkdir -p "$PLUGIN_DATA"
        printf '{"continue": true, "suppressOutput": false, "systemMessage": "%s -> python3 auto-install failed (download error). Install Python 3 manually."}\n' "${BOOTSTRAP_LABEL}" > "$PLUGIN_DATA/bootstrap_display.pending"
        exit 0
    fi

    if [[ "$OS" == MINGW* ]] || [[ "$OS" == MSYS* ]]; then
        log_entry "python3: installed standalone at $STANDALONE_PYTHON"
        PYTHON="$STANDALONE_PYTHON"
    else
        mkdir -p "$LOCAL_BIN"
        ln -sf "$STANDALONE_PYTHON" "$WANT_PYTHON"
        log_entry "python3: installed standalone, linked to $WANT_PYTHON"
        PYTHON="$WANT_PYTHON"
    fi
fi

# --- Persist PATH entries to Windows User PATH (registry) ---
if [[ "$OS" == MINGW* ]] || [[ "$OS" == MSYS* ]]; then
    for _path_entry in "$LOCAL_BIN" "$STANDALONE_PYTHON_BIN"; do
        _win_path=$(cygpath -w "$_path_entry" 2>/dev/null || echo "$_path_entry" | sed 's|/|\\|g')
        _ps_result=$(powershell.exe -NoProfile -NonInteractive -Command "
            \$entry = '$_win_path'
            \$current = [Environment]::GetEnvironmentVariable('Path', 'User')
            if (-not \$current) { \$current = '' }
            \$parts = \$current -split ';' | Where-Object { \$_ -ne '' }
            \$norm = \$entry.TrimEnd('\\')
            \$found = \$false
            foreach (\$p in \$parts) { if (\$p.TrimEnd('\\') -ieq \$norm) { \$found = \$true; break } }
            if (-not \$found) {
                \$newPath = (\$entry + ';' + \$current).TrimEnd(';')
                [Environment]::SetEnvironmentVariable('Path', \$newPath, 'User')
                Write-Output 'added'
            } else {
                Write-Output 'already_present'
            }
        " 2>/dev/null) || true
        if [ "$_ps_result" = "added" ]; then
            log_entry "PATH: added $_win_path to Windows User PATH (registry)"
        elif [ "$LOG_SUCCESS_SHELL" = "true" ] && [ "$_ps_result" = "already_present" ]; then
            log_entry "PATH: $_win_path already in Windows User PATH"
        fi
    done
fi

# --- Ensure uv is available ---
if ! command -v uv &>/dev/null; then
    log_entry "uv: not found, installing"
    if curl -LsSf https://astral.sh/uv/install.sh | sh 2>/dev/null; then
        log_entry "uv: installed"
    else
        log_entry "uv: FAILED - install error"
        flush_log
        exit 0
    fi
fi

# --- Create/update venv via uv sync (installs bootstrap from git) ---
VENV_PATH="$PLUGIN_DATA/.venv"
UV_BIN=$(command -v uv 2>/dev/null || echo "$LOCAL_BIN/uv")

UV_PROJECT_ENVIRONMENT="$VENV_PATH" "$UV_BIN" sync --project "$PLUGIN_ROOT" 2>/dev/null
SYNC_RC=$?
if [ $SYNC_RC -ne 0 ]; then
    log_entry "uv sync: FAILED (exit $SYNC_RC)"
    flush_log
    exit 0
fi
if [ "$LOG_SUCCESS_SHELL" = "true" ]; then
    log_entry "uv sync: ok"
fi

# --- Resolve venv bin directory ---
if [[ "$OS" == MINGW* ]] || [[ "$OS" == MSYS* ]]; then
    VENV_BIN="$VENV_PATH/Scripts"
else
    VENV_BIN="$VENV_PATH/bin"
fi

# --- Flush shell log entries before handing off to engine ---
if [ -z "$FLAG_CONSOLE" ]; then
    flush_log
fi

# --- Invoke bootstrap-engine from venv ---
if [ -z "$FLAG_CONSOLE" ]; then
    "$VENV_BIN/bootstrap-engine" \
        --plugin-root "$PLUGIN_ROOT" \
        --data-dir "$PLUGIN_DATA" \
        --hook-start-epoch "$HOOK_START_EPOCH" \
        --project-dir "$PWD" \
        --background \
        "${ENGINE_FLAGS[@]}" > /dev/null 2>&1 &
else
    exec "$VENV_BIN/bootstrap-engine" \
        --plugin-root "$PLUGIN_ROOT" \
        --data-dir "$PLUGIN_DATA" \
        --hook-start-epoch "$HOOK_START_EPOCH" \
        --project-dir "$PWD" \
        "${ENGINE_FLAGS[@]}"
fi
