---
name: webshop-controller-chains
description: Детальные цепочки вызовов WebShopController: getProductOffers, getProductForCheckout, processPaymentNotification, claimFreeItem. Входные/выходные данные, блокировки, авторизация, провайдеры офферов, EventBuffering, extension points. Используй при дебаге, добавлении поля в ответ, изменении валидации или трассировке платежа в WebShop.
---

# WebShop Controller Chains

## Базовый путь
`/api/external/webshop/v1/users/{userId}/...`

**Файлы:**
- Контроллер: `external/webshop/api/WebShopController.java`
- Singleton-сервис: `external/webshop/service/impl/WebShopProductOfferServiceImpl.java`
- CDI-сервис: `external/webshop/service/impl/SessionWebShopProductOfferService.java`
- Провайдер: `external/webshop/provider/offer/impl/CommonWebShopOfferProvider.java`

---

## Слои и ответственность

```
WebShopController                 ← REST, авторизация, обработка исключений
        │ redirectedExecutor.executeOnSessionOwner()
        │   (проверяет сервер пользователя, при необходимости редиректит на другой узел)
WebShopProductOfferServiceImpl    ← Singleton; SessionSemaphore + получение KloneSession
        │ CDI.getInstance(session).instance(WebShopProductOfferService.class)
SessionWebShopProductOfferService ← @Component per-session; вся бизнес-логика
        │
WebShopOfferProvider / validators / mappers / EventBuffering
```

**Критично:** Вся бизнес-логика — в `SessionWebShopProductOfferService`. `WebShopProductOfferServiceImpl` — тонкий роутер.

---

## Авторизация

| Тип запроса | Аннотация | Заголовок | Секрет |
|---|---|---|---|
| GET (read-only) | `@BearerAuthorization` | `Authorization: Bearer {token}` | `webshop.bearer.token` |
| POST (мутации) | `@SignatureAuthorization(STRATEGY_NAME)` | `X-Game-Server-Signature` + `X-Game-Server-Signature-Timestamp` | `webshop.signature.key` |

**HMAC формула:** `HMAC-SHA256(key, timestamp + "." + body)`
**Временное окно:** текущее время ± 5 минут

---

## Блокировки

Два уровня блокировки для POST-запросов:
1. `ThreadMarkerSemaphore(userId)` — в контроллере через `createProductResponse()`; один поток на userId
2. `SessionSemaphore` — в `WebShopProductOfferServiceImpl`; гарантирует атомарность получения сессии

Для GET — только `SessionSemaphore`.

---

## ENDPOINT 1: getProductOffers

```
GET /{userId}/offers/{language}
```

**Вход:** `userId`, `language` (default "en"), Bearer token

**Цепочка:**
```
WebShopController.getProductOffers()
  → createResponse(() → redirectedExecutor.executeOnSessionOwner())
  → WebShopProductOfferServiceImpl.getProductOffers(userId, language)
      SessionSemaphore.lock()
      KloneSession session = sessionProvider.getSession(userId)
      CDI.getInstance(session).instance(SessionWebShopProductOfferService.class)
        .getProductOffers(language)
  → SessionWebShopProductOfferService.getProductOffers()
      1. session.dispatchEvent(WEB_SHOP_OFFERS_REQUEST)  ← WebShopExecutable хуки
      2. cdi.instance(WebShopOfferProvider.class).offers()  ← все офферы
      3. .sorted(by hudPriority)
      4. .map(offer → new CDIRecord<>(offer, cdi))
      5. .map(productOfferMapper::convertFrom)  ← WebShopSellableOfferToProductOfferMapper
      6. TranslatableModelMapper.translate(productOffer, language)
      7. return List<ProductOffer>
```

**Провайдеры офферов (CommonWebShopOfferProvider.offers()):**
```
CommonWebShopOfferProvider
  ├── WebShopXmlOfferProvider       ← OfferItem из XML, группа "webshop_visible"
  ├── KloneOfferWebShopOfferProvider ← OfferSuper из state (активные офферы)
  │     фильтр: isSupportedType() → @WebShop.SupportedType на Item-классе
  │     фильтр: offer.isSupported(cdi)
  │     transform: adapter.webShopOffer(cdi)
  │       → WebShopStrategyAdapterConfiguratorHandler.handle(data, adapter, cdi)
  │       → все WebShopStrategyConfigurator.canBeApply() + configure()
  └── BattlePassAsWebshopOfferProvider ← BattlePass из Adventure (если версия ≥ 2.149)
```

