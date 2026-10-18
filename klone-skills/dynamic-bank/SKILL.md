---
name: dynamic-bank
description: >
  Архитектура и работа DynamicBank — банка с меняющимися офферами за реал и изумруды.
  Используй когда: понимаешь как работает банк, добавляешь/меняешь бандлы в XML,
  отлаживаешь условия показа/ротации, разбираешься с клиентским или серверным кодом банка,
  меняешь логику обновления или статистики, а также когда разбираешься почему в банке нет
  или различается по платформам маленький пакет валюты — их клиент досыпает сам из
  платформенной группы продуктов, минуя сервер.
---

# DynamicBank — архитектура и работа

## Главный принцип

DynamicBank — банк с **динамически вычисляемыми** офферами. Каждый офферный слот показывает
ровно один бандл — тот, который первым прошёл проверку условий из списка кандидатов.
Банк пересчитывается при старте сессии и по игровым событиям (level up, платёж и т.д.).

В отличие от офферов (`OfferSuper`) — у DynamicBank **нет жизненного цикла** типа start/finish.
Это просто "витрина": пересчитали, показали, купили.

---

## Структура: три слоя

| Слой | Класс | Модуль | Назначение |
|------|-------|--------|------------|
| Конфиг | `DynamicBankItem` | `klone-common` | XML → объект, неизменяемый |
| Серверный стейт | `DynamicBank` | `klone-mobile-server` | Runtime-объект в профиле игрока |
| Клиент | `DynamicBankState` + окно | `klone` | Отображение и покупка |

---

## Два источника содержимого: сервер даёт бандлы, клиент досыпает слоты

Неочевидное и важное: **в окне банка две группы товаров, и приходят они из разных мест.**

| Что | Откуда | Кто решает состав |
|---|---|---|
| **Большие бандлы** (`bigBundleContainer`) | серверный стейт — `DynamicBank.currentOffers` | сервер: `refillBank()` по условиям |
| **Маленькие пакеты** (`smallBundleContainer`) | XML прямо на клиенте | клиент: `DynamicBankWindowPresenter.updateSmallBundles()` |

Сервер про маленькие пакеты **не знает вообще** — они не в `currentOffers`, не в стейте, не в
`DynamicBankEvent`. Клиент собирает их сам при каждом `updateModel()`. Поэтому искать их в
серверном коде банка бессмысленно.

### `updateSmallBundles()` — две ветки по типу банка

```java
// klone/src/com/vizor/klone/ui/dynamicbank/DynamicBankWindowPresenter.java
if (isInAppsBank())   // isInAppsBank = Items.CASH_SLOT.equals(bankType)
{
    // изумрудный банк: реальные in-app продукты платформы, отфильтрованные по «выдаёт CASH»
    smallBundles = Lists.select(gameState.getProductsState().getActualInAppsProductsItems(),
            item -> R.Item.CASH.equals(getInAppProductItem((ProductItem) item).getId()));
}
else
{
    // монетный банк: отдельная XML-группа bank_shop_items
    smallBundles = items.getBankShopGroup().getItems();
}
```

| Банк | Источник | Тип айтема | Цена |
|---|---|---|---|
| `CASH_SLOT` (изумруды) | `ProductsState.getActualInAppsProductsItems()` | `ProductItem` | из стора, патчится |
| `MONEY_SLOT` (монеты) | группа `bank_shop_items` | `BankShopItem` (`item`, `count`, `image`) | не патчится, `BankShopItem` — не `ProductItem` и не имеет `purchase` |

### Почему изумрудная витрина платформенно-зависимая

`actualInAppsProductsItems` наполняется в конструкторе `ProductsState` ровно из одной группы:

```java
selectProductItems(actualInAppsProductsItems,
        items.<ItemGroup>getItem(R.Config.purchases_group()), ProductItem.class);
```

`R.Config.purchases_group()` — **не константа, а значение из конфига сборки**, подставляемое в
генерённый `klone/gen/com/vizor/klone/res/config/R.java` (лежит там base64-строкой; в
android-сборке это `products_android`). В XML под это заведены отдельные группы на каждый стор:

```
products_android   products_ios   products_amazon   products_huawei
products_uwp       products_ru_store              products_yookassa
```

Отсюда прямое следствие: **набор маленьких слотов в изумрудном банке различается по платформам
по построению** — другой список SKU, другое количество слотов, другие цены. Один и тот же билд
на разных сторах покажет разную витрину, и это не баг.

