---
name: klone-offers-architecture
description: >
  Архитектура системы офферов в klone-mobile-server. Используй когда работаешь
  с OfferItem/OfferSuper и их наследниками: понять как работает конкретный тип оффера,
  добавить новый тип, отладить жизненный цикл, разобраться в иерархии классов.
  Для интеграции оффера в вебшоп — см. naslednik-offera-v-webshop.
---

# Архитектура офферов klone-mobile

## Главный принцип: два класса на один оффер

| Класс | Пакет | Назначение |
|---|---|---|
| `OfferItem` (наследник) | `items/` | Конфиг из XML. Неизменяемый. |
| `OfferSuper` (наследник) | `mission/` или `game/` | Runtime-объект в стейте игрока. Хранит состояние. |

Связка: `OfferItem.createOffer(session)` возвращает нужный `OfferSuper`.  
Менеджер всего: `KloneOffers` в `KloneGameState` — хранит `list: List<OfferSuper>`.

---

## Иерархия OfferItem → OfferSuper

```
OfferItem
├── InfiniteOfferItem          → InfiniteOffer
│   Каждый пак покупается N раз (limits[]). Опциональный progressBar.
│
├── OfferTransformerItem       → OfferTransformer
│   N попыток старта → если не куплен, запускает next-оффер.
│   Старт только через event-listeners (showConditions), НЕ через start().
│
├── MoneyBoxOfferItem          → MoneyBoxOfferSuper
│   Копилка: наполняется через USE_ENERGY события (collectionPercent %).
│
├── OfferScoredItem            → OfferSuperScored
│   Призы по весу (Prize.weight). pickPrize(i) — забрать приз.
│
├── PaymentsRewardOfferItem    → PaymentsRewardOfferSuper
│   Награда за N реальных платежей. Слушает REAL_PAYMENT_COMPLETE.
│
├── SequencedMoneyBoxOfferItem → SequencedMoneyBoxOfferSuper
│   Несколько копилок последовательно, у каждой свой пак.
│
├── WindowDispenserOfferItem   → WindowDispenserOfferSuper
│   При покупке добавляет WindowDispenser в gameState.
│
├── MoneyBoxPromoItem          → MoneyBoxPromoOfferSuper  extends BaseMoneyBoxOffer
│   Акция-контейнер копилок (MoneyBoxItem[]). Стартует по dateRange.
│   Одновременно активна 1 копилка. @WebShop.SupportedType.
│
└── MoneyBoxSetItem            → MoneyBoxSet  extends BaseMoneyBoxOffer
    Ровно 3 копилки, активны одновременно. Покупка каждой отдельно
    или всех сразу через packPurchase.
```

`BaseMoneyBoxOffer` (abstract, extends OfferSuper) — базовый класс для новых копилок.  
Шаблонный метод: `initialize()`, `starting()`, `expiring()`, `buying(packIndex)`.

---

## Жизненный цикл OfferSuper

```
createOffer(session)        ← фабрика в OfferItem
    ↓
init(session)               ← инициализация: таймер, tasks, условия старта
    ↓
start() / start(endDate)    ← активация: attempt++, startsCount++, таймер истечения
    ↓
finish(index)               ← покупка пака, статистика, призы
    ↓
finishOffer(index)          ← finished=true, finishDate
    или
expireOffer()               ← disabled=true (по таймеру)
```

**Ключевые поля состояния:**
- `purchased: List<String>` — id купленных паков
- `attempt` — количество запусков (старт оффера)
- `startsCount` — то же, но не сбрасывается через `resetAttempt()`
- `disabled` / `finished` — взаимоисключающие финальные состояния
- `endDate` — вычисляется в `setEndDate()` из duration / dateRange / endByDateRange

**`isActive()` = !disabled && !finished && !isExpired()**

---

## KloneOffers — менеджер офферов

```
klone-mobile-server/src/.../KloneOffers.java
```

| Метод | Что делает |
|---|---|
| `onOwnerAccessStart()` | Инит активных офферов + tryStart при получении стартового пакета |
| `initActiveOffers()` | Проходит по products_offers, создаёт/инитит/стартует |
| `tryStartOfferNodePayer()` | Обходит ноды (NODE_PAYER → условные → next) |
| `initOfferContainer()` | Инит офферов из OfferContainerItem (dateRange / conditions) |
| `createOrGet()` | Создать новый OfferSuper или вернуть существующий из стейта |
| `addOffer()` | Создать + добавить в list + init |
| `getOffer(item)` | Найти runtime-объект по OfferItem |
| `finish(offer, packItem)` | Завершить покупку пака + ивент клиенту |
| `getBuyingOffer(packItem)` | Найти оффер, в котором пак ещё не куплен |

