---
name: klone-tool-entity-on-client
description: >
  Что обязательно доделать ЗА ПРЕДЕЛАМИ серверного модуля после того, как сущность заведена
  в монетизационной туле (Model → Mapper → Provider → Validator): доставка айтема клиенту,
  патчинг заглушек в DynamicItemsManualPatcher, ресурсы (@ExtractResources / ResourceSelector),
  платежи (*FromDbPaymentProcessorProvider), биллинг (ProductsState) и ссылки в стейте игрока.
  Используй сразу после серверного каркаса, а также при отладке симптомов: айтем из тулы
  не доехал до клиента, вместо картинки дырка, "No payment processor found", цена пака
  не обновилась, объект молча вырезало из стейта игрока.
---

# Сущность из тулы: что доделать за пределами сервера

## Когда применять

Серверный каркас (Model → Mapper → Provider → Validator) описан в скилле
`model-mapper-provider-validator`, офферная дельта — в `naslednik-offera-v-tyly`.
**Этот скилл — про всё, что после них.**

Он нужен, потому что серверная часть проверяется компиляцией и валидатором тулы,
а клиентская — ничем. Ни один из шести пунктов ниже не ловится ни компиляцией,
ни `./gradlew test`, ни `itemsAttributesValidation`. Пропуск обнаруживается крашем
на устройстве или молча — пустой картинкой и списанными деньгами.

---

## Как айтем из тулы попадает на клиент

Знать эту цепочку обязательно — почти все ошибки объясняются местом в ней.

**Сервер:** `SessionActiveItemRepository.activate(item)` → `Flattenable.flattenResult()`
(добавляет сам айтем первым, потом всё из `flatten()`) → фильтр по `sessionCache`
→ `ClientItemController.activate` → `ItemSyncEvent` c JSON.

**Клиент**, `EventPacketHandler.processItemSyncEvent` — шаги ровно в этом порядке,
они же печатаются в лог как `step=`:

```
parse → patch → products → selectors → put_all → compute_download
```

- `parse` — `new JsonReader(..., new BaseItemReader())`;
- `patch` — `DynamicItemsManualPatcher.patchDynamicItems`;
- `products` — `ProductsState.handleNewProductItems`;
- `selectors` — сбор недостающих ресурсов;
- `put_all` — `DynamicOffersService.putAll`;
- `compute_download` — докачка.

Из порядка следуют два факта, на которые опираются пункты ниже: **патчинг идёт
до сбора ресурсов и до биллинга**, поэтому они видят уже подменённые реальные айтемы;
и **исключение на любом шаге роняет весь батч**, а не одну сущность.

---

## Точка 1 — Доставка: айтем должен попасть в `flatten()` и в поле `items`

**Симптом пропуска:** айтем есть в `allDynamicItems`, но на клиент не приезжает;
либо приезжает, а `getItems()` на нём `null` и падает докачка ресурсов.

Две независимые вещи:

1. **`flatten()`** — если у сущности есть вложенные айтемы со своим id, их надо отдать
   в `flatten()`, иначе `activate()` их не активирует и клиент их не увидит.
2. **Поле `items` заполнять явно в маппере.** Если класс вычисляет `getItems()`
   переопределённым геттером, а поле `ItemGroup.baseItems` держит пустым — для айтемов
   из сборки это работает (`ItemWriter` зовёт геттеры), а для тулы **нет**:
   `ItemSyncEvent` сериализуется `SimpleGameSerializer` с `setVisibility(ALL, NONE)`
   + `setVisibility(FIELD, ANY)`, то есть **строго по полям, геттеры игнорируются**.

```java
// в маппере, после заполнения остальных полей
private void fillItemsField(OfferItem item)
{
    item.setItems(item.getItems());   // значение из геттера — порядок паков сохраняется
}
```

Эталон, на который надо равняться: `OfferModelToOfferItemMapper`, `PaymentsRewardModelToItemMapper` —
оба заполняют поле явно.

---

## Точка 2 — Патчинг заглушек: `DynamicItemsManualPatcher`

`klone/src/com/vizor/mobile/serialization/items/DynamicItemsManualPatcher.java`

**Симптом пропуска:** вместо вложенного айтема на клиенте заглушка (объект с одним id
и пустыми полями), либо `RuntimeException` из патчера и **падение всего батча**.

**Как понять, нужна ли ветка.** Посмотреть сгенерированную клиентскую модель
в `klone/gen/.../items/` и найти поля с `@ModelFieldRef` — именно они приезжают ссылкой
и требуют подмены. Это единственный надёжный способ: по серверному классу не видно.

Правила ветки:

- патчить **все** `@ModelFieldRef`-поля, включая те, что дублируются в `baseItems`:
  общая голова `patchOfferItem` чинит список, но само поле останется заглушкой;
- **не бросать исключение, если замены нет.** Вспомогательный метод возвращает `null`,
  вызывающий оставляет заглушку. Одна незнакомая сущность не должна ронять патчинг целиком;
- проверять `instanceof`, а не слепо кастовать: совпадение id с айтемом другого типа
  даст `ClassCastException`;
