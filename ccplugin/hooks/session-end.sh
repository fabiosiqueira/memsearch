#!/usr/bin/env bash
# SessionEnd hook: generate session index line + stop watch singleton.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# --- Generate session index line ---
# Summarize the entire session into a single ~120-char line for progressive disclosure.
# This runs once at session end (not per-turn), so it sees the complete session.
# The index line is used by session-start.sh to inject a compact memory index
# instead of raw tail-30 content (~10x token savings).

ensure_memory_dir
TODAY=$(date +%Y-%m-%d)
_SUFFIX="${SESSION_SUFFIX:+_${SESSION_SUFFIX}}"
MEMORY_FILE="$MEMORY_DIR/${TODAY}${_SUFFIX}.md"
# Fallback to daily file for sessions without a suffix (legacy or edge cases)
[ -f "$MEMORY_FILE" ] || MEMORY_FILE="$MEMORY_DIR/${TODAY}.md"

if [ -f "$MEMORY_FILE" ]; then
  # Find the last ## Session heading (the session that just ended)
  SESSION_TIME=$(grep -oE '^## Session [0-9]{2}:[0-9]{2}' "$MEMORY_FILE" | tail -1 | grep -oE '[0-9]{2}:[0-9]{2}')

  if [ -n "$SESSION_TIME" ] && ! grep -q "<!-- index:$SESSION_TIME" "$MEMORY_FILE"; then
    # Extract session block (from ## Session $TIME to next ## Session or EOF)
    SESSION_BLOCK=$(sed -n "/^## Session $SESSION_TIME/,/^## Session [0-9]/{
      /^## Session [0-9]/{
        /^## Session $SESSION_TIME/!d
      }
      p
    }" "$MEMORY_FILE")

    LINE_COUNT=$(echo "$SESSION_BLOCK" | wc -l | tr -d ' ')

    if [ "$LINE_COUNT" -ge 3 ] && command -v claude &>/dev/null; then
      INDEX_LINE=$(printf '%s' "$SESSION_BLOCK" | MEMSEARCH_NO_WATCH=1 CLAUDECODE= claude -p \
        --model haiku \
        --no-session-persistence \
        --no-chrome \
        --system-prompt "Resuma esta sessão de trabalho em UMA linha de no máximo 120 caracteres. Foque no que foi entregue/decidido, não no processo. Formato: <o que foi feito>. <resultado concreto se houver>. Não use prefixos como 'Sessão:' ou 'Resumo:'. Escreva no idioma do conteúdo." \
        2>/dev/null || true)

      if [ -n "$INDEX_LINE" ]; then
        # Enforce max 120 chars, single line, trim whitespace
        INDEX_LINE=$(echo "$INDEX_LINE" | head -1 | cut -c1-120 | sed 's/[[:space:]]*$//')
        # Insert after ## Session heading using python3 (safe with special chars)
        python3 -c "
import sys
time, line, path = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f: content = f.read()
marker = f'## Session {time}'
if marker in content:
    content = content.replace(marker, marker + '\n' + f'<!-- index:{time} {line} -->', 1)
    with open(path, 'w') as f: f.write(content)
" "$SESSION_TIME" "$INDEX_LINE" "$MEMORY_FILE"
      fi
    fi
  fi
fi

# --- Original cleanup ---
stop_watch

exit 0
