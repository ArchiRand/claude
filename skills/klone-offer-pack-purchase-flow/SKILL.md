---
name: klone-offer-pack-purchase-flow
description: >
  Механизм покупки паков в офферах klone-mobile-server. Используй когда работаешь
  с PackPurchaseItem, PackShopItem, платёжными процессорами, BuyHandler,
  OfferPaymentProcessorsProvider или разбираешься почему платёж из оффера не проходит / пак
  не выдаётся.
---

# Покупка пака из оффера

## Два типа паков

| Класс | XML/JSON | Родитель | Оплата |
|---|---|---|---|
| `PackPurchaseItem` | `packPurchase` | `ProductItem` | Реальные деньги (in-app) |
| `PackShopItem` | `packShop` | `ShopItem` | Внутриигровая валюта / бесплатно / токены |

> `SubscriptionPurchaseItem` (extends `PackPurchaseItem`) — **только для подписок, не для офферов**.

**Общее для обоих:**
- `products: List<CountedItem>` **или** `productGroups: List<ProductGroup>` — взаимоисключающие
- `getProducts()` всегда возвращает плоский список `CountedItem`
- `PackShopItem.getPurchase()` → всегда `null`; помечен `@ItemType(ItemType.Type.PACK_SHOP)`

### Варианты стоимости PackShopItem

`PackShopItem` наследует от `ShopItem`, который определяет способ оплаты. **Только один** из вариантов может быть задан — `postConstruct` бросает исключение при нескольких.

| Вариант | Поле | Описание |
|---|---|---|
| Внутриигровая валюта | `buyCoins: Integer` | Цена в монетах |
| Реальные деньги (cash) | `buyCash` (в `ShopItem`) | Цена в валюте сети |
| Токены | `buyItems: List<CountedItem>` | Один `<buyItem item="TOKEN_ID" count="N"/>` |
| Бесплатный пак | `free: Boolean = true` | Забрать бесплатно |

**Бесплатный пак** (`free=true`): игрок забирает пак без списания чего-либо.

**Пак за токены** (`buyItems`): стоимость — один айтем-токен (`buyItems.size()` должен быть равен 1, иначе postConstruct упадёт из-за `countOfBuyItem > 1`).

```xml
<!-- Бесплатный пак -->
<packShop id="offer_free_pack" free="true" shopImage="img.png">
    <product count="100" item="ENERGY"/>
</packShop>

<!-- Пак за токены -->
<packShop id="offer_token_pack" shopImage="img.png">
    <buyItem item="LUCKY_CHEST_TOKEN" count="3"/>
    <product count="500" item="ENERGY"/>
</packShop>
```

---

## Путь 1 — Реальные деньги (`PackPurchaseItem`)

```
Платформа подтвердила платёж
    ↓
SinglePaymentManager.completePayment()
    → startedPaymentInfo.itemId
    → paymentProcessors.getPaymentPackProcessor(platform, productId, itemId)
    ↓
PackPurchaseToPaymentProcessorMapper — processor function:
    1. PackPurchaseItem pack = getItemById(itemId)
    2. session.rewardPackPurchaseItem(pack, true, false, StorageAddOrigin.OFFER)
    3. OfferSuper offer = getBuyingOffer(pack)   // ищет оффер, у которого пак ещё не в purchased
    4. offers.finish(offer, pack)
    5. pack.inAppPurchaseId(platform)
    6. build MobilePaymentPack + dispatch PAYMENT_COMPLETE
```

### Регистрация процессоров при старте

`OfferPaymentProcessorsProvider` (`@Bean(scope=SINGLETON)`) в конструкторе:
- Сканирует все версии айтемов, собирает все `PackPurchaseItem` из всех `OfferItem`
- **Исключение:** `PaymentsRewardOfferItem` — не сканируется (его паки не покупаются напрямую)
- Для каждого пака создаёт `PlatformProductItemId`:
  - `Platform.ANY` — если задан `purchase`
  - Per-platform — если `platformPurchase` список не пуст

---

## Путь 2 — Внутриигровая валюта (`PackShopItem`)

