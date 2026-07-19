#!/bin/bash
# Обновление graphify-графа по 6 закреплённым путям (custom multi-path merge,
# не покрывается штатным `graphify update .` — тот сканил бы весь 114GB репо).
# Самодостаточен: работает в любом клоне/воркдире этого проекта без правок,
# сам находит корень репы и python-интерпретатор с graphify, даже если
# graphify тут ещё ни разу не запускался.
# Запуск: bash graphify-out/update.sh
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"
mkdir -p "$ROOT/graphify-out"

# --- найти python с установленным graphify (та же логика, что в Step 1 скила) ---
PY=""
if [ -f "$ROOT/graphify-out/.graphify_python" ]; then
  _CANDIDATE=$(cat "$ROOT/graphify-out/.graphify_python" 2>/dev/null)
  if [ -n "$_CANDIDATE" ] && [ -x "$_CANDIDATE" ] && "$_CANDIDATE" -c "import graphify" 2>/dev/null; then
    PY="$_CANDIDATE"
  fi
fi
if [ -z "$PY" ]; then
  GRAPHIFY_BIN=$(command -v graphify 2>/dev/null || true)
  if command -v uv >/dev/null 2>&1; then
    _UV_PY=$(uv tool run graphifyy python -c "import sys; print(sys.executable)" 2>/dev/null || true)
    [ -n "$_UV_PY" ] && PY="$_UV_PY"
  fi
  if [ -z "$PY" ] && [ -n "$GRAPHIFY_BIN" ]; then
    _SHEBANG=$(head -1 "$GRAPHIFY_BIN" | tr -d '#!')
    case "$_SHEBANG" in
      *[!a-zA-Z0-9/_.@-]*) ;;
      *) "$_SHEBANG" -c "import graphify" 2>/dev/null && PY="$_SHEBANG" ;;
    esac
  fi
  if [ -z "$PY" ]; then PY="python3"; fi
  if ! "$PY" -c "import graphify" 2>/dev/null; then
    echo "graphify не найден для интерпретатора $PY. Установи: uv tool install graphifyy" >&2
    exit 1
  fi
  echo "$PY" > "$ROOT/graphify-out/.graphify_python"
fi

PATHS=(
  "klone-mobile-server/src"
  "klone-desktop/src"
  "klone/src"
  "server-framework/server/src"
  "server-framework/mobile-fw-server/src"
  "server-framework/server/res"
)

echo "== 1/4: AST-update по ${#PATHS[@]} путям (без LLM; если графов ещё нет - соберутся с нуля; семантика из прошлых прогонов сохраняется) =="
# Без --no-cluster: update идёт через build_from_json, который отбрасывает рёбра
# на внешние/stdlib-символы (getter/xppdriver/...), которых нет в списке узлов.
# С --no-cluster эта проверка пропускается, и networkx при загрузке в merge-graphs
# материализует такие рёбра в узлы-призраки без атрибутов (проверено на практике -
# +13420 паразитных узлов на 6 путях).
for p in "${PATHS[@]}"; do
  echo "--- $p ---"
  graphify update "$ROOT/$p"
done

echo "== 2/4: мердж в единый граф =="
MERGE_ARGS=()
for p in "${PATHS[@]}"; do
  MERGE_ARGS+=("$ROOT/$p/graphify-out/graph.json")
done
graphify merge-graphs "${MERGE_ARGS[@]}" --out "$ROOT/graphify-out/graph.json"

echo "== 3/4: глобальный recluster + эвристическая разметка коммьюнити + отчёт =="
graphify cluster-only . --no-label --no-viz

"$PY" - <<'PYEOF'
import json
from collections import Counter
from pathlib import Path
from networkx.readwrite import json_graph
from graphify.cluster import score_all
from graphify.analyze import god_nodes, surprising_connections, suggest_questions
from graphify.report import generate

root = Path("graphify-out")
data = json.loads((root / "graph.json").read_text(encoding="utf-8"))
G = json_graph.node_link_graph(data, edges="links")

communities = {}
for n, attrs in G.nodes(data=True):
    cid = attrs.get("community")
    if cid is None:
        continue
    communities.setdefault(cid, []).append(n)

# Эвристическая разметка: имя коммьюнити = самый частый префикс директории
# среди source_file её узлов. Не LLM (при 1000+ коммьюнити это нереально
# делать вручную за один проход) - просто "где физически лежит код".
def label_for(members):
    dirs = []
    for n in members:
        sf = G.nodes[n].get("source_file") or ""
        parts = sf.replace("\\", "/").split("/")
        if len(parts) > 1:
            dirs.append(tuple(parts[:-1]))
    if not dirs:
        return None
    depth_counts = Counter(dirs)
    most_common_full, count = depth_counts.most_common(1)[0]
    if count >= max(2, len(members) * 0.4):
        prefix = most_common_full
    else:
        prefix = None
        for depth in range(max(len(p) for p in dirs), 0, -1):
            trimmed = [p[:depth] for p in dirs if len(p) >= depth]
            if not trimmed:
                continue
            c = Counter(trimmed)
            top, cnt = c.most_common(1)[0]
            if cnt >= max(2, len(dirs) * 0.5):
                prefix = top
                break
        prefix = prefix or dirs[0]
    if not prefix:
        return None
    tail = list(prefix)[-2:] if len(prefix) >= 2 else list(prefix)
    words = [seg.replace("_", " ").replace("-", " ").capitalize() for seg in tail]
    return " ".join(words) if words else None