### Два разных механизма платформенных SKU — не перепутать

В проекте платформенная специфика продуктов решается **двумя разными способами**, и в банке
встречаются оба:

| Механизм | Для чего | Как выбирается SKU |
|---|---|---|
| Отдельная XML-группа на стор (`products_android`, `products_ios`, …) | простые in-app продукты — маленькие слоты банка | группа целиком выбирается через `R.Config.purchases_group()`; у айтема свой `purchase` прямо в XML |
| Список `platformPurchase` внутри одного айтема | `PackPurchaseItem` — бандлы банка, офферы, паки фич | в рантайме в `ProductsState.addToMap()`: ищется запись с `R.Config.platform()` и подставляется в `productItem.setPurchase(...)` |

Причём резолвинг `platformPurchase` в `addToMap()` срабатывает **только для
`isPackPurchaseItem()`** и только когда `purchase == null`. Обычному `ProductItem` он не
достанется — ему и не нужен, за него отвечает выбор группы.

### Где патчатся цены больших бандлов

`packPurchase`-и больших бандлов лежат в **отдельной непплатформенной группе**
`dynamic_bank_purchases` (в `products_adjust.xml`), на которую бандлы ссылаются через
`<packPurchase reference="..."/>`. В `ProductsState` эта группа добавляется в общий
`productItems` — то есть попадает в `productsMap` и патчится ценами, — но **не** в
`actualInAppsProductsItems`:

```java
selectProductItems(productItems, items.<ItemGroup>getItem(R.Item.dynamic_bank_purchases), ProductItem.class);
```

Именно поэтому большие бандлы получают цены из стора, но при этом никогда не всплывают в
маленьких слотах. Если добавить их в `actualInAppsProductsItems`, они продублируются в витрине.

### Множитель покупки

Для изумрудного банка к моделям маленьких пакетов применяется коэффициент из
`gameState.getPurchaseMultiplier()`; для монетного всегда `DEFAULT_PERCENT = 100`.

---

## Иерархия конфига (`DynamicBankItem`)

```
dynamicBank (id="DYNAMIC_BANK")
  ├── onlineUpdateListeners       — события для онлайн-обновления банка
  ├── markNewConditions           — условия, при которых новые бандлы помечаются NEW
  ├── conditions                  — условия доступности банка целиком
  ├── productAnimatedIconsConfig  — маппинг image → анимированная вьюшка
  └── slot (BankSlot) × N
        ├── name                  — название слота (показывается в UI)
        ├── slotType              — CASH_SLOT | MONEY_SLOT
        ├── showConditions        — когда слот виден вообще
        └── bundle (BankBundle) × M
              ├── packPurchase    — за реал (XOR с packShop)
              ├── packShop        — за изумруды (XOR с packPurchase)
              ├── showConditions  — условия показа (ALL должны выполниться)
              ├── skipConditions  — условия пропуска (ANY сработало → бандл пропускается)
              ├── layout, image, labelImage — UI-данные
              └── abTests         — AB-тест (не более 1)
```

`postConstruct` в `BankSlot`/`BankBundle` инжектирует в каждый бандл `slotName`/`slotType`/`slotId`
из родительского слота (включая бандлы внутри AB-теста).

---

## Серверный runtime: `DynamicBank`

### Ключевые поля стейта

| Поле | Тип | Что хранит |
|------|-----|------------|
| `currentOffers` | `List<BankBundle>` | Текущие активные бандлы (сериализуется клиенту) |
| `activeStartDates` | `Map<id, Date>` | Дата начала показа для активных бандлов |
| `allStartDates` | `Map<id, Date>` | То же, но за всё время (только для статистики) |
| `purchaseDates` | `Map<id, List<Date>>` | Даты покупок по каждому бандлу |
| `newBundles` | `List<String>` | Бандлы, которые игрок ещё не видел |

### Инициализация

```
onOwnerAccess()
  1. getDynamicBankItem() — если null (банк неактивен) → isActive=false, выход
  2. refillBank()          — пересчитать витрину
  3. Подписываемся на onlineUpdateListeners (levelUp, payment, и т.д.)
     → callback refillOnline() → ждёт выхода из мини-игры → refillBank()
```

### Алгоритм `refillBank()`

