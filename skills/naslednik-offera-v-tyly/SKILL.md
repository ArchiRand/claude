---
name: naslednik-offera-v-tyly
description: Перенос конфигурации XOfferItem из XML в монетизационную тулу: Model, Mapper, Provider, Validator, кнопки soft launch. Использовать при реализации нового типа оффера через веб-интерфейс.
---
## Что это

Когда `XOfferItem` (наследник `OfferItem`) настраивается только через XML — нужно вынести его конфигурацию в монетизационную тулу. Результат: CRUD-управление офферами через веб-интерфейс с валидацией, кешированием и soft launch.

---

## Эталонные примеры для чтения (читать перед началом)

| Что | Путь |
|-----|------|
| Модель | `offers/model/OfferModel.java` |
| Маппер (простой) | `offers/mapper/OfferModelToOfferItemMapper.java` |
| Маппер (с вложенным item) | `offers/mapper/pac/PacModelToPacShopMapper.java` |
| Провайдер | `offers/provider/offer/impl/CassandraOfferItemProvider.java` |
| Валидатор | `offers/services/validator/offer/impl/OfferModelValidator.java` |
| Готовый пример (PaymentsReward) | `offers/model/PaymentsRewardModel.java` + `offers/mapper/PaymentsRewardModelToItemMapper.java` + `offers/provider/CassandraPaymentsRewardItemProvider.java` + `offers/services/validator/paymentreward/PaymentsRewardModelValidator.java` |

---

## Шаги

### 1. Model

Интерфейсы: `Translatable`, `TriggerSubscriberInfo`, `Model`, `DateRangedModel`, `Segmentable`, `ServerReviewInfoProvider`

Обязательные аннотации класса:
```java
@Data @NoArgsConstructor
@JsonIgnoreProperties(ignoreUnknown = true)
@JsonTypeInfo(use = JsonTypeInfo.Id.NAME, property = "@class")
@EqualsAndHashCode(onlyExplicitlyIncluded = true)
@TableModel(header = "...", tab = @Tab(name = "...", order = N))
@DialogModel(header = "...", buttons = { @Button(...), @Button(...) })
```

Стандартный набор полей (порядок имеет значение для UX тулы):
- `id` — `@NotNull`, `@EqualsAndHashCode.Include`, `@TableModel.Column(order=0)`, `@DialogModel.Field(order=0)`
- `title` — `@Translate`, `@NotNull`, `@Complete.DB(LocalizationsModel, "ru")`, `@DialogModel.Field(type=COMPLETE)`
- `description` — `@Translate`, `@Complete.DB(LocalizationsModel, "ru")`, `@DialogModel.Field`
- `image` — `@NotNull`, `@ExtractResources(type=IMAGE)`, `@DialogModel.Field`
- `layout` — `@NotNull`, `@ExtractResources(type=UI)`, `@DialogModel.Field`
- Специфичные для фичи поля
- `startDate`/`endDate` — `@JsonFormat(pattern=DATE_FORMAT, timezone="America/Los_Angeles")`, `@TableModel.Column`
- `duration`, `startLimit`, `hudPriority` — `@DialogModel.Field`
- `onTryStart` — `@Complete.DB(TriggerModel, "id")`, `@DialogModel.Field(type=MULTIPLE_COMPLETE)`, `@TableModel.Column(type=ARRAY)`
- `segmentsComposers` — `@NotNull`, `@Min(1)`, `@TableModel.Column(type=JSON, header="segments")`
- `hashTags` — `@DialogModel.Field(order=100)`
- `generatedID` — `@EqualsAndHashCode.Include` (без аннотаций тулы)
- `serverReviewInfo` — `@TableModel.Column(order=100, type=ARRAY, header="Attention")`

Обязательные методы:
```java
@Override public String triggerSubscriberId() { return id; }
@Override public List<String> getTriggersId() { return onTryStart; }
```

### 2. Модифицировать XOfferItem (если нужно)

