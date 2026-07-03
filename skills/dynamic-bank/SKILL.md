---
name: dynamic-bank
description: >
  Архитектура и работа DynamicBank — банка с меняющимися офферами за реал и изумруды.
  Используй когда: понимаешь как работает банк, добавляешь/меняешь бандлы в XML,
  отлаживаешь условия показа/ротации, разбираешься с клиентским или серверным кодом банка,
  меняешь логику обновления или статистики.
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

Логика ротации стартовых наборов (`starter_bundle_cash`):
- `bundle_6` скипается, если: нет персонализации, bundle_6 уже показывался 5д, кто-то из 1-5 активен
- Перебор от 6 до 1 — первый подходящий показывается

### Слоты в `products_adjust.xml` (актуально на момент написания)

| Слот | Тип | Логика |
|------|-----|--------|
| `starter_bundle_cash` (бандлы 1-6) | CASH | Ротация по уровню + возрасту бандла + персонализации |
| `small_bundle_cash` (1-3) | CASH | Виден только когда `starter_bundle_cash` отсутствует |
| `basic_bundle_cash` (1-2) | CASH | Персонализация + уровень ≥5 |
| `super_bundle_cash` (1-3) | CASH | Персонализация + уровень |
| `giant_bundle_cash` (1-4) | CASH | Персонализация + уровень + ротация |
| `small_bundle_coins` | MONEY | Нет условий смены |
| `basic_bundle_coins` (1-3) | MONEY | `dynamicBankBundleActive` expired/showDuration P5D |
| `super_bundle_coins` (1-3) | MONEY | То же |
| `mega_bundle_coins` (1-2) | MONEY | То же |

Условие доступности всего банка: `notCondition(abTestCondition(AB_29373_MATCH3_TEST))`.

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

```
products_adjust.xml
      ↓ (parse)
DynamicBankItem (config, klone-common)
      ↓ (refillBank)
DynamicBank.currentOffers
      ↓ (DynamicBankEvent BANK_UPDATED → serialize)
DynamicBankState.setDynamicBank()
  → updateFlags() → HUD badges listeners
      ↓
DynamicBankWindowPresenter.updateModel()
  → getDynamicBundles(bankType)
      ↓
DynamicBankWindow.updateBundles()
  → BigBundleView (big bundles) + SmallBundleView (small packs)
```

---

## Быстрый справочник по файлам

```
klone-mobile-server/src/com/social/game/klonemobile/
  game/
    DynamicBank.java                     ← runtime-стейт игрока
  items/
    DynamicBankItem.java                 ← конфиг: BankSlot, BankBundle

klone-common/res/items/release/
  products_adjust.xml                    ← XML-конфиг всего банка

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

---

## Связанные скилы

- `klone-offers-architecture` — система офферов (другой механизм монетизации)
- `klone-feature-pack-purchase-flow` — механизм покупки PackPurchaseItem
- `klone-client-architecture` — общая архитектура клиента
