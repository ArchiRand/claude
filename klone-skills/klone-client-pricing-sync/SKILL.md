---
name: klone-client-pricing-sync
description: >
  Клиентский механизм патчинга цен и валют в klone (ProductsState, SyncOperation, ProductFiller).
  Используй когда работаешь с ценами продуктов на клиенте: почему цена не обновляется,
  как добавить новый тип ProductItem в биллинг, RU-регион vs стор, handleNewProductItems
  для динамических айтемов (офферы, фичи).
---

# Клиентский патчинг цен

## Поля `ProductItem` и их жизненный цикл

| Поле | Откуда | Изменяется |
|---|---|---|
| `priceString` | XML (`"0.99"`) | Нет |
| `priceStringRu` | XML (рублёвая цена) | Нет |
| `priceAmount` | `postConstruct`: `priceString × 100` | Да — `SyncOperation` патчит |
| `originalPriceAmount` | `postConstruct`: то же значение | **Никогда** — эталон для desktop-fallback |
| `purchase` | XML / `actualizePurchases()` | Да — патчится под платформу |
| `currencyCode` | — | `SyncOperation` |
| `currencySymbol` | XML | `DefaultProductFiller` сбрасывает в `""` |
| `localeIdentifier` | XML | `DefaultProductFiller` |
| `originalJSON` | — | `DefaultProductFiller` |
| `verified` | — | `true` если `currencyCode` не пуст |

---

## Шаг 1 — Сбор всех `ProductItem` (`ProductsState` конструктор)

```
ProductsState(items):
    offersProductsItems  ← group_offer_product_items (XML)
                         + DynamicOffersService.getOffersPackPurchases()
    dynamicAccessProductItems ← DynamicOffersService.getItems() → filter AccessProductItem
    subscriptionPurchaseItems ← subscriptions_group
    actualInAppsProductsItems ← purchases_group

    productItems (LinkedHashSet, без дубликатов):
        + actualInAppsProductsItems
        + offersProductsItems
        + subscriptionPurchaseItems
        + dynamicAccessProductItems
        + access_products group
        + dynamic_bank_purchases group
        + other_offers group

    featuresProductsItems ← feature_packs group (XML)
                          + DynamicOffersService.getAdventPassPackPurchases()
    productItems += featuresProductsItems
    productItems += purchases_group_archive

    actualizePurchases(productItems)
```

> `LinkedHashSet` гарантирует отсутствие дублей при добавлении одного `ProductItem`
> в несколько списков.

---

## Шаг 2 — `actualizePurchases()`

1. Для `PackPurchaseItem` у которых `purchase == null` но `platformPurchase` не пуст:
   - ищет запись для текущей платформы (`R.Config.platform()`)
   - если нашёл — **патчит** `productItem.setPurchase(purchase)`
2. Строит `productsMap`: `purchase → List<ProductItem>`.
   - Один `purchase`-ID может соответствовать нескольким `ProductItem`

---

## Шаг 3 — `SyncOperation.execute()` (полная синхронизация)

Вызывается через `Billing.syncInAppDetails(productsState)`.

### RU-регион (`isRuRegion()` = true)

> RU-регион: `platformType == RuStore` или `R.Config.ru_build() == true`

```
для каждого entry в productsMap:
    строим ProductDetails вручную из productItem.priceStringRu:
        price        = priceStringRu
        priceAmount  = Float.parseFloat(priceStringRu) * 100
        currencyCode = "RUB"
        priceMicros  = priceAmount * 10000
    productsState.addProductDetails(purchaseId, productDetails)
    RuProductFiller.fillProductItem(productItem, productDetails)
        → verified = true
        → priceAmount = productDetails.getPriceAmount()
        → currencyCode = "RUB"
```

### Не-RU (стор)

```
billing.inAppsDetails()  → список ProductDetails от маркета
для каждого ProductDetails:
    productItemList = productsState.getProducts(productDetails.getProductId())
    для каждого ProductItem:
        DefaultProductFiller.fillProductItem(productItem, productDetails)
        productsState.addProductDetails(purchaseId, productDetails)
```

**`DefaultProductFiller`:**
```
currencySymbol = ""
priceAmount = priceMicros / 10000
    если priceAmount == 0 (desktop — маркет не вернул цену):
        priceAmount = originalPriceAmount * 1.1   ← имитация НДС
currencyCode = productDetails.priceCurrencyCode
localeIdentifier = productDetails.localeIdentifier
originalJSON = productDetails.data
verified = !isEmpty(currencyCode)
```