```
BuyHandler.buyPackShop(packShopItem):
    1. DynamicBank? → проверяем
    2. FeatureContainerStorage? → проверяем
    3. getBuyingOffer(packShopItem)
       если null && нет update-event в очереди → ProductUnavailableException
    4. offers.finish(targetOffer, packShopItem)
    5. для каждого product в packShopItem.getProducts():
         addPrizeGift(product)
         исключение: AtomicBombItem → идёт в storage, не в gifts
    6. origin = PaymentsRewardOfferSuper? → StorageAddOrigin.PAYMENTS_REWARD_OFFER
```

Диспатч в `BuyHandler` — по аннотации `@ItemType(ItemType.Type.PACK_SHOP)` на классе.

---

## ProductItem — ключевые поля

| Поле | Тип | Описание |
|---|---|---|
| `priceString` | String | Цена в долларах (`"0.99"`). Берётся из `PurchasePricesItem` по `purchase`-ID |
| `priceAmount` | Integer | `priceString × 100` (1$ = 100). Заполняется в `@XStreamPostConstruct` |
| `purchase` | String | In-app purchase ID (основной) |
| `platformPurchase` | List | Per-platform IDs → строится `purchaseMap` в postConstruct |
| `webProduct` | Boolean | Флаг альтернативной платёжки на Android |

```java
// Резолвинг in-app ID по платформе:
pack.inAppPurchaseId(platform)
    → purchaseMap.get(platform) если есть
    → purchase если задан
    → getId()  // fallback: ID айтема = ID в консоли платформы
```

---

## `extra`-тег для статистики

Приоритет в `getExtraFromPack()` (`PackPurchaseToPaymentProcessorMapper`):

1. Собственный `extra` пака (поле `PackPurchaseItem.extra`)
2. `MONEY_BOX` если `isMoneyBox()`
3. `SPECIAL_OFFER` если оффер — глобальный
4. `offerSuper.getExtra()` если задан
5. `OFFER` — дефолт

---

## Ловушки

| Проблема | Правильно |
|---|---|
| `PackShopItem` extends `ProductItem` | Нет — extends `ShopItem`. `getPurchase()` всегда null |
| `products` и `productGroups` вместе | `@XStreamPostConstruct` бросает исключение — только одно |
| Новый `PackPurchaseItem`, платёж не проходит | `OfferPaymentProcessorsProvider` не нашёл пак — проверь что оффер не `PaymentsRewardOfferItem` и purchase задан |
| `PackPurchaseItem` в `PaymentsRewardOfferItem` | Исключён из `OfferPaymentProcessorsProvider` намеренно — не покупается напрямую |
| `offers.finish()` без `getBuyingOffer()` | `getBuyingOffer` ищет нужный оффер по паку; без него не знаем какой оффер завершать |
| `SubscriptionPurchaseItem` в оффере | Подписки в офферах не продаются — только отдельным механизмом |

---

## Файлы

```
klone-mobile-server/src/com/social/game/klonemobile/
  items/
    ProductItem.java                       ← базовый класс реальных продуктов
    PackPurchaseItem.java                  ← пак за реальные деньги
    PackShopItem.java                      ← пак за внутриигровую валюту
    SubscriptionPurchaseItem.java          ← подписка (extends PackPurchaseItem, не для офферов)
  payments/
    OfferPaymentProcessorsProvider.java    ← регистрация процессоров при старте
  offers/mapper/
    PackPurchaseToPaymentProcessorMapper.java  ← маппер платёж → reward + finish
  gamestate/helpers/
    BuyHandler.java                        ← покупка за внутриигровую валюту
server-framework/.../payments/
  SinglePaymentManager.java               ← точка входа реального платежа
```

---

## Связанные скиллы

- `klone-offers-architecture` — архитектура офферов, жизненный цикл, иерархия классов
- `klone-client-pricing-sync` — актуализация цен и валют на мобильном клиенте. Не актуально для вебшопа
- `webshop-controller-chains` — цепочки вызовов в вебшопе, авторизация, платёж
