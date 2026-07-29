#!/bin/bash
# Обновление code-review-graph (CRG) по 6 закреплённым путям монорепо.
# v2: используем нативный --repo вместо cd в сабшелл (подтверждено --help).
#
# Не нужен merge-graphs / кастомная разметка коммьюнити / обрезка отчёта —
# у CRG multi-repo registry + cross_repo_search_tool решают то же самое
# на уровне запроса, а не статического файла.
#
# Запуск: bash crg-update.sh
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"

command -v code-review-graph >/dev/null 2>&1 || {
  echo "code-review-graph не найден в PATH. Установи: uv tool install code-review-graph" >&2
  exit 1
}

PATHS=(
  "klone-mobile-server/src"
  "klone-desktop/src"
  "klone/src"
  "server-framework/server/src"
  "server-framework/mobile-fw-server/src"
  "server-framework/server/res"
)

echo "== 1/2: build/update графа по ${#PATHS[@]} путям =="
for p in "${PATHS[@]}"; do
  TARGET="$ROOT/$p"
  if [ ! -d "$TARGET" ]; then
    echo "пропуск: $TARGET не существует" >&2
    continue
  fi
  echo "--- $p ---"
  # build сам обновляет существующий граф инкрементально (SHA-256 diff),
  # так что отдельный update-вызов не нужен — build безопасен на повторный запуск.
  code-review-graph build --repo "$TARGET" -q
done

echo "== 2/2: регистрация в multi-repo registry (для cross_repo_search_tool) =="
EXISTING_REPOS="$(code-review-graph repos 2>/dev/null || true)"
for p in "${PATHS[@]}"; do
  TARGET="$ROOT/$p"
  [ -d "$TARGET" ] || continue
  if printf '%s' "$EXISTING_REPOS" | grep -qF "$TARGET"; then
    echo "уже зарегистрирован: $p"
  else
    code-review-graph register "$TARGET"
  fi
done

echo "Готово. Графы собраны по ${#PATHS[@]} путям, репозитории зарегистрированы."
echo
echo "Для автообновления без ручных прогонов:"
echo "  crg-daemon add <path> --alias <name>   # на каждый путь из PATHS"
echo "  crg-daemon start"