- модуль `klone` под java2cpp — циклами по индексу, без Stream API (см. `.claude/rules/java2cpp.md`);
- после правки прогнать `./gradlew :klone-android-gradle:convertJava` — в `test` он не входит.

---

## Точка 3 — Ресурсы: `@ExtractResources`, а не селектор

**Симптом пропуска:** дырка вместо картинки, падение окна на отсутствующей вёрстке.

**Главное: в `ResourceSelector` и его наследников лезть, скорее всего, НЕ надо.**
Для сущностей из тулы работает отдельный, полностью автоматический путь:

1. поля модели помечаются `@ExtractResources(type = ResourceType.UI | IMAGE)`;
2. провайдер реализует `CrossVersionItemProvider.getCrossVersionItems()` через
   `ResourcesItemExtractor.extracted(model)`;
3. `ResourcesItemProviderImpl.collectFromObject` обходит модель рекурсивно и **проваливается
   в `List<X>`, если у класса `X` есть `@DialogModel`** — так достаются вложенные модели;
4. получается `ResourcesItem` с `consumerId = <id модели>`;
5. `CrossVersionAdapterItemProvider` строит `DependencyIndexItem` по `consumerId`;
6. `SessionActiveItemRepository.doActivate` подтягивает `ResourcesItem` вместе с самой
   сущностью — он уезжает тем же `ItemSyncEvent`;
7. на клиенте `ResourcesItemResourcesSelector` раскладывает по типам:
   `UI` → вёрстка, `OBJ_ANIM` → объект карты, остальное → картинка.

**Что проверить вместо правки селектора:**

- у каждого ресурсного поля модели стоит `@ExtractResources` с верным `type`;
- у вложенных моделей есть `@DialogModel` — иначе обход в них не провалится;
- провайдер реализует `CrossVersionItemProvider`;
- поля, которые клиент для этого типа НЕ читает, в модели запрещены валидатором —
  иначе ММ зададут ресурс, он уедет в скачку и будет качаться впустую.

**Когда селектор всё-таки нужен:** если ресурс берётся не из строки модели, а из
разрешённого айтема (иконка вложенного продукта, картинка пака) — это тянет
`ResourceSelector.fill(Item, out)` из уже существующих веток. Проверь, что твой айтем
попадает в обход, и только если нет — добавляй ветку.

**Полезно знать:** `isPreloadActualDateRange(null)` возвращает `true`, то есть сущность
с `duration` и без дейтрэнджа из полного прохода селектора не выпадает.
А `ResourcesItemResourcesSelector` в `processItemSyncEvent` добавляется **безусловно**,
тогда как `OfferItemResourceSelector` — только при `gameState.getLocation() != null`.

---

## Точка 4 — Платежи: свой `*FromDbPaymentProcessorProvider`

**Симптом пропуска:** клиент платит, деньги списываются, в логе
`No payment processor found` и `Result.ERROR`. **Тестами не ловится вообще** — регистрация
живёт в другом слое.

Если у сущности есть платные паки или `AccessProductItem`, нужен свой провайдер —
наследник `AbstractDynamicPaymentProcessorProvider`
(`klone-mobile-server/src/com/social/game/klonemobile/payments/`). Реализуются два метода:

```java
protected abstract Set<PlatformProductItemId> loadFromDB();
protected abstract PaymentProcessor createProcessor(PlatformProductItemId id);
```

- **наследовать именно `AbstractDynamicPaymentProcessorProvider`**, а не копировать
  `OfferFromDbPaymentProcessorProvider` — последний недоотрефакторенный предшественник базы
  и тащит свою копию `getPaymentProcessors`/`findNewProcessors`. Эталоны на базе:
  `AccessProductFromDbPaymentProcessorProvider`, `PurchaseFeatureFromDBPaymentProcessorProvider`,
  `MoneyBoxFromDbPaymentProcessorProvider`;
- **регистрировать нигде не надо**: `PaymentsModule:28`
  (`server-fw/mobile-fw-server/src/com/vizor/mobile/server/modules/payments/`) делает
  `CollectionBinder.bindCollection(binder(), PaymentProcessorsProvider.class)` и подхватывает
  любой `@Bean(scope = Scope.SINGLETON)`;
- паки брать `allDynamicItems(version, RU)` + фильтр по типу, а не `allItems()` + `getItems()`:
  не зависит от того, что вернёт `getItems()` у конкретного типа, и бесплатные паки
  отсеиваются сами;
- `PlatformProductItemId` помечен `@EqualsAndHashCode`, поэтому один пак, собранный
  для всех версий айтемсов, сворачивается в `Set` в один кортеж. Без этого контейнер
  платежей упал бы на `Not unique payment pack processor` — и упал бы **весь**,
  не только твоя сущность.

---

## Точка 5 — Биллинг: `ProductsState`

`klone/src/com/vizor/klone/billing/ProductsState.java`

**Симптом пропуска:** цена пака на клиенте не обновляется, показывается цена из конфига.

Два пути, оба надо проверить:

