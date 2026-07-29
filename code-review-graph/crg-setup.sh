#!/bin/bash
# Переносимый one-shot сетап code-review-graph (CRG) для монорепо klone-mobile.
#
# Делает всё, что нужно на новой машине:
#   1) собирает + регистрирует 6 подграфов монорепо (через crg-update.sh);
#   2) вешает симлинк <project>/.code-review-graph -> полный граф klone-mobile-server,
#      чтобы дефолтные вызовы MCP (без repo_root) били по основному модулю;
#   3) прячет симлинк в .git/info/exclude (трекаемый .gitignore не трогаем);
#   4) идемпотентно прописывает PostToolUse-хук в <project>/.claude/settings.local.json,
#      указывая на crg-hook-update.sh РЯДОМ с этим скриптом (свой путь у каждого).
#
# Запуск:
#   bash crg-setup.sh /path/to/klone-mobile
#   # либо из каталога проекта без аргумента:
#   cd /path/to/klone-mobile && bash ~/…/code-review-graph/crg-setup.sh
#
# Идемпотентно: повторный запуск безопасен (пересобирает граф, чинит симлинк/хук).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/crg-hook-update.sh"
UPDATE="$SCRIPT_DIR/crg-update.sh"

# --- предпосылки ---
command -v code-review-graph >/dev/null 2>&1 || {
  echo "❌ code-review-graph не в PATH. Установи: uv tool install code-review-graph" >&2
  exit 1
}
command -v python3 >/dev/null 2>&1 || {
  echo "❌ python3 не найден (нужен хуку для парсинга JSON)." >&2
  exit 1
}
[ -f "$HOOK" ]   || { echo "❌ не найден $HOOK" >&2; exit 1; }
[ -f "$UPDATE" ] || { echo "❌ не найден $UPDATE" >&2; exit 1; }
chmod +x "$HOOK" "$UPDATE"

# --- определяем корень проекта ---
if [ "${1:-}" != "" ]; then
  PROJECT="$(cd "$1" && git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "❌ '$1' не внутри git-репозитория." >&2; exit 1; }
else
  PROJECT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "❌ Запусти из каталога проекта или передай путь аргументом." >&2; exit 1; }
fi

SERVER_GRAPH_DIR="$PROJECT/klone-mobile-server/src/.code-review-graph"
[ -d "$PROJECT/klone-mobile-server/src" ] || {
  echo "❌ '$PROJECT' не похож на klone-mobile (нет klone-mobile-server/src)." >&2; exit 1; }

echo "== проект: $PROJECT"
echo "== скрипты: $SCRIPT_DIR"

# --- 1) сборка + регистрация подграфов ---
echo ""
echo "== 1/4: сборка и регистрация графов =="
( cd "$PROJECT" && bash "$UPDATE" )

# --- 2) симлинк дефолтного графа на klone-mobile-server ---
echo ""
echo "== 2/4: симлинк <project>/.code-review-graph -> klone-mobile-server граф =="
[ -d "$SERVER_GRAPH_DIR" ] || {
  echo "❌ Граф klone-mobile-server не собрался ($SERVER_GRAPH_DIR)." >&2; exit 1; }
LINK="$PROJECT/.code-review-graph"
if [ -L "$LINK" ]; then
  rm "$LINK"                                   # старый симлинк — пересоздаём
elif [ -e "$LINK" ]; then
  rm -rf "$LINK"                               # огрызок-директория (gitignored) — сносим
fi
( cd "$PROJECT" && ln -s "klone-mobile-server/src/.code-review-graph" ".code-review-graph" )
echo "   $LINK -> klone-mobile-server/src/.code-review-graph"

# --- 3) прячем симлинк от git ---
echo ""
echo "== 3/4: .git/info/exclude =="
GITDIR="$(cd "$PROJECT" && git rev-parse --git-dir)"
EXCL="$GITDIR/info/exclude"
mkdir -p "$(dirname "$EXCL")"; touch "$EXCL"
grep -qxF '/.code-review-graph' "$EXCL" 2>/dev/null \
  || printf '\n# CRG symlink -> full server graph (local only)\n/.code-review-graph\n' >> "$EXCL"
echo "   ok"

# --- 4) хук в settings.local.json (идемпотентный merge) ---
echo ""
echo "== 4/4: PostToolUse-хук в .claude/settings.local.json =="
mkdir -p "$PROJECT/.claude"
SETTINGS="$PROJECT/.claude/settings.local.json" HOOK_PATH="$HOOK" python3 - <<'PY'
import json, os
p = os.environ["SETTINGS"]
hook = os.environ["HOOK_PATH"]
try:
    with open(p) as f:
        cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    cfg = {}
hooks = cfg.setdefault("hooks", {})
post = hooks.setdefault("PostToolUse", [])

def cmds(entry):
    return [h.get("command", "") for h in entry.get("hooks", [])]

# уже есть наш хук? — обновим путь; иначе добавим новый matcher
found = False
for entry in post:
    for h in entry.get("hooks", []):
        if "crg-hook-update.sh" in h.get("command", ""):
            h["command"] = hook
            h.setdefault("type", "command")
            h.setdefault("timeout", 30)
            found = True
if not found:
    post.append({
        "matcher": "Edit|Write",
        "hooks": [{"type": "command", "command": hook, "timeout": 30}],
    })

with open(p, "w") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
    f.write("\n")
print("   " + ("обновлён путь хука" if found else "добавлен хук") + f": {p}")
PY

echo ""
echo "✅ Готово."
echo "   Дефолтный граф (без repo_root) = klone-mobile-server."
echo "   Другие модули — через repo_root=<путь>/… или cross_repo_search_tool."
echo "   Перезапусти сессию Claude Code, чтобы MCP подхватил граф и хук."