**Два источника запуска:**
1. **OfferNode** (`NODE_PAYER`) — цепочка нод с условиями и repeat
2. **OfferContainer** (`offer_containers_group`) — по dateRange или условиям в рантайме

---

## OfferContainerItem — контейнер офферов

Описывается в `products.xml`, группа `offer_containers_group`. Запускает один или несколько офферов по условиям или датам.

### Офферы в контейнере

| Поле | Тип | Описание |
|---|---|---|
| `offerItems` | `List<OfferItem>` | Офферы без AB-теста. Инициализируются первыми |
| `offerContainerABTests` | `List<ABTest>` | AB-тесты. `ABTest` содержит `subGroup[]`, каждая с `percent` и списком `OfferItem` |

`getOffers()` возвращает плоский список всех офферов (из обоих источников).

### Ключевые флаги

| Поле | По умолчанию | Описание |
|---|---|---|
| `singleActiveOffer` | false | Не инициализировать контейнер, если оффер из его списка уже активен |
| `multiExecution` | false | Разрешить повторную инициализацию, даже если контейнер уже был в стейте |
| `offerContainerEndDate` | false | Запущенному офферу выставить `endDate` = endDate dateRange контейнера |
| `isOnlineContainer` | auto | `true` если хоть одно условие с `needListener=true` — может инициализироваться в рантайме |

### Условия запуска

`allConditions: List<AbstractGameStateCondition>` — все условия должны выполниться.  
`getDateRangeCondition()` — достаёт `DateRangeCondition` из `allConditions`.  
`getDateRange()` — делегирует в `DateRangeCondition` (или `null`).

### Ограничения (postConstruct бросает исключение)

| Ситуация | Почему запрещено |
|---|---|
| `offerItems` и `abTest` оба пустые | Нечего запускать |
| `multiExecution=true` + `DateRangeCondition` | Контейнер и так запустится по дате при старте сессии |
| Оффер внутри контейнера имеет собственный `dateRange` | Исключения: `OfferTransformerItem` и `MoneyBoxesOwner` |
| `offerContainerEndDate=true` без `DateRangeCondition` | Нет источника endDate |

### `extra` поле

`OfferContainerItem.extra` используется для статистики при покупке оффера. Имеет меньший приоритет, чем `extra` самого пака, но больший, чем дефолтный `OFFER`.

---

### Механизм запуска (KloneOffers)

**Три триггера запуска контейнера:**

| Триггер | Метод | Когда |
|---|---|---|
| `ORIGIN_DATE_RANGE` | `initOfferContainerByDateRange()` | Старт сессии: dateRange активен или ставит таймер на будущее |
| `ORIGIN_CONDITION_TRIGGER` | `initOnlineContainerListeners()` | Рантайм: `isOnlineContainer=true`, подписка на `OnlineGameStateCondition` |
| `ORIGIN_LOCATION_TRIGGER` | `tryToInitOfferContainer(id, extra)` | Внешний вызов: объект с атрибутом `offerContainer` появился на локации |

**Алгоритм `initOfferContainer()` — шаг за шагом:**

```
1. executedOfferContainers.containsKey(id) && !multiExecution → return (уже запускался)
2. singleActiveOffer && isActiveOfferFromContainer() → return (уже есть активный оффер)
3. !hasCondition() || !getConditionResult(session) → return (условия не выполнены)
4. executedOfferContainers.put(id, now)  ← отмечаем как запущенный
5. Перебираем offerItems (без AB):
     первый offerItem.isAvailableFor(session) → createOrGet() + startOfferFromContainer() → return
6. Перебираем abTests:
     a. уже выполнялся → берём сохранённую subGroup из executedABTests
     b. новый && abTest.isActualABTest() → случайный выбор subGroup по percent
        → executedABTests.put(abTest.id, subGroup.id) + dispatch RESOLVE_AB_TEST
     первый доступный offerItem из subGroup → createOrGet() + startOfferFromContainer() → return
```

**Важно:** за один вызов `initOfferContainer` стартует ровно **один** оффер — сразу `return` после первого успешного запуска.

**AB-тест:** выбранная подгруппа сохраняется в `executedABTests`. При повторном вызове (только если `multiExecution=true`) — та же подгруппа, без перебрасывания.

**`startOfferFromContainer()`:**
- `offerContainerEndDate=true` → `offer.start(container.dateRange.endDate)`
- иначе → `offer.start()`

**`canExecuteOfferContainer()`:** `!executedOfferContainers.containsKey(id) || multiExecution`  
Используется при инициализации online-слушателей — не подписываемся на уже исчерпанные контейнеры.

---

## Добавление нового типа оффера

