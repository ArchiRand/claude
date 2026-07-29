# code-review-graph (CRG) для klone-mobile

Скрипты для сборки и подключения [code-review-graph](https://pypi.org/project/code-review-graph/)
к монорепо **klone-mobile** так, чтобы MCP-инструменты Claude Code реально видели
граф проекта, а не пустышку.

## Зачем это

Монорепо собирается как **6 отдельных графов** (по модулю), потому что `--repo`
у CRG задаёт одновременно *что парсить* и *куда положить `graph.db`*. Из-за этого
без настройки MCP (auto-detect до git-root) читает не тот `graph.db`, что наполняют
скрипты, и «не находит» классы. Сетап это чинит: вешает дефолтный граф на модуль
`klone-mobile-server`, а остальные модули остаются доступны через `repo_root` /
`cross_repo_search`.

## Предпосылки

- `code-review-graph` в PATH: `uv tool install code-review-graph`
- `python3` (хук парсит JSON события)
- клон монорепо klone-mobile

## Установка (один раз на машину)

```bash
git clone https://github.com/ArchiRand/claude.git ~/projects/claude   # или свой путь
bash ~/projects/claude/code-review-graph/crg-setup.sh /path/to/klone-mobile
```

Скрипт идемпотентный — повторный запуск безопасен. Что он делает:

1. Собирает и регистрирует 6 подграфов (`crg-update.sh`).
2. Вешает симлинк `<project>/.code-review-graph → klone-mobile-server/src/.code-review-graph`
   — дефолтные вызовы MCP (без `repo_root`) бьют по основному модулю.
3. Прячет симлинк в `.git/info/exclude` (трекаемый `.gitignore` не трогается).
4. Идемпотентно прописывает PostToolUse-хук в `<project>/.claude/settings.local.json`,
   указывая на `crg-hook-update.sh` рядом со скриптом (свой абсолютный путь у каждого).

После установки **перезапусти сессию Claude Code**, чтобы MCP подхватил граф.

## Скрипты

| Файл | Назначение |
|---|---|
| `crg-setup.sh` | Полный сетап на новой машине (см. выше). |
| `crg-update.sh` | Пересборка/обновление всех 6 подграфов. Гоняй после крупных изменений/смены ветки. |
| `crg-hook-update.sh` | PostToolUse-хук: на Edit/Write инкрементально обновляет тот подграф, которому принадлежит файл. Вызывается автоматически, руками трогать не нужно. |

## Как пользоваться графом (важно)

Дефолтный граф = **klone-mobile-server**. Поэтому:

- Работаешь в `klone-mobile-server` → зовёшь MCP-инструменты как обычно, без `repo_root`.
- Работаешь в другом модуле → передавай `repo_root` явно. Зарегистрированные корни:
  - `…/klone-mobile-server/src` — game backend (DEFAULT)
  - `…/klone/src` — core engine
  - `…/klone-desktop/src` — desktop
  - `…/server-framework/server/src`
  - `…/server-framework/mobile-fw-server/src`
  - `…/server-framework/server/res`
- Не знаешь, в каком модуле класс → `cross_repo_search_tool` (ищет по всем графам).
- **0 хитов ≠ «класса нет».** Почти всегда он в другом модуле — повтори с нужным
  `repo_root` или через `cross_repo_search`, а не падай в Grep.

Сниппет для вставки в личный `CLAUDE.local.md` проекта (чтобы Claude помнил правила) —
см. раздел «Multi-repo layout» в `CLAUDE.local.md` у Артёма, либо скопируй список
корней выше.

## Что НЕ шарится через git

- Сами `graph.db` — содержат абсолютные пути, у каждого свой `$HOME`. Собираются локально.
- Registry `~/.code-review-graph/registry.json` — локальный.
- Симлинк `.code-review-graph` — создаётся сетапом на каждой машине.
- `settings.local.json` — личный файл, сетап его дополняет, а не коммитит.

## Troubleshooting

- **MCP показывает мало файлов / `status` = десятки файлов** — дефолтный граф не тот.
  Перезапусти `crg-setup.sh` (починит симлинк).
- **`head_matches_build: false`** — граф отстал от рабочего дерева. Прогони `crg-update.sh`.
- **Хук не срабатывает** — проверь, что в `settings.local.json` путь к `crg-hook-update.sh`
  существует и файл исполняемый (`chmod +x`).
