---
name: xconsole-google-sheets
description: Экспорт/импорт моделей монетизационной тулы в Google Sheets в xconsole2-backend — FlatteningConfig, стратегии configuredMapper (by-fields, by-key-value, by-object-index, by-nested-array-index, join, json, zip), fieldMappings, obsoleteHeaders, тесты roundtrip, права на шиты и сервисный аккаунт. Используй когда добавляешь модель в шиты, меняешь раскладку колонок, чинишь баг «не раскладывается на колонки» / «импорт падает», разбираешься с «Нет доступа» к шиту или проверяешь экспорт локально.
---

# Google Sheets в xconsole2-backend

Репа: `~/projects/xconsole2-backend` (фронт — `~/projects/xconsole2-frontend`).
Пайплайн: модель JSON из БД ⇄ плоские строки шита. Всё описывается декларативно в `FlatteningConfig`, код стратегий трогать почти никогда не нужно.

## Добавить модель в шиты — 4 точки

1. **Конфиг** — `src/google/configuredMapper/strategies/strategies.ts`: `export const <Project><Model>FlatteningConfig: FlatteningConfig = {...}`.
2. **Маппер** — `src/google/configuredMapper/strategies/projectModelStrategyMapper.ts`: импорт + ветка `else if (modelId === '<ModelId>')`. Без неё — `Unknown model ... in project ...`.
3. **Флаг для UI** — `src/routes/modelEditor/configuration.ts`, `SHEETS_MODELS.add('<ModelId>')` в блоке проекта. Без него фронт не покажет кнопки Import/Export (`sheets: true`).
4. **Тест** — `tests/google/flattenAndParse/<project>/<ModelId>.test.ts` через `expectFlattenedAndParsed`.

`<ModelId>` — id таблицы из `/api/v1/ui/configuration` игрового сервера (например `MoneyBoxOfferModel`, `PyramidRouletteFeatureModel`).

## FlatteningConfig

```ts
{
  arrayStrategies: ArrayStrategy[];      // применяются ПО ПОРЯДКУ на экспорте, в ОБРАТНОМ — на импорте
  objectStrategies?: ObjectStrategy[];   // только json, после arrayStrategies
  fieldMappings?: Record<string, string>;        // внутренний путь → заголовок колонки
  regexFieldMappings?: {direct: [RegExp, string]; reverse: [RegExp, string]}[];
  obsoleteHeaders?: string[];            // заголовки старой раскладки: импорт с ними падает
}
```

Типы — `src/types/google/flattenedModels.ts`.

## Стратегии

| Стратегия | Параметры | Колонки | Когда |
|---|---|---|---|
| `by-fields` | `field`, `identifierField[]` | `field.prop`, **строка на каждый элемент** | массив объектов, который удобно редактировать построчно (паки, награды, раунды). Единственная, что множит строки |
| `by-key-value` | `field`, `keyField` | `field.<KEY>.<prop>` + `field.<KEY>.index` | массив объектов с уникальным ключом (`item`, `type`) → колонка на ключ. Повтор ключа → суффикс `:1`, `:2` |
| `by-object-index` | `field`, `nestedArrays?` | `field[0].prop`, `field[0].nested.prop` | небольшой массив объектов в одной строке (options, actionPrices, offer-level packs). `nestedArrays: true` — разрешает `field[0].rules[0].x` и запрещает дыры в индексах |
| `by-nested-array-index` | `field`, `innerField` | `field[0].inner` = `a,b,c` | `segmentsComposers` → `segments` |
| `by-primitive-index` | `field` | `field.0`, `field.1` | массив примитивов в отдельные колонки |
| `join` | `field` | `field` = `a,b,c` | массив примитивов в одну ячейку (`hashTags`, `onTryStart`, `serverReviewInfo`) |
| `json` | `field` | `field` = JSON-строка | крайний случай: то, что людям не редактировать. **Не используй для данных, которые геймдиз правит руками** — именно это было багом KA-56963 |
| `zip` | `field`, `withField`, `as` | склеивает `withField[i]` в `field[i]` как `as.*` | два параллельных массива без общего id (pyramid: `rewards` + `actionPrices`). Ставится ДО `by-fields` по `field` |

Вложенные поля адресуются через точку уже расплющенного ключа: после `by-fields` на `moneyBoxes` следующая стратегия пишет `field: 'moneyBoxes.packs'`.

### Правила порядка

- Родительский `by-fields` раньше дочернего; у дочернего `identifierField` включает родительский id: `['id', 'moneyBoxes.id']`. Ids должны быть уникальны в рамках родителя — иначе `must be unique across models`.
- Два `by-fields` на соседних (не вложенных) массивах дают декартово произведение строк — так не делай; второй массив раскладывай `by-object-index` или `by-key-value`.
- При нескольких строках на модель все «общие» поля дублируются в каждой строке; на импорте `reverseByFieldsFromRows` требует, чтобы они совпадали (`inconsistent values across rows`).

## fieldMappings и значения

- Ключ — путь после стратегий; булевы поля — с суффиксом `:boolean` (`'endByDR:boolean': 'Offer EndByDR'`), в ячейке `1`/`0`.
- Поле без маппинга выгружается с сырым заголовком (`moneyBoxes.packs.watchAd:boolean`) — работает, но некрасиво.
- Порядок колонок в шите = порядок ключей в `fieldMappings`, затем немапленные в порядке появления.
- Для индексных колонок (`segmentsComposers[N].segments`) принято явно расписывать 20 штук: `'... Segments'`, `'... Segments 2'` … `'... Segments 20'`. Для двойной индексации — генератор, см. `guaranteedPickupFieldMappings` в `strategies.ts`.
- `regexFieldMappings` нужны для `by-key-value`: пара `direct`/`reverse`, напр. `PRIZE_$1` ⇄ `prizes.$1.count` и `PRIZE_$1_INDEX` ⇄ `prizes.$1.index`. Reverse проверяется с конца списка — более общий паттерн ставь раньше.
- `fieldMappings` должен быть биективным: два пути на один заголовок сломают импорт.