### 1. Item-класс (конфиг из XML)

```java
@JsonTypeName("myOffer")
@XStreamAlias("myOffer")
@ModelGenIdentify
public class MyOfferItem extends OfferItem {

    @XStreamAsAttribute
    @Getter
    private int myParam;

    @Override
    public MyOfferSuper createOffer(KloneSession session) {
        return new MyOfferSuper(this);
    }

    @XStreamPostConstruct
    private void postConstruct() {
        if (myParam <= 0) {
            throw new PostConstructException("myParam must be positive. Offer {}", getId());
        }
    }
}
```

### 2. State-класс (runtime)

```java
@NoArgsConstructor(access = AccessLevel.PROTECTED)
@JsonTypeInfo(use = JsonTypeInfo.Id.NAME, property = "type")
@JsonTypeName("myOffer")
@ModelNeedTypeInfo
@ModelTypeName(property = "type")
@Slf4j
public class MyOfferSuper extends OfferSuper {

    @Getter
    private int myRuntimeField;

    public MyOfferSuper(MyOfferItem item) {
        super(item);
    }

    @Override
    public void init(KloneSession session) {
        super.init(session);
        // доп. инициализация
    }

    @Override
    public void start() {
        super.start();
        myRuntimeField = 0;
        // подписка на события
    }

    @Override
    public void finish(int index) {
        super.finish(index);
        // кастомная логика после покупки
    }

    @Override
    public MyOfferItem getItem() {
        return (MyOfferItem) item;
    }

    @Override
    public String getOfferType() {
        return "my_offer_type"; // для статистики
    }
}
```

---

## Частые ошибки и ловушки

| Проблема | Правильно |
|---|---|
| Вызов `start()` напрямую на `OfferTransformer` | `start()` переопределён пустым методом. Старт только через `tryToStartOffer()` внутри |
| `purchased` очищается при выдаче prize за все паки | В `sendGiftForAllPacksPurchase()` — намеренно, для повторного завершения |
| `attempt` vs `startsCount` путаница | `attempt` сбрасывается `resetAttempt()`, `startsCount` — никогда |
| `InfiniteOffer`: `purchased` ≠ "куплен пак" | В `purchasedPacks` кладётся каждая покупка; в `purchased` — только при исчерпании лимита |
| `endDate` null при isOneChanceOffer | `setEndDate()` ранний return. `isExpired()` возвращает `true` сразу |
| `BaseMoneyBoxOffer.finish()` делегирует в `buying()` | Не переопределяй `finish()` в наследниках BaseMoneyBoxOffer — переопределяй `buying()` |
| `MoneyBoxPromoItem.getItems()` возвращает packPurchase каждой копилки | Не путать с `getMoneyBoxesItems()` (сами MoneyBoxItem) |

---

## Покупка пака из оффера

Паки бывают двух типов: `PackPurchaseItem` (реальные деньги) и `PackShopItem` (внутриигровая валюта).  
**`SubscriptionPurchaseItem` в офферах не используется** — подписки продаются отдельным механизмом.

Полная документация: скилл `klone-pack-purchase-flow`.

---

## Быстрый справочник по файлам

```
klone-mobile-server/src/com/social/game/klonemobile/
  items/
    OfferItem.java                    ← базовый Item-класс
    OfferContainerItem.java           ← контейнер офферов (offer_containers_group)
    InfiniteOfferItem.java
    OfferTransformerItem.java
    MoneyBoxOfferItem.java
    OfferScoredItem.java
    PaymentsRewardOfferItem.java
    SequencedMoneyBoxOfferItem.java
    WindowDispenserOfferItem.java
    moneybox/
      MoneyBoxPromoItem.java
      MoneyBoxSetItem.java
  mission/
    OfferSuper.java                   ← базовый runtime-класс
    InfiniteOffer.java
    OfferTransformer.java
    MoneyBoxOfferSuper.java
    OfferSuperScored.java
    SequencedMoneyBoxOfferSuper.java
    WindowDispenserOfferSuper.java
  game/
    PaymentsRewardOfferSuper.java
    moneybox/
      BaseMoneyBoxOffer.java          ← abstract, шаблонный метод
      MoneyBoxPromoOfferSuper.java
      MoneyBoxSet.java
  KloneOffers.java                   ← менеджер всех офферов игрока
```

---

## Связанные скиллы

- `klone-pack-purchase-flow` — механизм покупки паков (PackPurchaseItem, PackShopItem, платёжные процессоры)
- `naslednik-offera-v-webshop` — интеграция оффера в вебшоп
- `naslednik-offera-v-tyly` — интеграция оффера в тулу монетизации
- `webshop-controller-chains` — цепочки вызовов, авторизация, платёж
