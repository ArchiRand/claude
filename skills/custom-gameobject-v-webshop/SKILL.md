---
name: custom-gameobject-v-webshop
description: >
  Используй когда нужно продавать в вебшопе игровой объект, который НЕ является OfferItem/OfferSuper —
  например BattlePass, EnergyPass или любой другой state-объект с собственным жизненным циклом.
  Для OfferItem-наследников — см. naslednik-offera-v-webshop.
  Для цепочек вызовов контроллера — см. webshop-controller-chains.
---

# Интеграция кастомного game-объекта в WebShop

Паттерн применялся для BattlePass/EnergyPass (KA-36810).
Эталонные файлы: `BattlePassItem`, `BattlePass`, `BattlePassAsWebshopOfferProvider`, `BattlePassProductDataConfigurator`.

---

## Обзор архитектуры

```
YourItem (config/XML)        implements WebShop.Offer + @WebShop.SupportedType
YourStateObject (runtime)    implements WebShop.Offer.Adapter + WebShop.ProductOwner
YourWebshopOfferProvider     @Component: WebShopOfferProvider + ProductOwnerFinder
YourStrategyConfigurator     @Bean(SINGLETON): WebShopStrategyConfigurator
```

**Ключевое отличие от OfferItem-паттерна**: провайдер и finder объединяются в один компонент; валидация checkout идёт через отдельную ветку, а не через `validateOfferAvailability()`.

---

## Пошаговая реализация

### 1. Добавить значения в enum-ы

```java
// ProductOfferType.java — тип оффера-контейнера (как группируются паки)
your_feature_type,

// ProductType.java — тип карточки продукта (как рендерится клиентом)
your_feature_type,

// ReleaseVersion.java — минимальная версия клиента, поддерживающая фичу
V_X_XXX("x.xxx"),
версию надо уточнить у пользователя
```

### 2. Item-класс → `WebShop.Offer` + `@WebShop.SupportedType`

```java
@WebShop.SupportedType
public class YourItem extends ... implements WebShop.Offer {

    @Override
    public ProductOfferType getWebShopOfferType() {
        return ProductOfferType.your_feature_type;
    }

    @Override
    // логику реализации этого метода уточнить у пользователя 
    // или подсветить что ему надо обратить внимание на этотметод    
    public boolean isSupported(CDI cdi) {
        // ReleaseVersion.V_X_XXX — константа, которую добавили в шаге 1
        KloneGameState gs = cdi.instance(KloneGameState.class);
        return new Version(gs.getClientVersion()).isMoreOrEquals(ReleaseVersion.V_X_XXX.getVersion())
            && getRequiredField() != null;
    }

    @Override
    public List<? extends WebShop.Product> getGropedProducts() {
        return List.of(getProductItem()); // ProductItem, который продаётся
    }

    @Override
    public String getImage() { return getHudIcon(); }   // иконка на HUD в вебшопе

    @Override
    public String getLayout() { return getLayoutId(); } // id верстки в webShopLayoutsConfig

    @Override
    public Integer getWebShopHudPriority(WebShopProductPriorityResolver resolver) {
        return resolver.getPriority(this);
    }

    // Опционально — секция с описанием (subtitle, rewards, infoText)
    @Override
    public PassDetailsInfo getPassDetailsInfo() {
        return getBuyWindowConfig(); // если BuyWindowConfig implements PassDetailsInfo
    }
}
```

### 3. State-класс → `WebShop.Offer.Adapter` + `WebShop.ProductOwner`

```java
public class YourStateObject extends ... implements WebShop.Offer.Adapter {

    @Override
    public WebShop.Offer getTargetInstance() {
        return getItem(); // YourItem — это и есть WebShop.Offer
    }

    @Override
    public void simpleInit(KloneSession session) {
        // ТОЛЬКО listeners для платежа. Никаких таймеров, полной инициализации.
        if (this.session == null) {
            this.session = session;
        }
    }

    @Override
    public boolean isAvailable() {
        return !isPurchased(); // false если уже куплен
    }

    @Override
    public Date getWebShopStartDate() { return getItem().getDateRange().getStartDate(); }

    @Override
    public Date getWebShopEndDate() { return getItem().getDateRange().getEndDate(); }
}
```