**Структура ProductOffer (ответ):**
```
id, offerType (bank|infinite|battle_pass|energy_pass|...), productSlotCount,
sequential, overall, name (переводимое), imageUrl, passDetails,
dateStart/dateEnd (ISO8601), layout (цвет+декоры), progress (прогресс-бар),
products: List<Product>
```

**Каждый Product содержит:**
```
id, imageUrl, productType (pack|battle_pass|money_box|...),
price (с бонусами и валютой), status (active|locked|disabled|purchased),
version, name, description, items: List<ProductItem>, layout, attributes, quantity
```

---

## ENDPOINT 2: getProductForCheckout

```
GET /{userId}/products/{productId}/{language}/checkout
```

**Вход:** `userId`, `productId`, `language`, Bearer token

**Цепочка:**
```
WebShopController.getProductForCheckout()
  → createResponse(() → redirectedExecutor.executeOnSessionOwner())
  → WebShopProductOfferServiceImpl.getProductForCheckout(userId, productId, language)
  → SessionWebShopProductOfferService.getProductForCheckout()
      1. WebShopValidateProductService.getValidatedProduct(session, productId)
           a. Найти оффер, содержащий productId
           b. Найти Product в этом офере
           c. Проверить pending платежи (Google Play) → PendingPurchaseException
           d. Для battle_pass/energy_pass → validateBattlePassAvailability()
           e. Иначе → validateOfferAvailability():
                - session.getItem(offerId) → OfferItem
                - OfferControllerDispatcher.getController(offerItem)
                - offerController.getOfferById(offerId) → OfferSuper
                - offerSuper.initDependencies(session)
                - проверить: offerSuper == null? → unavailable
                - offerSuper.isProductAlreadyBought(productId)? → unavailable
                - isNotAllowedPackIndex(offerData, offerSuper, product)? → unavailable
      2. SellableProductToWebShopProductMapper.convertFrom(CDIRecord<Product, cdi>)
      3. PaymentCheckoutStatisticsEvent → EventDispatcher.dispatch()
      4. TranslatableModelMapper.translate(product, language)
      5. return Product
```

**Логика `isNotAllowedPackIndex`:**
- Если `allowedToBuyAnyPack = true` → ок, покупаем любой пак
- Если `withSelfDeletingPacks = true` → только первый пак (index == 0)
- Иначе → `purchased.size() == indexOf(product)` (строго по порядку)

**Исключения:**
- `PendingPurchaseException` → 409 Conflict
- `ProductUnavailableException` → 404 / 400

---

## ENDPOINT 3: processPaymentNotification

```
POST /{userId}/payment-notification
Body: GameServerOrderDeliveryRequest
```

**Вход:** `userId`, `notification` (JSON body), HMAC подпись

**GameServerOrderDeliveryRequest:**
```json
{
  "actionType": "PAYMENT | PAYMENT_FAILED | REFUND",
  "actionDate": 1640995200000,
  "orderId": "order_12345",
  "checkoutRef": "checkout_ref",
  "checkoutProvider": "ADYEN | AGHANIM | ...",
  "paymentMethod": "credit_card",
  "currency": "USD",
  "country": "US",
  "amount": 29.99,
  "item": { "productId": "product_id", "quantity": 1 },
  "reason": "optional_error_reason",
  "paymentSource": "WEB_SHOP | WEB_ALT_PAYMENT",
  "sandbox": false,
  "metadata": { "externalTransactionToken": "optional_token" }
}
```

**Цепочка:**
```
WebShopController.processPaymentNotification()
  → createProductResponse(() → redirectedExecutor.executeOnSessionOwner())
    [ThreadMarkerSemaphore(userId).lock()]  ← блокировка на userId
  → WebShopProductOfferServiceImpl.processPaymentNotification()
  → SessionWebShopProductOfferService.processPaymentNotification()
      switch (notification.actionType):
        PAYMENT → processWebShopPayment() или processWebAltPayment()
        PAYMENT_FAILED → processPaymentFailed()  ← статистика, 200 OK
        REFUND → processRefund()  ← статистика, 200 OK
```

