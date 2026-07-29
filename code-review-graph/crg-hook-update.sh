#!/bin/bash
# PostToolUse-хук CRG: инкрементально обновляет ТОТ зарегистрированный подграф,
# которому принадлежит изменённый файл.
#
# Почему так, а не `update --repo <git-root>`: в монорепо каждый модуль собран
# как отдельный repo-root (см. crg-update.sh PATHS) со своим graph.db в
# <module>/.code-review-graph/. Апдейт по git-root плодил бы отдельный огрызок,
# который MCP и читал вместо полных графов. Здесь мы находим нужный подграф по
# префиксу пути файла и обновляем именно его — без загрязнения и без огрызков.
#
# Вешается на PostToolUse (Edit|Write). Получает JSON tool-события в stdin.
set -euo pipefail

input="$(cat 2>/dev/null || true)"
command -v code-review-graph >/dev/null 2>&1 || exit 0

# путь изменённого файла из tool_input
file="$(printf '%s' "$input" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('file_path',''))" \
  2>/dev/null || true)"
[ -n "$file" ] || exit 0

# найти зарегистрированный repo-root, покрывающий файл (самый длинный префикс)
best=""
while IFS= read -r repo; do
  repo="${repo#"${repo%%[![:space:]]*}"}"   # ltrim
  [ -n "$repo" ] || continue
  case "$file" in
    "$repo"/*)
      [ "${#repo}" -gt "${#best}" ] && best="$repo"
      ;;
  esac
done < <(code-review-graph repos 2>/dev/null || true)

[ -n "$best" ] || exit 0   # файл вне зарегистрированных модулей — молча выходим

code-review-graph update --skip-flows --repo "$best" >/dev/null 2>&1 || true
exit 0