- Добавить `@Setter` на поля, у которых он отсутствует
- Добавить публичный делегат для `@XStreamPostConstruct`-метода:
```java
public void invokePostConstruct() { postConstruct(); }
```
- Не трогать `postConstruct()` — он `private` по дизайну

### 3. Mapper

```java
@Bean(scope = Scope.SINGLETON, to = Mapper.class)
@RequiredArgsConstructor(onConstructor_ = {@Inject})
public class XModelToItemMapper implements Mapper<VersionDataStoreDTO<XModel>, XOfferItem>
```

Стандартные зависимости:
- `Mapper<DateRangedModel, DateRangeItem> dateRangeMapper`
- `Mapper<Segmentable, List<AbstractGameStateCondition>> segmentableMapper`
- `Mapper<VersionDataStoreDTO<ProductModel>, CountedItem> countedItemMapper` (если есть продукты)
- `ItemLoader itemLoader`

Порядок маппинга в `convertFrom()`:
1. Извлечь `model` и `version` из `VersionDataStoreDTO`
2. `new XOfferItem()`
3. Поля базового `OfferItem`: `id`, `title`, `image`, `layout`, `source = DB`, `duration`, `startLimit` (default `Integer.MAX_VALUE` если null), `hudPriority`, `showOnHud`, `subOffer`, `hashTags`
4. `item.setAllConditions(segmentableMapper.convertFrom(model))`
5. `item.setTriggersId(model.getTriggersId())`
6. `item.setDateRange(dateRangeMapper.convertFrom(model))`
7. Специфичные поля `XOfferItem`
8. Если есть вложенный `PackShopItem`:
   - `packShopItem.setId(model.getId() + "_PACK_SHOP")`
   - `packShopItem.setFree(true)`
   - products: `countedItemMapper.convertFrom(new VersionDataStoreDTO<>(p, dto))`
   - `packShopItem.onMappingFinished(itemLoader.getItemsByVersion(version))`
   - `item.setItems(List.of(packShopItem))`
9. `item.onMappingFinished(itemLoader.getItemsByVersion(version))` — **обязательно в конце**

### 4. Provider

```java
@Bean(scope = Scope.SINGLETON)
@RequiredArgsConstructor(onConstructor_ = {@Inject})
@Slf4j
public class CassandraXItemProvider implements DynamicItemsProvider, CrossVersionItemProvider
```

Зависимости:
- `ModelProvider modelProvider`
- `Mapper<VersionDataStoreDTO<XModel>, XOfferItem> itemMapper`
- `ResourcesItemExtractor extractor`
- `@Getter Class<XModel> modelClass = XModel.class`

Методы:
```java
@Cacheable(tags = Cache.Tag.MONETIZATION_TOOL)
public List<XOfferItem> allItems(String version, Language lang) {
    return modelProvider.getByClass(XModel.class).stream()
        .map(m -> itemMapper.convertFromWithExceptionWrapper(new VersionDataStoreDTO<>(version, m)))
        .filter(Objects::nonNull)
        .collect(Collectors.toList());
}

@Cacheable(tags = Cache.Tag.MONETIZATION_TOOL)
public List<? extends DynamicItem> allDynamicItems(String version, Language lang) {
    return allItems(version, lang);
}

@Cacheable(tags = Cache.Tag.MONETIZATION_TOOL)
public Optional<XOfferItem> byId(Criteria criteria) {
    return allItems(criteria.getVersion(), criteria.getLanguage()).stream()
        .filter(i -> i.getId().equals(criteria.getId()))
        .findFirst();
}

protected List<XOfferItem> getItems(String version) {
    return allItems(version, Language.RU);
}

public List<CrossVersionItem> getCrossVersionItems() {
    return extractor.extract(this);
}
```

**Важно**: `convertFromWithExceptionWrapper` (не `convertFrom`) — логирует ошибки без краша всего провайдера.

### 5. Validator