**processWebShopPayment() — детально:**
```
1. createWebshopPaymentDTO(notification, productItem)
     paymentId=orderId, inAppPurchaseId=purchase, itemId=item.id,
     amountUser, currencyUser, purchaseToken=orderId (для WEB_SHOP),
     paymentMethod, paymentSystem=mapped(checkoutProvider),
     externalTransactionToken (если enabled), sandbox, paymentSource, location=country

2. cdi.instance(RewardChainManager.class)        ← инит зависимостей
3. cdi.instance(WebShopOfferProvider.class)      ← подписка на WebshopPaymentStartedEvent

4. EventPublisherBufferingInterceptor interceptor = cdi.instance(...)
5. initPurchase(productId)                       ← WebshopPaymentStartedEvent
6. interceptor.startBuffering()                  ← все события уходят в буфер

7. paymentServicesProvider.get().processPayment(session, info)
     → OfferController.processBuy() → ItemProcessor
     → ItemAddedEvent, OfferEvent, BattlePassEvent ... (все в буфер)

8. webShopInterceptService.sendShowDialogInterceptedEvent()
     → drain буфера
     → ShowDialogActionEvent с начисленными предметами
     → пересылаем OfferEvent, BattlePassEvent клиенту

9. return WebShopTransactionResponse.success(notification)
finally:
10. interceptor.stopBuffering()                  ← все события идут в клиент
```

**processWebAltPayment() — отличия от WebShop:**
- Без `EventPublisherBufferingInterceptor` (нет диалога)
- После успеха: `session.addLocalEvent(new WebAltPaymentEvent(ACTION_PAYMENT_COMPLETE, token))`
- `purchaseToken` = `externalTransactionToken` (из metadata) вместо orderId

**processPaymentFailed / processRefund:**
- Только диспатч статистического события: `PaymentFailedStatisticsEvent` / `PaymentRefundStatisticsEvent`
- Всегда 200 OK

**Исключения:**
- `ProductUnavailableException` / `GameException` / `WebshopPaymentAlreadyExists` → 400/404

---

## ENDPOINT 4: claimFreeItem

```
POST /{userId}/products/{productId}/claim
```

**Вход:** `userId`, `productId`, HMAC подпись (тело пустое)

**Цепочка:**
```
WebShopController.claimFreeItem()
  → createProductResponse(() → redirectedExecutor.executeOnSessionOwner())
    [ThreadMarkerSemaphore(userId).lock()]
  → WebShopProductOfferServiceImpl.claimItem(userId, productId)
  → SessionWebShopProductOfferService.claimItem()
      1. session.getItem(productId) → item (или возврат "not found")
      2. EventPublisherBufferingInterceptor interceptor
      3. interceptor.startBuffering()
      4. cdi.instance(WebShopOfferProvider.class).claimItem(item)
           → CommonWebShopOfferProvider.claimItem()
           → KloneOfferWebShopOfferProvider.claimItem(item)
               if item instanceof PackShopItem:
                 WebShopValidateProductService.validateFreeProduct(session, id)
                 itemProcessor.processBuyEvent(ACTION_BUY, item.id, qty=1, gameState)
                 return WebShopTransactionResponse.success(item)
      5. webShopInterceptService.sendShowDialogInterceptedEvent()
      6. return response
      finally:
      7. interceptor.stopBuffering()
```

---

## EventPublisherBufferingInterceptor — паттерн

Используется для атомарной доставки событий клиенту при мутирующих операциях.

```java
interceptor.startBuffering();
try {
    // Любые события (ItemAdded, OfferUpdate, BattlePass) → буфер вместо клиента
    doWork();
    // Обработать буфер: собрать диалог, отфильтровать нужные события
    webShopInterceptService.sendShowDialogInterceptedEvent();
} finally {
    interceptor.stopBuffering(); // Все события → клиент
}
```

**sendShowDialogInterceptedEvent() делает:**
1. `interceptor.drain()` — вытаскивает буфер
2. Собирает `AccruedItemsEvent` → формирует `ShowDialogActionEvent` (диалог с наградами)
3. Пересылает `ClientEvent`'ы (OfferEvent, BattlePassEvent) в dispatcher

---

## Обработка ошибок в контроллере