```
1. Очищаем currentOffers
2. Для каждого слота:
   a. slot.isAvailable(gameState)?  → нет → skip
   b. findBundle(bundles):
      - Перебираем бандлы по порядку
      - skipConditions (ANY) сработало → skip
      - showConditions (ALL) выполнились → return этот бандл (с учётом AB-теста)
   c. Добавляем в currentOffers, запоминаем id
3. Удаляем из activeStartDates бандлы, которых нет в currentBundlesIds
   → sendBundleExpiredStats()
   → если был в newBundles → убираем
4. Для новых бандлов (есть в current, нет в activeStartDates):
   → activeStartDates.put(id, now)
   → sendBundleStartedStats()
   → если isSendNewBundles() → newBundles.add(id)
5. allStartDates.putAll(activeStartDates)
6. DynamicBankEvent(BANK_UPDATED) → клиент получает обновление
```

---

## XML-конфиг: как устроены бандлы

### Механизм ротации (`dynamicBankBundleActive`)

Ключевой инструмент для смены бандлов — условие `dynamicBankBundleActive`:

```xml
<dynamicBankBundleActive bundleId="X" expired="true"  showDuration="P5D"/>
<!-- SKIP если бандл X показывался дольше 5 дней (expired=true означает "уже истёк") -->

<dynamicBankBundleActive bundleId="X" expired="false" showDuration="P3D"/>
<!-- SKIP если бандл X показывался меньше 3 дней (expired=false означает "ещё свежий") -->

<dynamicBankBundleActive bundleId="X"/>
<!-- SKIP если бандл X сейчас активен (без showDuration) -->
```

Типовая схема ротации внутри слота: бандлы лежат в XML в обратном порядке (от «дальнего» к
«первому»), перебираются сверху вниз, показывается первый не заскипанный. У каждого бандла в
`skipConditions` собраны три вида условия:

```xml
<skipConditions>
    <!-- условия сегментации: уровень, персонализация и т.п. -->
    <dynamicBankBundleActive bundleId="сам_себя"  expired="true"  showDuration="P5D"/>
    <dynamicBankBundleActive bundleId="следующий_1"/>
    <dynamicBankBundleActive bundleId="следующий_2"/>
    <dynamicBankBundleActive bundleId="первый"    expired="false" showDuration="P5D"/>
</skipConditions>
```

| Форма | Смысл |
|---|---|
| на себя, `expired="true"` + `showDuration` | «я свой срок уже отработал — пропусти меня» |
| на соседей, без атрибутов | «сейчас активен кто-то другой — пропусти меня», держит в слоте ровно один бандл |
| на базовый бандл, `expired="false"` + `showDuration` | «базовый ещё свежий — моя очередь не пришла» |

`showDuration` у разных бандлов свой (в конфиге встречаются и `P5D`, и `P3D`) — единого срока нет.

За счёт этого слот сам переключается на следующий бандл по мере истечения срока предыдущего,
никакой серверной логики очереди для этого не нужно.

### Актуальный состав слотов — только из XML

Конкретные слоты, бандлы и условие доступности банка целиком живут в
`klone-common/res/items/release/products_adjust.xml` и меняются каждый релиз — здесь их
не дублируем, чтобы не расходились. Смотри сам XML:

```bash
grep -n "<slot\|<bundle\|dynamicBank" klone-common/res/items/release/products_adjust.xml
```

Что там искать: `slotType` (`CASH_SLOT` / `MONEY_SLOT`), порядок бандлов внутри слота
(он же порядок перебора в `findBundle`), `showConditions`/`skipConditions` на слоте и на
бандлах, `conditions` на самом `dynamicBank` — это и есть доступность банка целиком
(обычно AB-тест).

Типовые схемы, которые встречаются в конфиге: ротация стартовых наборов по возрасту бандла
и уровню игрока, слот-дублёр, видимый только когда основной слот отсутствует, наборы за
внутриигровую валюту с ротацией по `showDuration`.

---

## Статистика

| Событие | Когда |
|---------|-------|
| `Bundle Started` | Бандл появился в currentOffers впервые |
| `Bundle Expired` | Бандл исчез из currentOffers |
| `Bundle Completed` | Игрок купил бандл |

`Bundle Completed` содержит: `id`, `type` (real/cash), `duration_gametime` (секунды с момента первого показа или последней покупки), `count` (сколько раз куплен), `price` или `price_cash`.

---

## Покупка

