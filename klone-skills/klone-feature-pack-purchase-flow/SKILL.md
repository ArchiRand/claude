---
name: klone-feature-pack-purchase-flow
description: >
  Механизм покупки паков через Feature (PurchasableFeature) в klone-mobile-server.
  Используй когда работаешь с AdventPass или другими Feature, реализующими PurchasableFeature:
  регистрация PaymentProcessor, маппер FeaturePackToPaymentProcessorMapper, провайдеры
  (статический/DB/desktop), AccessProductItem, или разбираешься почему платёж за фичу
  не проходит / слот не засчитывается.
---

# Покупка паков через Feature

## Ключевые участники

| Класс | Роль |
|---|---|
| `PurchasableFeature` | Интерфейс: `hasProduct`, `buy`, `getStorageAddOrigin` |
| `FeatureContainerStorage` | StateComponent: хранит активные/завершённые `FeatureContainer`, предоставляет `findPurchasableFeatureByPack()` |
| `FeatureContainer` | Обёртка: связывает `FeatureContainerItem` + `Feature` + даты |
| `Feature` | Базовый класс фичи (abstract); `PurchasableFeature` — отдельный интерфейс |
| `AdventPassFeature` | Единственная известная реализация `PurchasableFeature` |
| `FeaturePackToPaymentProcessorMapper` | Маппер реальных платежей для `PackPurchaseItem` |
| `AccessProductToPaymentProcessorMapper` | Маппер для `AccessProductItem` (пас/подписка на фичу) |

---

## Путь 1 — Реальные деньги (`PackPurchaseItem`)

```
Платформа подтвердила платёж
    ↓
SinglePaymentManager.completePayment()
    → itemId из startedPaymentInfo
    → paymentProcessors.getPaymentPackProcessor(platform, productId, itemId)
    ↓
FeaturePackToPaymentProcessorMapper — processor function:
    1. PackPurchaseItem pack = session.getItem(itemId)
    2. FeatureContainerStorage storage = session.getGameState()
           .getContainer().getComponents().get(FEATURE_CONTAINER.name())
    3. PurchasableFeature feature = storage.findPurchasableFeatureByPack(pack)
       → если null → log.debug + return null
    4. feature.buy(session, pack)
    5. session.rewardPackPurchaseItem(pack, true, false, feature.getStorageAddOrigin())
    6. pack.inAppPurchaseId(platform)
    7. build MobilePaymentPack (extra = PaymentsUtils.SPECIAL_OFFER)
    8. session.dispatchEvent(PAYMENT_COMPLETE)
```

### Регистрация процессоров при старте

Все три провайдера используют один маппер — `FeaturePackToPaymentProcessorMapper`.

| Провайдер | Источник айтемов | Платформа |
|---|---|---|
| `PurchaseFeaturePaymentProcessorProvider` | XML, группа `FEATURES_PACKS` | `ANY` или per-platform |
| `PurchaseFeatureFromDBPaymentProcessorProvider` | `CassandraAdventPassItemProvider` (Cassandra) | `ANY` |
| `PurchaseFeaturePaymentDesktopProcessorProvider` | Тот же XML `FEATURES_PACKS`, `@Bean(testMode=true)` | `DESKTOP` |

**Статический провайдер** (`PurchaseFeaturePaymentProcessorProvider`) строит `PlatformProductItemId`:
- `Platform.ANY` + `purchase` — если поле `purchase` задано
- Per-platform — если задан список `platformPurchase`

**Динамический провайдер** (`PurchaseFeatureFromDBPaymentProcessorProvider`) расширяет
`AbstractDynamicPaymentProcessorProvider`: при каждом вызове `getPaymentProcessors()`
перечитывает DB и добавляет только **новые** процессоры (старые не удаляются).

---

## Путь 2 — `AccessProductItem` (пас/подписка на фичу)

`AccessProductItem` — отдельный тип, не `PackPurchaseItem`. Используется, например, для
покупки премиум-пропуска BattlePass (доступа к фиче), а не её контента.

```
AccessProductFromDbPaymentProcessorProvider:
    источник: CassandraRandomGiftItemProvider.allDynamicItems()
              фильтрует item instanceof AccessProductItem
    PlatformProductItemId: Platform.ANY + item.getPurchase() + item.getId()
    ↓
AccessProductToPaymentProcessorMapper — processor function:
    1. AccessProductItem productItem = session.getItem(itemId)
       → если null → session.errorWithClientAndTerminate()
    2. count = 1 (всегда для AccessProductItem)
    3. build MobilePaymentPack:
         .setProduct(productItem.getId())    ← НЕ inAppPurchaseId!
         .setExtra(item.extra ?: BATTLE_PASS)
    4. session.dispatchEvent(PAYMENT_COMPLETE)
       → слушатель настроен на productItem.getId() в BattlePass
```

> `AccessProductItem` **не вызывает** `feature.buy()` напрямую — покупка пропуска
> обрабатывается слушателем PAYMENT_COMPLETE внутри BattlePass/фичи.

---

## Путь 3 — Внутриигровая валюта (`PackShopItem`) через BuyHandler