- **загрузка сессии** — конструктор, `DynamicOffersService.getOffersPackPurchases()`.
  Он обходит `offerItem.getItems()` у всех динамических офферов и берёт оттуда
  `PackPurchaseItem`. **Работает только если поле `items` заполнено маппером** — см. точку 1;
- **рантайм** — `handleNewProductItems`, вызывается шагом `products`. Собирает
  `ProductItem` из батча через `selectProductItems` и патчит цены через `ProductFiller`.

Если сущность не является `OfferItem` и её продукты лежат не в `getItems()`, потребуется
своя ветка в `selectProductItems` — она разбирает айтем по типам. Ветка обязана
уважать `clazz` и проверять `out.contains(...)`, иначе продукт уедет в чужую по типу
выборку и продублируется.

**Ловушка про цену:** `priceString` руками в туле лучше не задавать. `ProductItem.setPriceString(ItemGroup)`
подставляет её из `PurchasePricesItem` по `purchase`, а при расхождении кидает
`PostConstructException("Incorrect priceString=...")`. Если же `purchase` вообще неизвестен
`PurchasePricesItem`, `priceString` останется null и `postConstruct` упадёт на
`new BigDecimal(null)` — сохранение модели заблокируется невнятным NPE.

Подробности механизма — скилл `klone-client-pricing-sync`.

---

## Точка 6 — Ссылки на сущность в стейте игрока

**Симптом пропуска:** объект молча исчезает из стейта, в логе
`NewItemDeserializer`/`ItemDeserializer` — `"Error on deserializing item"`.

Касается **вложенных** сущностей, у которых нет своей записи в `cql_models`
(они живут внутри JSON родительской модели), но на которые стейт ссылается по id.

`DynamicItemsProviders.byId` ищет провайдера **по классу модели, найденной по id айтема**.
У вложенной сущности своей модели нет, поэтому до провайдера дело не доходит.
Решение — переопределить в своём провайдере:

```java
@Override
public Optional<Model> findModelByInnerItemId(String innerItemId)
```

Искать **по моделям из `ModelCache`, а не по собранным айтемам.** Любой обход, который
запускает мапперы, уходит в рекурсию: провайдер → маппер → `ItemIdToItemMapper`
→ `CommonItemsProvider.byId` → `DynamicItemsProviders`. `@Cacheable` от неё не защищает —
значение кладётся в кеш уже после `invocation.proceed()`.

---

## Чеклист

- [ ] вложенные айтемы отдаются в `flatten()`;
- [ ] поле `items` заполняется маппером явно, а не только геттером;
- [ ] в `DynamicItemsManualPatcher` есть ветка на все `@ModelFieldRef`-поля
      (сверено по `klone/gen`), без бросков и со `instanceof`;
- [ ] `./gradlew :klone-android-gradle:convertJava` прошёл;
- [ ] ресурсные поля модели помечены `@ExtractResources`, вложенные модели имеют `@DialogModel`,
      провайдер реализует `CrossVersionItemProvider`;
- [ ] поля-ресурсы, которые клиент для этого типа не читает, запрещены валидатором;
- [ ] есть свой `*FromDbPaymentProcessorProvider` на базе `AbstractDynamicPaymentProcessorProvider`
      (если есть платные паки);
- [ ] цены подтягиваются на обоих путях `ProductsState` — и на загрузке сессии, и в рантайме;
- [ ] ссылки на вложенные айтемы в стейте резолвятся (`findModelByInnerItemId`);
- [ ] ручная приёмка на устройстве: Soft Launch → окно открылось → покупка прошла.

---

## Ловушки

- **Исключение на любом шаге `processItemSyncEvent` роняет весь батч**, а не одну сущность.
  Поэтому в клиентском коде для сущностей из тулы null-guard'ы важнее «правильных» бросков.
- **Трюк «переопределить `getItems()` вместо заполнения поля» работает только для айтемов
  из сборки.** Для тулы — нет, `ItemSyncEvent` сериализуется по полям.
- **`@Cacheable` не защищает от рекурсии**: значение попадает в кеш после `proceed()`,
  на повторном входе его ещё нет.
- **`CacheableInterceptor` кеширует и `null`** — безусловно, без проверки результата.
  Обход провайдеров по `byId` оставит мусорные null-записи на каждый промах.
- **`DynamicItemCacheComposer.tryFillDynamicItemCache` прогревает `allItems`, а не
  `allDynamicItems`** — на прогретый кеш вложенных айтемов рассчитывать нельзя.
- **Селектор ресурсов работает ПОСЛЕ патчинга** и видит уже подменённые айтемы.
- **`@WebShop.SupportedType` не наследуется** (объявлена без `@Inherited`): если сущность
  наследует класс, помеченный ею, она автоматически появится в вебшопе.

---

## Связанные скиллы

- `model-mapper-provider-validator` — серверный каркас, читать первым;
- `naslednik-offera-v-tyly` — офферная дельта поверх каркаса;
- `knopki-dlya-modeli` — кнопки и инвалидация кеша;
- `klone-client-pricing-sync` — механизм цен целиком;
- `klone-offer-pack-purchase-flow`, `klone-feature-pack-purchase-flow` — платёжные цепочки.