```
buyPackPurchase(ppi) или buyPackShop(ppi)
  → findPackPurchaseBundle() / findPackShopBundle() — ищет в currentOffers
    (для packPurchase — если не нашёл в current, ищет по всем слотам)
  → processBuyBundle(bundle)
      → sendBundleCompletedStats()
      → purchaseDates.add(now)
      → KloneSessionEvent(DYNAMIC_BANK_PURCHASE, bundleId, slotType)
```

`isBankPackPurchase(ppi)` — проверяет что ppi был показан в банке (через `shownPackPurchases`).
`isBankPackShop(packShop)` — проверяет что packShop сейчас активен в currentOffers.

---

## Клиентская сторона

### `DynamicBankState` — мост сервер → UI

```java
// Инициализация: забирает DynamicBank из KloneGameState и зануляет ссылку
DynamicBankState(KloneGameState) → this.dynamicBank = kloneGameState.getDynamicBank()

getDynamicBundles(bankType)  // фильтрует currentOffers по slotType
searchNeededBundle(itemId)   // ищет бандл, содержащий itemId (сортировка по цене ↓)
removeViewedBundles(list)    // после просмотра → updateFlags() → notifyListeners()
```

`updateFlags()` пересчитывает `newInCashBank`/`newInCoinsBank` → нотифицирует подписчиков
(используется для меток NEW на кнопках HUD).

### `DynamicBankWindowPresenter` — логика окна

- `updateModel()` — тянет `getDynamicBundles(bankType)` + `getNewBundles()` из `DynamicBankState`
- `buy(item)`: `ProductItem` → `Klondike.billing().buy()` (IAP); shop-item → проверка баланса → `ServerEventManager.buy()`
- `initProductImage()` — для каждого бандла ищет анимированную иконку в `animatedIconsConfig`; если не нашёл — ставит обычный image
- `destroy()` → `markViewedBundles()` → `ServerEventManager.markViewedBundles()` (серверное событие) + `DynamicBankState.removeViewedBundles()`

### `DynamicBankWindow` — UI

Два контейнера в горизонтальном `ScrollView`:
- `bigBundleContainer` — большие бандлы (из DynamicBank), по типу `bankType`
- `smallBundleContainer` — маленькие пакеты изумрудов/монет (in-app products или bankShopGroup)

**`MoreBundlesButton`** — если бандлов больше чем влезает в экран. При нажатии:
1. Маленькие бандлы улетают с анимацией
2. `bigBundleContainer.setCols(MAX_INT)` → все бандлы раскрываются
3. `scBundleList.scrollToPosition(...)` — скролл влево

**Match3-банк:** `isMatch3BankEnabled()` → если выполнены условия из `DYNAMIC_BANK_MATCH3` →
открывается `MatchThreeDynamicBankWindow` вместо стандартного.

**Открытие с конкретным бандлом:**
```java
DynamicBankWindow.showWindow(gameState, neededBundle, searchedItem, openBehavior)
// → scrollToPosition + playSearchedItemParticle(searchedItem) для нужного BigBundleView
```

**Показ награды:**
- 1 продукт в бандле → `ThanksForPurchase` диалог
- Несколько → `OfferRewardScene` (PackRewardingComponent)

---

## Поток данных end-to-end

Две независимые ветки сходятся только в презентере:

```
ВЕТКА 1 — большие бандлы (через сервер)
products_adjust.xml
  slot/bundle + dynamic_bank_purchases (packPurchase по reference)
      ↓ (parse)
DynamicBankItem (config, klone-common)
      ↓ (refillBank: условия слотов и бандлов)
DynamicBank.currentOffers
      ↓ (DynamicBankEvent BANK_UPDATED → serialize)
DynamicBankState.setDynamicBank()
  → updateFlags() → HUD badges listeners
      ↓
DynamicBankWindowPresenter.updateModel()
  → model.setDynamicBundles(getDynamicBundles(bankType))

ВЕТКА 2 — маленькие пакеты (сервер не участвует)
R.Config.purchases_group()  ──→ products_<платформа>.xml   [изумрудный банк]
bank_shop_items             ──→ BankShopItem                [монетный банк]
      ↓
ProductsState.actualInAppsProductsItems   (только для изумрудного)
      ↓ фильтр «выдаёт CASH»
DynamicBankWindowPresenter.updateSmallBundles()
  → model.setSmallBundles(...)

                    ↓ обе ветки ↓
DynamicBankWindow.updateBundles()
  → BigBundleView (ветка 1) + SmallBundleView (ветка 2)
```