```
createProductResponse()  ← для POST (покупки)
  ProductUnavailableException  → 404 / 400, errorCode: PRODUCT_UNAVAILABLE
  PendingPurchaseException     → 409, errorCode: PENDING_PURCHASE
  WebshopPaymentAlreadyExists  → 400, errorCode: PRODUCT_UNAVAILABLE
  GameException                → 400, errorCode: PRODUCT_UNAVAILABLE
  ServerRedirectException      → redirectToUsersServer()
  Exception                    → 500, errorCode: INTERNAL_ERROR

createResponse()  ← для GET
  ServerRedirectException      → redirectToUsersServer()
  Exception                    → 500
```

---

## Стратегии конфигурации офферов

`WebShopStrategyConfigurator` (`@Bean(SINGLETON)`, `@CollectionBinder`) — extension point для сборки `WebShop.Offer.Data`.

```java
public interface WebShopStrategyConfigurator {
    boolean canBeApply(WebShop.Offer.Data offer, WebShop.Offer.Adapter adapter);
    void configure(WebShop.Offer.Data offer, WebShop.Offer.Adapter adapter, CDI cdi);
}
```

Вызывается в `WebShopStrategyAdapterConfiguratorHandler.handle()` — перебирает ВСЕ стратегии, применяет подходящие.

**Существующие стратегии:**
- `SimpleOfferStrategyConfigurator` — базовый оффер
- `SequentialOfferStrategyConfigurator` — паки покупаются по порядку
- `OverallOfferStrategyConfigurator` — можно купить все паки
- `Infinite*StrategyConfigurator` — бесконечные (4/6 слотов, с прогресс-баром)
- `BattlePassProductDataConfigurator` — Battle Pass
- `MoneyBox*Configurator` — Money Box

---

## Ключевые классы — быстрый доступ

| Класс | Файл (пакет external/webshop/) |
|---|---|
| `WebShopController` | `api/WebShopController.java` |
| `WebShopProductOfferServiceImpl` | `service/impl/WebShopProductOfferServiceImpl.java` |
| `SessionWebShopProductOfferService` | `service/impl/SessionWebShopProductOfferService.java` |
| `CommonWebShopOfferProvider` | `provider/offer/impl/CommonWebShopOfferProvider.java` |
| `KloneOfferWebShopOfferProvider` | `provider/offer/impl/KloneOfferWebShopOfferProvider.java` |
| `WebShopValidateProductService` | `service/impl/WebShopValidateProductService.java` |
| `WebShopSessionInterceptService` | `service/impl/WebShopSessionInterceptService.java` |
| `WebShopSellableOfferToProductOfferMapper` | `mapper/WebShopSellableOfferToProductOfferMapper.java` |
| `SellableProductToWebShopProductMapper` | `mapper/SellableProductToWebShopProductMapper.java` |
| `WebShopHMACAuthStrategy` | `api/WebShopHMACAuthStrategy.java` |
| `WebShop` (интерфейс) | `interfaces/WebShop.java` |
| `ProductOffer` | `model/ProductOffer.java` |
| `WebShopTransactionResponse` | `model/WebShopTransactionResponse.java` |
| `GameServerOrderDeliveryRequest` | `model/payment/GameServerOrderDeliveryRequest.java` |

---

## Диагностика — что куда смотреть

| Проблема | Куда идти |
|---|---|
| Оффер не появляется в списке | `CommonWebShopOfferProvider` → `isSupportedType()` → `isSupported(cdi)` |
| Поле ProductOffer некорректное | `WebShopSellableOfferToProductOfferMapper` |
| Поле Product некорректное | `SellableProductToWebShopProductMapper` |
| Стратегия конфигурации не применяется | `WebShopStrategyAdapterConfiguratorHandler` + `canBeApply()` у стратегии |
| Товар недоступен для покупки | `WebShopValidateProductService.isProductUnavailable()` |
| Платёж не обрабатывается | `SessionWebShopProductOfferService.processWebShopPayment()` → `paymentServicesProvider.get().processPayment()` |
| Диалог после покупки не показывается | `WebShopSessionInterceptService.sendShowDialogInterceptedEvent()` |
| Авторизация падает | `WebShopHMACAuthStrategy` (HMAC), `WebShopBearerAuthFilter` (Bearer) |
| 500 при редиректе | `RedirectedExecutor`, `ServerRedirectException` |