```java
@Slf4j
@Bean(scope = Scope.SINGLETON)
@RequiredArgsConstructor(onConstructor_ = {@Inject})
public class XModelValidator implements BatchModelValidator<XModel>
```

Зависимости:
- `@Getter Class<XModel> modelClass = XModel.class`
- `TranslateExistModelValidator translatableValidator`
- `ModelToItemConversionValidation toItemConversionValidation`
- `Mapper<VersionDataStoreDTO<XModel>, XOfferItem> mapper`
- `Validator<ModelIdsDTO> segmentDataDTOValidator`
- `@Inject @Named("TriggerValidator") Validator<ModelIdsDTO> triggerModelValidator`

Стандартный `validate()`:
```java
translatableValidator.validate(model);
// assertStartLimit: если startLimit != null && < 1 → ToolRuntimeException
assertHasSegments(model);   // model.getSegmentsComposers() → segmentDataDTOValidator
triggerModelValidator.validate(new ModelIdsDTO(model.getTriggersId()));
assertEndDateAfterStartDate(model);  // endDate.before(startDate) → ToolRuntimeException
toItemConversionValidation.validate(model, mapper);
```

`@Min(1)` на `segmentsComposers` и `products` в модели — аннотационная валидация, не дублировать исключением.

`BatchModelValidator` подхватывается автоматически через `@CollectionBinder` — ручной биндинг в Guice-модулях не нужен.

### 6. Soft Launch кнопки

**Новый тип оффера** — создать конкретный handler:
```java
@Slf4j @Bean(scope = Scope.SINGLETON) @RequiredArgsConstructor(onConstructor_ = {@Inject})
public class XSoftLaunchButtonHandler extends AbstractSoftLaunchButtonHandler<XModel> {
    private final Mapper<VersionDataStoreDTO<XModel>, XOfferItem> mapper;
    @Override
    protected OfferItem buildOfferItem(KloneSession session, XModel model) {
        return mapper.convertFrom(new VersionDataStoreDTO<>(session.getClientVersion(), model));
    }
}
```

**Кнопка Stop** — `StopSoftLaunchedOfferButtonHandler` модель-агностик, переиспользовать как есть.

Зарегистрировать в `@DialogModel` на модели:
```java
@DialogModel(header = "...", buttons = {
    @Button(labels = "Soft Launch", handler = XSoftLaunchButtonHandler.class,
            description = "Тестовый запуск оффера на устройстве без сохранения его в бд"),
    @Button(labels = "Stop Launched offer", handler = StopSoftLaunchedOfferButtonHandler.class,
            description = "Принудительная остановка активного оффера")})
```

---

## Итоговые файлы

| Файл | Описание |
|------|----------|
| `offers/model/XModel.java` | Модель оффера для тулы |
| `items/XOfferItem.java` | Модифицирован: `@Setter` + `invokePostConstruct()` |
| `offers/mapper/XModelToItemMapper.java` | Маппер модель → айтем |
| `offers/provider/CassandraXItemProvider.java` | Провайдер из Cassandra |
| `offers/services/validator/x/XModelValidator.java` | Валидатор перед сохранением |
| `offers/handler/button/dialog/XSoftLaunchButtonHandler.java` | Кнопка тестового запуска |

---

## Ловушки

- **Импорты + `@Button`** — добавлять импорты хендлеров и аннотацию `@Button` в одном `Write`, иначе линтер удалит "неиспользуемые" импорты между правками
- **`convertFrom` vs `convertFromWithExceptionWrapper`** — в провайдере всегда `WithExceptionWrapper`
- **`onMappingFinished`** — вызывать на каждом вложенном item (PackShopItem) и на самом item в конце; без этого не резолвятся ссылки на игровые предметы
- **`startLimit` default** — если `null`, ставить `Integer.MAX_VALUE` в маппере (иначе оффер никогда не стартанёт)
- **`@XStreamPostConstruct`** — это `postConstruct()` в айтеме; не вызывать из маппера напрямую; `invokePostConstruct()` нужен только для валидатора (`toItemConversionValidation`)