### 4. Провайдер: `WebShopOfferProvider` + `ProductOwnerFinder`

```java
@Component
public class YourWebshopOfferProvider implements WebShopOfferProvider, ProductOwnerFinder {

    @Override
    public List<WebShop.Offer> offers() {
        return getActiveObjects().stream()
            .map(obj -> (WebShop.Offer.Adapter) obj)
            .filter(adapter -> adapter.isSupportedType(cdi))
            .map(adapter -> adapter.webShopOffer(cdi))
            .toList();
    }

    @Override
    public WebShop.ProductOwner getProductOwner(String productId) {
        // productId — это ID ProductItem (не оффера!)
        return getActiveObjects().stream()
            .filter(obj -> {
                var price = obj.getItem().getProductItem();
                return price != null && price.getId().equals(productId);
            })
            .findFirst().orElse(null);
    }

    @Override
    public WebShopTransactionResponse claimItem(Item item) {
        throw new UnsupportedOperationException("Cannot be claimed as free item");
    }
}
```

### 5. Стратегия конфигурации

```java
@Bean(scope = Scope.SINGLETON)
public class YourStrategyConfigurator implements WebShopStrategyConfigurator {

    @Override
    public boolean canBeApply(WebShop.Offer.Data offer, WebShop.Offer.Adapter adapter) {
        return adapter instanceof YourStateObject
            && offer.getWebShopOfferType().equals(ProductOfferType.your_feature_type);
    }

    @Override
    public void configure(WebShop.Offer.Data offerData, WebShop.Offer.Adapter adapter, CDI cdi) {
        YourStateObject obj = (YourStateObject) adapter;
        ProductItem productItem = obj.getItem().getProductItem();
        offerData.setGropedProducts(List.of(
            WebShop.Product.Data.builder()
                .id(productItem.getId())
                .name(productItem.getName())
                .webShopPrice(productItem.getWebShopPrice())
                .image(productItem.getCardImage())
                .productType(ProductType.your_feature_type)
                .status(obj.isPurchased() ? ProductStatus.locked : ProductStatus.active)
                .storeBonus(productItem.getStoreBonus(cdi))
                .rewardChainPoints(productItem.getRewardChainPoints(cdi))
                .purchase(productItem.getPurchase())
                .build()
        ));
    }
}
```

### 6. Зарегистрировать в `CommonWebShopOfferProvider`

```java
@Inject
private YourWebshopOfferProvider yourProvider;

@Override
public List<WebShop.Offer> offers() {
    List<WebShop.Offer> offers = new ArrayList<>();
    offers.addAll(webShopXmlOfferProvider.offers());
    offers.addAll(kloneOfferWebShopOfferProvider.offers());
    offers.addAll(battlePassAsWebshopOfferProvider.offers());
    offers.addAll(yourProvider.offers());  // ← добавить
    return offers;
}
```

### 7. Добавить ветку валидации в `WebShopValidateProductService`

```java
// в getValidatedProduct():
if (ProductOfferType.your_feature_type.equals(webShopOffer.getWebShopOfferType())) {
    validateYourFeatureAvailability(webShopOffer, product);
} else {
    validateOfferAvailability(session, webShopOffer, product);
}

private void validateYourFeatureAvailability(WebShop.Offer.Data offer, WebShop.Product product) {
    WebShop.ProductOwner owner = yourProvider.getProductOwner(offer.getId());
    if (owner == null || !owner.isAvailable()) {
        productUnavailableException(product.getId());
    }
}
```

### 8. Добавить приоритет в `WebShopProductPriorityResolver`

```java
private static final int YOUR_FEATURE_PRIORITY = 200; // подобрать по ТЗ

// в getPriority():
if (!(sellable instanceof OfferItem)) {
    if (sellable instanceof YourItem) return YOUR_FEATURE_PRIORITY;
    if (sellable instanceof BattlePassItem) return DEFAULT_PASS_PRIORITY;
    return DEFAULT_PRIORITY;
}
```

⚠️ **Проверяй `instanceof YourItem`, а не какой-то другой класс** — это частый баг.

### 9 (если нужно). Кастомная структура items в `SellableProductToWebShopProductMapper`