### Валидация значений

- Экспорт: перед стратегиями `normalizeModels` превращает числа в строки и выкидывает `null`/`''`/`[]`/`{}`. После стратегий каждое значение — непустая строка или boolean, иначе `postProcess: Field ... has non-string` (значит, массив/объект остался без стратегии).
- Импорт: каждая ячейка — непустая строка; пустые ячейки отсутствуют в объекте строки.
- Заголовки шита (`preprocessHeader`): колонка с `!` в начале игнорируется; `#XYZ` превращается в `<предыдущая колонка>_XYZ` (так пишут `PRIZE_GOLD` + `#INDEX`); дубли запрещены.

## Смена раскладки существующей модели

Если меняешь колонки (json → колонки, переименование), старые шиты у геймдизов останутся. Добавь их заголовки в `obsoleteHeaders` — импорт упадёт понятной ошибкой `Sheet has outdated columns: ... Export to a new sheet` вместо молчаливой порчи данных (старый JSON-столбец иначе прилетит в модель строкой). Пример — `CommonPickupGroupModel`, `MoneyBoxOfferModel`.

## Тесты

```ts
import {expectFlattenedAndParsed} from '../../../../src/helpers/modelEditor/forTests/expectFlattenedAndParsed';
expectFlattenedAndParsed(models, expectedFlatObjects, Config); // экспорт == expected, импорт == models
```

Также есть `expectFlattened`, `expectParsed`, `expectFlatDataParsed` (сырой 2D-массив с заголовком, прогоняет `preprocessHeader`). Для ошибок — `expect(() => parseFlattenedModels(rows, Config)).toThrow(...)`.

Модели в тестах — уже нормализованные: числа строками, без пустых значений, с `linkID`.
Обязательно покрывай: несколько элементов в каждом `by-fields` (размножение строк), элемент без вложенного массива, булевы поля.

```bash
yarn test --testPathPatterns=<ModelId>   # jest новый: --testPathPattern больше не работает
yarn test && yarn lint                   # lint — zero warnings
```
`yarn` берётся из Homebrew; `~/.nvm/nvm.sh` на машине нет.

## Флоу в рантайме

- **Export** (`POST /model-editor/v1/ui/google/appendData` → `OfferToolGoogleSheetsFacade.transferModelsToSheet`): модели из БД по `generatedIds` (без `servers`, `generatedID`, `@class`, с `linkID`) → `getFlattenedModels` → **дописывание** в лист. Пустой лист — сначала заголовки; непустой — недостающие колонки добавляются справа, строки вниз. Ничего не перезаписывается.
- **Import** (`GET /model-editor/v1/ui/google/data/...` → `getModelsFromSheet`): `preprocessHeader` → `parseFlattenedModels` → `onCurrentServer`: по `linkID` ищет модель на текущем сервере — нашлась → перезапись, нет → создание. Результат уходит во фронт как черновики.
- Список файлов — Drive-поиск по свойствам `project` + `componentID` (без фильтра по пользователю).

## Права на шиты

Бэк ходит в Google от сервисного аккаунта из `OFFER_TOOL_GOOGLE_CREDENTIALS` (`src/google/google.ts`):
- k8s-release: `monetization-tool@monetization-too-427809.iam.gserviceaccount.com`
- остальное и локально: `personal-monetization-tool@personal-monetization-tool.iam.gserviceaccount.com`

**Create** (`POST /sheets/create`): владелец — сервисный аккаунт, `writer` выдаётся только на email из Keycloak-сессии. Запросы доступа от других уходят сервисному аккаунту — их никто не увидит; делиться должен создатель.
**Link table** (`POST /google/external/link`, кнопка только в режиме Import): свой шит, сервисному аккаунту даёшь Editor вручную; на 403 бэк сам подсказывает email. После линковки файл виден и в Export.

## Локальная проверка

- Emergency-логин и `ivan.ivanov` не дают email Google-аккаунта → Create создаёт шит, к которому у тебя «Нет доступа». Варианты:
  - завести в локальном Keycloak (`http://localhost:8080/admin/master/console/`, `keycloak`/`keycloak`, realm **xconsole**) юзера со своей рабочей почтой, Email verified, пароль без Temporary;
  - или свой шит + Editor для `personal-monetization-tool@…` + Link table.
- Logout в туле не завершает SSO Keycloak — для смены юзера открыть `http://localhost:8080/realms/xconsole/protocol/openid-connect/logout` (или Sessions → Sign out в админке, или инкогнито).
- Проверяй экспорт на **пустом листе**: в старый лист новые колонки допишутся справа к старым.

## Известные ловушки в коде

- `createSpreadSheet` вызывает `addPermission` без `await` — ошибка выдачи прав глотается, UI пишет «created».
- В `pushModelToSheet` `appendData`/`updateRange` тоже не ожидаются — ошибки записи после заголовков не долетают до ответа.
- `configuration.ts`: `serverConfig.base_url` читается до проверки `if (!serverConfig)` — неизвестный сервер даёт 500 вместо 404.