labels = {}
for cid, members in communities.items():
    labels[cid] = label_for(members) or f"Community {cid}"
(root / ".graphify_labels.json").write_text(
    json.dumps({str(k): v for k, v in labels.items()}, indent=2, ensure_ascii=False), encoding="utf-8"
)

cohesion = score_all(G, communities)
gods = god_nodes(G)
surprises = surprising_connections(G, communities)
questions = suggest_questions(G, communities, labels)

# bridge_node-вопросы для god-node'ов (GameState и т.п.) на мердже из 6 путей
# перечисляют ВСЕ соседние коммьюнити подряд - при сотнях соседей вопрос
# превращается в простыню из полутора сотен имён. Наши эвристические лейблы
# к тому же сильно повторяются (одно и то же имя у десятков разных коммьюнити),
# так что дедуп с подсчётом частоты не просто короче, а информативнее голой
# обрезки - сразу видно, с чем узел связан сильнее всего.
import re as _re
_BRIDGE_RE = _re.compile(r"^Why does `(.+?)` connect `(.+?)` to (.+)\?$")
_ITEM_RE = _re.compile(r"`([^`]+)`")

def _fix_bridge_question(q, max_shown=10):
    if q.get("type") != "bridge_node":
        return q
    m = _BRIDGE_RE.match(q["question"])
    if not m:
        return q
    hub, home, tail = m.groups()
    items = _ITEM_RE.findall(tail)
    if len(items) <= max_shown:
        return q
    counts = Counter(items)
    ranked = counts.most_common()
    shown = ranked[:max_shown]
    shown_names = {name for name, _ in shown}
    remaining_occurrences = sum(c for name, c in ranked if name not in shown_names)
    remaining_distinct = len(ranked) - len(shown)
    parts = [f"`{name}`" + (f" (×{cnt})" if cnt > 1 else "") for name, cnt in shown]
    suffix = f", +{remaining_occurrences} more across {remaining_distinct} other communities" if remaining_occurrences else ""
    q = dict(q)
    q["question"] = f"Why does `{hub}` connect `{home}` to {', '.join(parts)}{suffix}?"
    return q

questions = [_fix_bridge_question(q) for q in questions]

detection = {"total_files": 0, "total_words": 0, "files": {}, "skipped_sensitive": []}
tokens = {"input": 0, "output": 0}

report = generate(G, communities, cohesion, labels, gods, surprises, detection, tokens, ".", suggested_questions=questions)

# При 1000+ коммьюнити (мердж нескольких кодовых баз без LLM-разметки) секции
# "Community Hubs" и "Communities" превращаются в дамп на тысячи строк, который
# никто не читает. На graphify query/path/explain это не влияет - они читают
# graph.json напрямую, не отчёт. Обрезаем до топ-N (коммьюнити уже отсортированы
# по убыванию размера) и честно пишем, сколько опущено - без тихого урезания.
MAX_COMMUNITIES_IN_REPORT = 40

def _truncate_section(text, header_prefix, max_items, item_splitter, omitted_note):
    start = text.find(header_prefix)
    if start == -1:
        return text
    next_header = text.find("\n## ", start + 1)
    end = next_header if next_header != -1 else len(text)
    section = text[start:end]
    header_line_end = section.find("\n")
    header_line = section[:header_line_end]
    body = section[header_line_end:]
    items = item_splitter(body)
    if len(items) <= max_items:
        return text
    kept = "".join(items[:max_items])
    note = omitted_note(len(items) - max_items)
    new_section = header_line + "\n" + kept + note
    return text[:start] + new_section + text[end:]

report = _truncate_section(
    report,
    "## Community Hubs (Navigation)",
    MAX_COMMUNITIES_IN_REPORT,
    lambda body: [line + "\n" for line in body.strip("\n").split("\n") if line.strip()],
    lambda n: f"- _... и ещё {n} коммьюнити - полный список в graph.json / `graphify query`_\n",
)
report = _truncate_section(
    report,
    "## Communities (",
    MAX_COMMUNITIES_IN_REPORT,
    lambda body: ["\n### " + block for block in body.split("\n### ")[1:]],
    lambda n: f"\n_... и ещё {n} коммьюнити опущено (не по объёму знаний, а по объёму отчёта) - полный список в graph.json, конкретную коммьюнити можно поднять через `graphify query`/`graphify explain`_\n",
)

(root / "GRAPH_REPORT.md").write_text(report, encoding="utf-8")
print(f"Report regenerated: {len(communities)} communities, {G.number_of_nodes()} nodes, {G.number_of_edges()} edges")
PYEOF

echo "== 4/4: html-визуализация =="
graphify export html

echo "Готово. graphify-out/GRAPH_REPORT.md и graphify-out/graph.html обновлены."