```java
// в defineSellableProductAndCreateItems():
case your_feature_type -> { return createFromYourFeature(record); }
```

Пример: `createFromPass()` для БП создаёт единственный `ProductItem` с `quantity=1`.

### 10. URL ресурсов — только через `WebShopConfiguration.Conf.getResUrl()`

Любой путь к картинке, который уходит клиенту, **должен** быть обёрнут через `conf.getResUrl()`. Без этого вебшоп не найдёт файл в MinIO.

```java
// Где угодно, где формируешь URL:
WebShopConfiguration.Conf conf = cdi.instance(WebShopConfiguration.Conf.class);

String iconUrl = conf.getResUrl(rawImageName);          // "icon.png" → "https://minio/.../icon.png"
```

**Где встречается:**
- `WebShopSellableOfferToProductOfferMapper.getHudIcon()` — HUD-иконка оффера
- `SellableProductToWebShopProductMapper.createFromYourFeature()` — изображение карточки
- `BuyWindowConfig.getRewards()` — иконки наград в `PassDetailsInfo`

В конфигураторе (`configure()`) передавай **сырое имя файла** — маппер сам вызовет `getResUrl()`.  
В `PassDetailsInfo.getRewards(CDI cdi)` вызывай `getResUrl()` напрямую, т.к. маппер туда не заходит.

### 11 (если нужно). Пробросить `dateRange` от родительского item

Если даты берутся не из самого item, а из Adventure/другого контейнера:

```java
// В родительском item (напр. YourAdventureTabItem):
@XStreamPostConstruct
private void postConstruct() {
    if (getDateRange() != null && yourObject.getDateRange() == null) {
        yourObject.setDateRange(getDateRange());
    }
}
```

---

## Частые ошибки

| Ошибка | Правильно |
|---|---|
| В priority resolver `instanceof WrongClass` | Проверяй именно Item-класс твоей фичи |
| `simpleInit()` с полной инициализацией | Только listeners, нужные для обработки платежа |
| `getProductOwner()` ищет по ID оффера | Ищет по ID `ProductItem` (тот, что в `vipAccessRealMoneyPrice` и т.п.) |
| Ветка `validateOfferAvailability` для нового типа | Нужна отдельная ветка — у нового типа нет `OfferItem` в сессии |
| `@WebShop.SupportedType` на State-классе | Только на Item-классе |
| Провайдер не реализует `ProductOwnerFinder` | Без этого `SessionWebShopProductOfferService` не найдёт `ProductOwner` перед платежом |
| Сырое имя файла уходит клиенту напрямую | Всегда оборачивать через `conf.getResUrl()` — особенно в `PassDetailsInfo.getRewards()` |

---

## Чеклист

- [ ] `ProductOfferType` enum value добавлен
- [ ] `ProductType` enum value добавлен
- [ ] `ReleaseVersion` enum value добавлен
- [ ] Item-класс: `@WebShop.SupportedType`, `WebShop.Offer`, все обязательные методы
- [ ] `isSupported()`: проверка версии клиента + обязательных полей
- [ ] State-класс: `WebShop.Offer.Adapter` + `WebShop.ProductOwner`
- [ ] `simpleInit()` минимальный (только payment listener)
- [ ] `isAvailable()` отражает текущее состояние (куплен/не куплен)
- [ ] Провайдер: `WebShopOfferProvider` + `ProductOwnerFinder` в одном `@Component`
- [ ] `getProductOwner()` ищет по ID `ProductItem`
- [ ] `WebShopStrategyConfigurator` — `canBeApply` + `configure`
- [ ] Провайдер добавлен в `CommonWebShopOfferProvider`
- [ ] Ветка валидации в `WebShopValidateProductService`
- [ ] Приоритет в `WebShopProductPriorityResolver` через `instanceof YourItem`
- [ ] `SellableProductToWebShopProductMapper` — новый case если структура items нестандартная
- [ ] `dateRange` пробрасывается если берётся снаружи
- [ ] Все URL ресурсов обёрнуты через `WebShopConfiguration.Conf.getResUrl()` (особенно в `PassDetailsInfo.getRewards()`)
- [ ] Ресурсы (иконки) включены в `deploy_minio_web` в Rakefile