```
BuyHandler.buyPackShop(packShopItem):
    1. isDynamicBank? → dynamicBank.buyPackShop(packShopItem)
    2. иначе:
       FeatureContainerStorage storage = CDI.getInstance(state).instance(...)
       PurchasableFeature feature = storage.findPurchasableFeatureByPack(packShopItem)
       если feature != null:
           feature.buy(session, packShopItem)
           origin = feature.getStorageAddOrigin()
       иначе:
           OfferSuper targetOffer = getBuyingOffer(packShopItem)  ← стандартный оффер-флоу
```

---

## `PurchasableFeature` — интерфейс

```java
boolean hasProduct(ProductsOwner item);     // есть ли этот пак в фиче
boolean buy(KloneSession session, ProductsOwner item);  // выполнить покупку
StorageAddOrigin getStorageAddOrigin();     // origin для rewardPackPurchaseItem
```

## `FeatureContainerStorage.findPurchasableFeatureByPack()`

Ищет во **всех контейнерах** (активных + завершённых):
```java
containers.stream()
    .map(FeatureContainer::getFeature)
    .filter(f -> f instanceof PurchasableFeature)
    .filter(f -> ((PurchasableFeature) f).hasProduct(productsOwner))
    .findFirst()
```

> Ищет и в `finishedContainers` — платёж может прийти после завершения фичи по времени.

---

## `AdventPassFeature` — реализация `PurchasableFeature`

```java
// hasProduct: есть ли слот с этим паком
getSlotByPack(item) → slots.stream().filter(slot.getPack().equals(item)).findFirst()

// buy: засчитать слот
picked.add(pickedSlot.getId())  // список взятых слотов

// getStorageAddOrigin
return StorageAddOrigin.ADVENT_PASS
```

---

## `extra`-тег в `MobilePaymentPack`

| Путь | `extra` |
|---|---|
| `FeaturePackToPaymentProcessorMapper` | всегда `PaymentsUtils.SPECIAL_OFFER` |
| `AccessProductToPaymentProcessorMapper` | `item.getExtra()` если задан, иначе `BATTLE_PASS` |

---

## Ловушки

| Проблема | Правильно |
|---|---|
| Новый `PackPurchaseItem` в фиче, платёж не проходит | Проверь: пак в группе `FEATURES_PACKS` или в `CassandraAdventPassItemProvider`; `purchase` задан |
| `findPurchasableFeatureByPack` возвращает null | Фича не реализует `PurchasableFeature`, или `hasProduct()` не матчит айтем |
| `AccessProductItem` — `product` в MobilePaymentPack не тот | Для AccessProduct `product = item.getId()`, не `inAppPurchaseId` |
| `PurchaseFeatureFromDBPaymentProcessorProvider` не добавляет новый процессор | `AbstractDynamicPaymentProcessorProvider` добавляет только новые (не пересоздаёт старые) — перезапуск сервера решит |
| Покупка PackShopItem через фичу не проходит в BuyHandler | Проверь что нет `isDynamicBank` ветки выше; фича должна быть в `startedContainers` или `finishedContainers` |
| `feature.buy()` возвращает false | Слот уже в `picked` — повторная покупка |

---

## Файлы

```
klone-mobile-server/src/com/social/game/klonemobile/
  game/feature/container/
    Feature.java                        ← базовый abstract класс фичи
    PurchasableFeature.java             ← интерфейс: hasProduct / buy / getStorageAddOrigin
    FeatureContainer.java               ← обёртка: item + feature + даты
    FeatureContainerStorage.java        ← StateComponent; findPurchasableFeatureByPack()
  game/feature/pass/
    AdventPassFeature.java              ← единственная реализация PurchasableFeature
  offers/mapper/
    FeaturePackToPaymentProcessorMapper.java   ← PackPurchaseItem → buy + reward
    AccessProductToPaymentProcessorMapper.java ← AccessProductItem → PAYMENT_COMPLETE
  offers/provider/
    CassandraAdventPassItemProvider.java       ← динамические айтемы AdventPass из DB
  payments/
    AbstractDynamicPaymentProcessorProvider.java        ← базовый класс динамических провайдеров
    PurchaseFeaturePaymentProcessorProvider.java        ← статический (XML FEATURES_PACKS)
    PurchaseFeatureFromDBPaymentProcessorProvider.java  ← динамический (Cassandra)
    PurchaseFeaturePaymentDesktopProcessorProvider.java ← desktop-only (testMode)
    AccessProductFromDbPaymentProcessorProvider.java    ← AccessProductItem из Cassandra
  gamestate/helpers/
    BuyHandler.java                     ← PackShopItem → feature.buy() или оффер-флоу
```

---

## Связанные скиллы

- `klone-offer-pack-purchase-flow` — покупка паков в офферах (PackPurchaseItem / PackShopItem)
- `klone-offers-architecture` — архитектура офферов, жизненный цикл OfferSuper
- `klone-client-pricing-sync` — актуализация цен и валют на клиенте
- `battlepass-energypass` — BattlePass/EnergyPass: стадии, слоты, AccessProductItem