Цены обеих ветвей патчит один механизм — `SyncOperation`/`ProductFiller` через
`ProductsState.productsMap` — но только для `ProductItem`. `BankShopItem` монетного банка мимо
него проходит, у него цена в XML (`buyCash`).

---

## Быстрый справочник по файлам

```
klone-mobile-server/src/com/social/game/klonemobile/
  game/
    DynamicBank.java                     ← runtime-стейт игрока
  items/
    DynamicBankItem.java                 ← конфиг: BankSlot, BankBundle

klone-common/res/items/release/
  products_adjust.xml                    ← слоты/бандлы банка + группа dynamic_bank_purchases
  products.xml                           ← ВСЕ платформенные группы в одном файле:
                                           products_android, products_ios, products_amazon,
                                           products_huawei, products_uwp, products_ru_store,
                                           products_yookassa (+ *_archive).
                                           Одна из них выбирается через
                                           R.Config.purchases_group() и даёт маленькие слоты
                                           изумрудного банка

klone/src/com/vizor/klone/billing/
  ProductsState.java                     ← actualInAppsProductsItems (платформенная группа),
                                           productsMap, addToMap: резолвинг platformPurchase

klone/gen/com/vizor/klone/res/config/
  R.java                                 ← purchases_group() — значение из конфига сборки

klone/src/com/vizor/klone/ui/dynamicbank/
  DynamicBankState.java                  ← мост сервер→клиент, флаги NEW
  DynamicBankModel.java                  ← data-holder для презентера
  DynamicBankWindowPresenter.java        ← логика: buy, updateModel, markViewed
  DynamicBankWindow.java                 ← UI, анимации, scroll, Match3-ветка
  IDynamicBankWindow.java                ← интерфейс окна
  bundles/
    bigbundles/BigBundleView.java        ← большой бандл с hint-окном
    smallbundles/SmallBundleView.java    ← маленький пакет
    subsbundles/SubsBundleView.java      ← подписка (если доступна)
    MoreBundlesButton.java               ← кнопка раскрытия всех бандлов
  match3/
    MatchThreeDynamicBankWindow.java     ← Match3-вариант банка
```

---

## Ловушки и частые вопросы

| Проблема | Что происходит |
|----------|----------------|
| Бандл не показывается | Проверь `skipConditions` — сначала они, потом `showConditions`. ANY skip = skip. |
| Банк не обновляется онлайн | `onlineUpdateListeners` в XML — проверь что нужный listener есть |
| `getBankBundleById` возвращает null | Бандл не в `allStartDates` (никогда не показывался) или не найден в DynamicBankItem и items |
| `shownPackPurchases` содержит null | Нормально: `shownPackPurchases.removeIf(i -> i == null)` в refillBank |
| `slotType` у бандла не проставлен | `postConstruct` в `DynamicBankItem` инжектирует из слота — нужен корректный XML |
| `allStartDates` null при первом `processBuyBundle` | `allStartDates` инициализируется в `refillBank` — если банк ни разу не пересчитывался, будет NPE |
| Маленький пакет не ищется в серверном коде банка | Его там нет. Маленькие слоты собирает клиент в `updateSmallBundles()`, сервер про них не знает |
| Маленький пакет не появился в изумрудном банке | Он должен лежать в группе `R.Config.purchases_group()` **текущей платформы** — добавили в `products_android`, а проверяете на iOS, значит его нет |
| Пакет лежит в платформенной группе, но в банк не попал | Фильтр `R.Item.CASH.equals(getInAppProductItem(item).getId())`. Для `PackPurchaseItem` берётся **первый** продукт (`getProducts().get(0)`) — если первым идёт не `CASH`, пакет отфильтруется |
| Витрина различается на Android и iOS | Ожидаемо: разные XML-группы продуктов на стор, см. раздел про два источника |
| Большой бандл продублировался в маленьких слотах | `dynamic_bank_purchases` попал в `actualInAppsProductsItems`; он должен добавляться только в общий `productItems` |
| У `BankShopItem` нет цены из стора | И не будет: это не `ProductItem`, `purchase` у него нет, в `productsMap` не попадает. Цена — `buyCash` из XML |

---

## Связанные скиллы

- `klone-offers-architecture` — система офферов (другой механизм монетизации)
- `klone-offer-pack-purchase-flow` — механизм покупки `PackPurchaseItem` в офферах
