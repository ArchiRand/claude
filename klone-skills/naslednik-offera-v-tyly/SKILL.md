---
name: naslednik-offera-v-tyly
description: >
  Перенос конфигурации наследника OfferItem (XOfferItem) из XML в монетизационную тулу:
  правка самого айтема под маппинг из тулы (@Setter, invokePostConstruct), специфичные поля
  модели оффера, порядок маппинга, проверки валидатора и кнопки Soft Launch.
  Используй при реализации нового типа оффера через веб-интерфейс.
---

# Наследник оффера в монетизационной туле

## Каркас: Model → Mapper → Provider → Validator

Четыре базовых шага (аннотации модели, контракт маппера, шаблон провайдера с сигнатурами,
валидатор, общие ловушки) описаны в общем файле:

**`~/.claude/skills/model-mapper-provider-validator/references/tool-entity-skeleton.md`**

Прочитай его первым — ниже только офферная дельта поверх этого каркаса. Файл общий для
этого скилла и `model-mapper-provider-validator`; правки вносить туда, а не копировать сюда.

## Что это за задача

Когда `XOfferItem` (наследник `OfferItem`) настраивается только через XML — нужно вынести его
конфигурацию в монетизационную тулу. Результат: CRUD через веб-интерфейс с валидацией,
кешированием и soft launch.

---

## Эталонные примеры для чтения

| Что | Путь |
|-----|------|
| Модель оффера | `offers/model/OfferModel.java` |
| Маппер (простой) | `offers/mapper/OfferModelToOfferItemMapper.java` |
| Маппер (с вложенным item) | `offers/mapper/pac/PacModelToPacShopMapper.java` |
| Провайдер | `offers/provider/offer/impl/CassandraOfferItemProvider.java` |
| Валидатор | `offers/services/validator/offer/impl/OfferModelValidator.java` |
| Готовый сквозной пример (PaymentsReward) | `offers/model/PaymentsRewardModel.java` + `offers/mapper/PaymentsRewardModelToItemMapper.java` + `offers/provider/CassandraPaymentsRewardItemProvider.java` + `offers/services/validator/paymentreward/PaymentsRewardModelValidator.java` |

---

## Дельта 1 — Модифицировать сам `XOfferItem`

Айтем изначально заполняется XStream'ом, поэтому под маппинг из тулы его надо чуть открыть:

- Добавить `@Setter` на поля, у которых он отсутствует.
- Добавить публичный делегат для `@XStreamPostConstruct`-метода:

```java
public void invokePostConstruct() { postConstruct(); }
```

- **`postConstruct()` не трогать** — он `private` по дизайну.
- `invokePostConstruct()` нужен только валидатору (для `ModelToItemConversionValidation`).
  Из маппера `postConstruct()` напрямую не вызывать.

---

## Дельта 2 — Поля модели, специфичные для оффера

Базовый набор полей — в `model-mapper-provider-validator`. У офферной модели поверх него:

- `onTryStart` — `@Complete.DB(component = TriggerModel.class, field = "id")`,
  `@DialogModel.Field(type = MULTIPLE_COMPLETE)`, `@TableModel.Column(type = ARRAY)`
- `duration`, `startLimit`, `hudPriority` — `@DialogModel.Field`
- `segmentsComposers` — `@NotNull`, `@Min(1)`, `@TableModel.Column(type = JSON, header = "segments")`
- `hashTags` — `@DialogModel.Field(order = 100)`

Обязательные методы (из `TriggerSubscriberInfo`):

```java
@Override public String triggerSubscriberId() { return id; }
@Override public List<String> getTriggersId()  { return onTryStart; }
```

---

## Дельта 3 — Порядок маппинга в `convertFrom()`

Общий скелет маппера — в базовом скилле. Специфика оффера — порядок и обязательные поля:

1. Извлечь `model` и `version` из `VersionDataStoreDTO`
2. `new XOfferItem()`
3. Поля базового `OfferItem`: `id`, `title`, `image`, `layout`, `source = DB`, `duration`,
   `startLimit` (default `Integer.MAX_VALUE` если `null`), `hudPriority`, `showOnHud`,
   `subOffer`, `hashTags`
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

Стандартные зависимости маппера:

- `Mapper<DateRangedModel, DateRangeItem> dateRangeMapper`
- `Mapper<Segmentable, List<AbstractGameStateCondition>> segmentableMapper`
- `Mapper<VersionDataStoreDTO<ProductModel>, CountedItem> countedItemMapper` (если есть продукты)
- `ItemLoader itemLoader`

---

## Дельта 4 — Специфичные проверки валидатора

Поверх базового `validate()`:

```java
// assertStartLimit: если startLimit != null && < 1 → ToolRuntimeException
assertHasSegments(model);            // model.getSegmentsComposers() → segmentDataDTOValidator
triggerModelValidator.validate(new ModelIdsDTO(model.getTriggersId()));
assertEndDateAfterStartDate(model);  // endDate.before(startDate) → ToolRuntimeException
```

Дополнительные зависимости:

- `Validator<ModelIdsDTO> segmentDataDTOValidator`
- `@Inject @Named("TriggerValidator") Validator<ModelIdsDTO> triggerModelValidator`

`@Min(1)` на `segmentsComposers` и `products` — аннотационная валидация, исключением не дублировать.

---

## Дельта 5 — Soft Launch кнопки

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

## Ловушки (офферные — общие в файле каркаса)

- **`startLimit` default** — если `null`, ставить `Integer.MAX_VALUE` в маппере, иначе оффер
  никогда не стартанёт
- **`@XStreamPostConstruct`** — это `postConstruct()` в айтеме; из маппера напрямую не вызывать;
  `invokePostConstruct()` нужен только валидатору (`toItemConversionValidation`)
- **Импорты + `@Button`** — добавлять импорты хендлеров и аннотацию `@Button` в одном `Write`,
  иначе линтер выкинет «неиспользуемые» импорты между правками

---

## Связанные скиллы

- `model-mapper-provider-validator` — тот же каркас для сущности, которая **не** наследник `OfferItem`
- `knopki-dlya-modeli` — `TableButtonActionHandler` и цепочка инвалидации кеша тулы
- `klone-offers-architecture` — архитектура офферов, иерархия, жизненный цикл
- `klone-tool-entity-on-client` — **обязательное продолжение**: доставка айтема клиенту,
  патчинг заглушек, ресурсы, платежи и биллинг. Серверным каркасом задача не закрыта