---

## Шаг 4 — `handleNewProductItems()` (динамические айтемы)

Вызывается при получении `ItemSyncEvent` с новыми айтемами (офферы, фичи).

```
handleNewProductItems(items):
    selectProductItems(productItems, items, ProductItem.class)
    если productItems пуст → return

    actualizePurchases(productItems)   ← добавляем в productsMap

    // Тип верхнеуровневого айтема определяет список:
    если items[0] instanceof OfferItem       → offersProductsItems.addAll(productItems)
    если items[0] instanceof FeatureContainerItem → featuresProductsItems.addAll(productItems)

    ProductFiller filler = isRuRegion() ? RuProductFiller : DefaultProductFiller
    для каждого productItem:
        productDetails = getProductDetails(productItem.getPurchase())
        если productDetails == null:
            // Маловероятный кейс — продукт ещё не синхронизировался
            billing.syncInAppDetails(this)   ← повторная полная синхронизация
            return
        filler.fillProductItem(productItem, productDetails)
```

> **Важно:** `ItemSyncEvent` несёт **либо** офферы **либо** feature-паки — никогда оба сразу.
> Тип определяется первым верхнеуровневым айтемом списка.

---

## `DynamicOffersService` — кеш динамических айтемов

Статический singleton-кеш (key: itemId). Заполняется при получении динамических айтемов с сервера.

| Метод | Возвращает |
|---|---|
| `getOffersPackPurchases()` | `PackPurchaseItem`-и внутри `OfferItem`-ов |
| `getAdventPassPackPurchases()` | `PackPurchaseItem`-и внутри слотов `AdventPassFeatureItem` |
| `getItems()` | все айтемы (используется для фильтрации `AccessProductItem`) |

---

## Как добавить новый тип `ProductItem` в биллинг

1. **Если айтемы идут из XML**: добавь группу в нужный `selectProductItems` вызов в конструкторе `ProductsState`
2. **Если айтемы динамические**:
   - Убедись, что они попадают в `DynamicOffersService` через `putAll()`
   - В `ProductsState` конструкторе добавь `selectProductItems(..., DynamicOffersService.getItems(), ...)` с нужной фильтрацией
   - Либо добавь отдельный метод в `DynamicOffersService` (по аналогии с `getAdventPassPackPurchases`)
3. **Если это `FeatureContainerItem`-based**: добавь в `featuresProductsItems` — тогда `handleNewProductItems` правильно распределит по списку

---

## Ловушки

| Проблема | Причина |
|---|---|
| Цена не обновляется после синхронизации | `purchase`-ID в `productItem` не совпадает с ключом в `productsMap`; проверь `actualizePurchases` |
| `verified = false` | `DefaultProductFiller` не получил `currencyCode` от стора; проверь ответ `inAppsDetails()` |
| Desktop показывает завышенную цену | Намеренно: `originalPriceAmount * 1.1` (имитация НДС) |
| Динамический айтем не попал в биллинг | Не добавлен в `DynamicOffersService` или не вызван `handleNewProductItems` |
| Новый `PackPurchaseItem` из фичи не синхронизируется | Нет в `feature_packs` группе и не добавлен через `DynamicOffersService.getAdventPassPackPurchases()` |
| RU-регион: `priceAmount` неправильный | `priceStringRu` не задана в XML — `Float.parseFloat(null)` упадёт |

---

## Файлы

```
klone/src/com/vizor/klone/
  billing/
    ProductsState.java              ← сбор всех ProductItem, productsMap, handleNewProductItems
    SyncOperation.java              ← полная синхронизация цен со стором / RU-логика
    Billing.java                    ← isRuRegion(), syncInAppDetails(), DEFAULT_RU_CURRENCY_CODE="RUB"
    product/
      ProductFiller.java            ← интерфейс стратегии патчинга
      DefaultProductFiller.java     ← non-RU: priceMicros/10000, desktop fallback *1.1
      RuProductFiller.java          ← RU: priceStringRu*100, currencyCode="RUB"
  common/items/
    DynamicOffersService.java       ← статический кеш динамических айтемов

klone-mobile-server/src/com/social/game/klonemobile/items/
  ProductItem.java                  ← priceString/priceAmount/originalPriceAmount/purchaseMap
```

---

## Связанные скиллы

- `klone-offer-pack-purchase-flow` — регистрация и покупка `PackPurchaseItem` в офферах
- `klone-feature-pack-purchase-flow` — покупка через Feature/AdventPass
