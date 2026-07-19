---
name: naslednik-offera-v-webshop
description: >
  Руководство по интеграции нового наследника OfferItem в вебшоп (WebShop).
  Используй этот скил только когда нужно добавить новый тип оффера на основе OfferItem/OfferSuper:
  Item-класс (конфиг из XML), state-класс (runtime), стратегия конфигурации, маппер, провайдер.
  Для всего остального в вебшопе (сервисный слой, контроллер, платёж, авторизация) — используй другой скил.
---

# Наследник оффера в вебшопе

> Цепочки вызовов контроллера, авторизация, блокировки, форматы запросов/ответов, ключевые классы и диагностика → `webshop-controller-chains`.

## Ключевые принципы

- Всё, что per-session — через `@Component` (CDI scoped). Всё глобальное — `@Bean(scope=SINGLETON)`.
- `WebShopProductOfferServiceImpl` — тонкий роутер; вся бизнес-логика — в `SessionWebShopProductOfferService`.
- Новый тип оффера в вебшопе: Item-класс (наследник `OfferItem`) реализует `WebShop.Offer` и помечается `@WebShop.SupportedType`; соответствующий state-класс (наследник `OfferSuper`) реализует нужные методы `WebShop.Offer.Adapter`.
- `@WebShop.SupportedType` ставится на **Item-класс** (наследник `OfferItem`), а не на `OfferSuper`. `OfferItem` уже несёт эту аннотацию — нужна только если создаётся новый подтип `OfferItem`.

---

## Extension Points — куда добавлять что

### 1. Новый тип оффера в вебшопе

Два класса на один оффер: **Item** (конфиг из XML) и **state-объект** (runtime).

**Item-класс** (наследник `OfferItem`, реализует `WebShop.Offer`):
1. Аннотировать `@WebShop.SupportedType` — нужно только если создаётся новый подтип `OfferItem` (базовый `OfferItem` уже аннотирован).
2. Переопределить методы `WebShop.Offer` при необходимости: `getWebShopOfferType()`, `getGropedProducts()`, `isSupported(CDI)`, `getWebShopHudPriority(...)` и др.

**State-класс** (наследник `OfferSuper`, реализует `WebShop.Offer.Adapter`):
1. Переопределить методы `WebShop.Offer.Adapter` при необходимости: `getWebShopEndDate()`, `getWebShopStartDate()`, `getProgressBar()`, `getClassStrategy()`.
2. `getTargetInstance()` уже возвращает `item` (OfferItem) — не трогать без причины.
3. Добавить `WebShopStrategyConfigurator` если нужна специфичная сборка `Offer.Data` (см. п. 2 ниже).
4. Если state-класс реализует `WebShopFeatureOffer` — переопределить `isInitialized()` и убедиться, что инит вызывается в `KloneOfferWebShopOfferProvider.postConstruct()`.

Для оффера из XML (не из state):
1. Реализовать `WebShop.Offer` напрямую и добавить провайдер, регистрируемый в `WebShopXmlOfferProvider`.

### 2. Новая стратегия конфигурации (WebShopStrategyConfigurator)

```java
@Bean(scope = Scope.SINGLETON)
public class MyOfferStrategyConfigurator implements WebShopStrategyConfigurator {

    @Override
    public boolean canBeApply(WebShop.Offer.Data offer, WebShop.Offer.Adapter adapter) {
        return adapter instanceof MyOffer
            && offer.getWebShopOfferType().equals(ProductOfferType.MY_TYPE);
    }

    @Override
    public void configure(WebShop.Offer.Data offer, WebShop.Offer.Adapter adapter, CDI cdi) {
        MyOffer myOffer = (MyOffer) adapter;
        offer.setGropedProducts(myOffer.getProductsResult(cdi));
        // специфичные поля Data...
    }
}
```
Регистрируется автоматически через `@CollectionBinder` — вручную в модуль добавлять не нужно.

Список существующих стратегий → `webshop-controller-chains` (раздел "Стратегии конфигурации офферов").

### 3. Новый REST endpoint

Добавлять **только** в `WebShopController`.
- Покупки/начисления → `createProductResponse(...)`, read-only → `createResponse(...)`.
- Паттерн метода, авторизация, обработка ошибок → `webshop-controller-chains` (разделы "Авторизация", "Обработка ошибок в контроллере").

### 4. Новый метод в сервисном слое

1. Добавить сигнатуру в `WebShopProductOfferService`.
2. Реализовать в `WebShopProductOfferServiceImpl` — шаблон: получить сессию через `sessionProvider`, семафор lock/unlock в try/finally, делегировать в `CDI.getInstance(session).instance(WebShopProductOfferService.class).myMethod(...)`.
3. Реализовать в `SessionWebShopProductOfferService` — бизнес-логика сессионного уровня.

Детали семафоров и цепочки вызовов → `webshop-controller-chains`.

### 5. Новый маппер

Реализовать `Mapper<CDIRecord<WebShop.X>, TargetModel>`, зарегистрировать `@Component`.
`CDIRecord<T>` несёт `(T target, CDI cdi)` — используй `cdi` для получения зависимостей внутри маппера.

### 6. Новый провайдер офферов

Реализовать `WebShopOfferProvider`, зарегистрировать `@Component`.
Добавить инъекцию и вызов `.offers()` в `CommonWebShopOfferProvider`.

---

## Частые ошибки и антипаттерны

| Проблема | Правильно |
|---|---|
| Бизнес-логика в `WebShopProductOfferServiceImpl` | Только роутинг в сессию; логика — в `SessionWebShopProductOfferService` |
| `@Singleton` для per-session компонента | `@Component` — CDI создаёт экземпляр per session |
| Прямой вызов `new MyService()` вместо CDI | Всегда `cdi.instance(MyService.class)` |
| Отсутствие семафора при мутирующих операциях | `SessionSemaphore.lock()` / `.unlock()` в try/finally |
| `@SupportedType` забыт на новом подтипе `OfferItem` | Оффер будет отфильтрован в `KloneOfferWebShopOfferProvider.isSupportedType()` |
| Двойная инициализация `WebShopFeatureOffer` | Добавить проверку `isInitialized()` в метод инита |
| Стратегия конфигуратора не добавлена | Поля `gropedProducts` и т.д. в `Data` останутся null |

---

## Чеклист новой фичи

- [ ] Определён слой (доменная модель / стратегия / сервис / REST)
- [ ] `@WebShop.SupportedType` на новом подтипе `OfferItem` (только если создаётся новый подтип, не нужно для наследников `OfferSuper`)
- [ ] `WebShopStrategyConfigurator` добавлен и покрывает `canBeApply` + `configure`
- [ ] Метод в `WebShopProductOfferService` → impl → session impl
- [ ] Семафор в `WebShopProductOfferServiceImpl` (lock/finally unlock)
- [ ] Правильная авторизация на endpoint → `webshop-controller-chains`
- [ ] `WebShopFeatureOffer.isInitialized()` проверяется если оффер — фича
- [ ] Маппер зарегистрирован (`@Component`)
- [ ] Статистика: `session.addAllStatsEvent(...)` / `EventDispatcher.dispatch(...)`
- [ ] Мутирующие операции (payment, claim) обёрнуты в `EventPublisherBufferingInterceptor` → `webshop-controller-chains`
