---
name: model-mapper-provider-validator
description: Добавление новой сущности в монетизационную тулу: Model, Mapper, CassandraProvider, Validator. Использовать при добавлении любой сущности с управлением через веб-интерфейс, не обязательно OfferItem.
---
## Когда применять

Нужно управлять игровой сущностью (`XItem`) через веб-тулу (CRUD, валидация при сохранении, кеширование). Источник данных — Cassandra через `ModelProvider`.

---

## Эталонные файлы (читать в этом порядке)

| Роль | Простой пример | Сложный пример |
|------|---------------|----------------|
| Модель | `offers/model/news/NewsModel.java` | `offers/model/OfferModel.java` |
| Маппер | `offers/mapper/news/NewsModelToNewsItemMapper.java` | `offers/mapper/OfferModelToOfferItemMapper.java` |
| Провайдер без CrossVersion | `offers/provider/CassandraNewsItemProvider.java` | — |
| Провайдер с CrossVersion | `offers/provider/CassandraStorageItemProvider.java` | `offers/provider/CassandraPaymentsRewardItemProvider.java` |
| Валидатор минимальный | `offers/services/validator/news/impl/NewsModelValidator.java` | — |
| Валидатор с доп. проверками | `offers/services/validator/storage/StorageModelValidator.java` | `offers/services/validator/paymentreward/PaymentsRewardModelValidator.java` |

---

## Шаг 1 — Model

**Пакет:** `offers/model/` (или подпакет по фиче)

**Минимальный набор аннотаций:**
```java
@Data
@NoArgsConstructor
@JsonIgnoreProperties(ignoreUnknown = true)
@JsonTypeInfo(use = JsonTypeInfo.Id.NAME, property = "@class")   // нужен для полиморфной десериализации
@EqualsAndHashCode(onlyExplicitlyIncluded = true)
@TableModel(header = "...", tab = @Tab(name = "...", order = N))
@DialogModel(header = "...")
public class XModel implements Model
```

**Интерфейсы — выбирать по необходимости:**

| Интерфейс | Когда | Что требует |
|-----------|-------|-------------|
| `Model` | всегда | `getId()` |
| `Translatable` | есть поля с `@Translate` | — (маркерный) |
| `DateRangedModel` | есть `startDate`/`endDate` | `getStartDate()`, `getEndDate()`, `getId()` |
| `Segmentable` | есть сегментация | `getId()`, `getSegmentsComposers()` |
| `TriggerSubscriberInfo` | есть триггеры | `triggerSubscriberId()`, `getTriggersId()` |
| `ServerReviewInfoProvider` | маппер завязан на версии айтемов | добавляет `serverReviewInfo: List<String>` + `addInfo()` |

**Стандартные поля:**
```java
@NotNull(message = "id field must be filled in")
@EqualsAndHashCode.Include
@TableModel.Column(order = 0)
@DialogModel.Field(order = 0)
private String id;

// Переводимые строки:
@Translate
@NotNull
@Complete.DB(component = LocalizationsModel.class, field = "ru")
@DialogModel.Field(type = Dialog.Field.Type.COMPLETE)
private String title;

// Ресурсы:
@NotNull
@ExtractResources(type = GameResource.Type.IMAGE)
@DialogModel.Field
private String image;

// Дата:
@JsonFormat(shape = JsonFormat.Shape.STRING, pattern = DATE_FORMAT, timezone = "America/Los_Angeles")
@TableModel.Column(order = N)
@DialogModel.Field
private Date startDate;

// Всегда в конце:
@EqualsAndHashCode.Include
private String generatedID;

@TableModel.Column(order = 100, type = Table.Column.Field.Type.ARRAY, header = "Attention")
private List<String> serverReviewInfo;   // только если реализует ServerReviewInfoProvider
```

**`DATE_FORMAT`** — константа из `DateRangedModel` (`"yyyy-MM-dd HH:mm:ss"`).

---

## Шаг 2 — Mapper

**Пакет:** `offers/mapper/` (или подпакет)

```java
@Bean(scope = Scope.SINGLETON, to = Mapper.class)   // to = Mapper.class — обязательно!
@RequiredArgsConstructor(onConstructor_ = {@Inject})
public class XModelToXItemMapper implements Mapper<F, XItem>
```

**`F`** — это `XModel` напрямую или `VersionDataStoreDTO<XModel>` (нужен когда маппинг зависит от версии статических айтемов).

**`VersionDataStoreDTO`** — два конструктора:
- `new VersionDataStoreDTO<>(String version, T model)` — корневой
- `new VersionDataStoreDTO<>(T model, VersionDataStoreDTO<?> parent)` — для вложенных маппингов (наследует версию)

**Общий скелет `convertFrom()`:**
```java
@Override
public XItem convertFrom(VersionDataStoreDTO<XModel> dto)
{
    XModel model = dto.getDto();
    String version = dto.getVersion();

    XItem item = new XItem();
    item.setId(model.getId());
    // ... заполнить поля ...

    item.onMappingFinished(itemLoader.getItemsByVersion(version));  // резолвит ссылки на игровые айтемы
    return item;
}
```

**Важно:**
- `@Bean(scope = Scope.SINGLETON, to = Mapper.class)` — без `to = Mapper.class` маппер не будет виден при инъекции как `Mapper<F, T>`
- `onMappingFinished(itemLoader.getItemsByVersion(version))` — вызывать на каждом вложенном айтеме и на самом айтеме в конце
- Если маппинг не зависит от версии — `F = XModel` (без `VersionDataStoreDTO`)

---

## Шаг 3 — Provider

**Пакет:** `offers/provider/`

```java
@Bean(scope = Scope.SINGLETON)
@RequiredArgsConstructor(onConstructor_ = {@Inject})
@Slf4j
public class CassandraXItemProvider implements DynamicItemsProvider  // + CrossVersionItemProvider если нужно
```

**`DynamicItemsProvider`** помечен `@CollectionBinder` — все реализации подхватываются автоматически, ручной биндинг в Guice не нужен.

**Обязательные зависимости:**
```java
private final ModelProvider modelProvider;
private final Mapper<F, XItem> itemMapper;
@Getter
private final Class<XModel> modelClass = XModel.class;   // требует DynamicItemsProvider
```

**Если нужен `CrossVersionItemProvider` (экстракция ресурсов):**
```java
private final ResourcesItemExtractor extractor;
```

**Шаблон методов:**
```java
@Override
@Cacheable(tags = Cache.Tag.MONETIZATION_TOOL)
public List<Item> allItems(String version, String language)
{
    return modelProvider.getByClass(XModel.class).stream()
            .map(m -> itemMapper.convertFromWithExceptionWrapper(new VersionDataStoreDTO<>(version, m)))
            .filter(Optional::isPresent)
            .map(Optional::get)
            .collect(Collectors.toList());
}

@Override
public List<Item> allDynamicItems(String version, String lang)
{
    return allItems(version, lang);
}

@Override
@Cacheable(tags = Cache.Tag.MONETIZATION_TOOL)
public Item byId(Criteria criteria)
{
    return allItems(criteria.version, Languages.RU).stream()
            .filter(i -> i.getId().equals(criteria.id))
            .findFirst()
            .orElse(null);
}

// Если нужен CrossVersionItemProvider:
@Override
public List<Item> getCrossVersionItems()
{
    return extractor.extract(this);
}

// Защищённый геттер для внутреннего переиспользования (без двойного кеширования):
protected List<XItem> getItems(String version)
{
    return allItems(version, Languages.RU);
}
```

**Выбор кеш-тега:**
- `Cache.Tag.MONETIZATION_TOOL` — стандарт для офферов и монетизации
- `Cache.Tag.COMMUNITY_NEWS` — только для новостей
- Инвалидация происходит автоматически при сохранении модели через тулу

**`convertFromWithExceptionWrapper` vs `convertFrom`:**
- В провайдере **всегда** `convertFromWithExceptionWrapper` — логирует ошибку и возвращает `Optional.empty()` вместо краша всего провайдера при проблемном айтеме

---

## Шаг 4 — Validator

**Пакет:** `offers/services/validator/<feature>/`

```java
@Slf4j
@Bean(scope = Scope.SINGLETON)
@RequiredArgsConstructor(onConstructor_ = {@Inject})
public class XModelValidator implements BatchModelValidator<XModel>
```

**`BatchModelValidator`** помечен `@CollectionBinder` — регистрируется автоматически.

**Обязательные зависимости:**
```java
@Getter
private final Class<XModel> modelClass = XModel.class;   // требует BatchModelValidator
```

**Опциональные зависимости (брать по необходимости):**
```java
private final TranslateExistModelValidator translatableValidator;     // для @Translate полей
private final ModelToItemConversionValidation toItemConversionValidation; // для проверки маппинга по версиям
private final Mapper<F, XItem> mapper;                                // нужен toItemConversionValidation
private final Validator<ModelIdsDTO> segmentDataDTOValidator;         // для сегментов
@Inject @Named("TriggerValidator") Validator<ModelIdsDTO> triggerModelValidator; // для триггеров
```

**Шаблон `validate()`:**
```java
@Override
public void validate(XModel model)
{
    translatableValidator.validate(model);          // если есть @Translate поля
    // доп. проверки бизнес-логики (бросать ToolRuntimeException)
    toItemConversionValidation.validate(model, mapper); // если маппер привязан к версиям айтемов
}
```

**Бросать `ToolRuntimeException`:**
```java
// Один аргумент — errorType = "BAD_MODEL_CONFIG" по умолчанию:
throw new ToolRuntimeException("описание ошибки");

// Два аргумента — кастомный errorType:
throw new ToolRuntimeException("CUSTOM_ERROR_TYPE", "описание для '{}'", model.getId());
```

**`ModelToItemConversionValidation`:**
- Пробует замапить модель для каждой версии статических айтемов
- Если хотя бы одна версия успешна — OK, пишет предупреждения в `serverReviewInfo`
- Если ни одна версия не прошла — `ToolRuntimeException("NO_ITEM_FOUND", ...)`
- Модель должна реализовывать `ServerReviewInfoProvider` для записи предупреждений

---

## Итоговый чеклист

```
offers/model/XModel.java
offers/mapper/XModelToXItemMapper.java
offers/provider/CassandraXItemProvider.java
offers/services/validator/<feature>/XModelValidator.java
```

Ручной биндинг в Guice-модулях **не нужен** для провайдера и валидатора — `@CollectionBinder` подхватывает автоматически. Маппер нужен с `to = Mapper.class` в `@Bean`.

---

## Ловушки

- **`@Bean(scope = Scope.SINGLETON, to = Mapper.class)`** — без `to = Mapper.class` маппер не инъектируется как `Mapper<F, T>`; провайдер и валидатор пишутся без `to`
- **`convertFromWithExceptionWrapper`** в провайдере — не `convertFrom`, иначе один сломанный айтем кладёт весь провайдер
- **`onMappingFinished`** — резолвит ссылки на игровые предметы; если не вызвать, айтем будет с пустыми слотами
- **`@JsonTypeInfo`** — нужен на модели если она используется полиморфно (хранится в коллекции вместе с другими типами)
- **`ServerReviewInfoProvider`** — обязателен если используется `ModelToItemConversionValidation`; без него при несовместимости с версией будет `ToolRuntimeException` вместо предупреждения
- **`@Getter private final Class<XModel> modelClass = XModel.class`** — Lombok не видит инициализатор поля без `@Getter`; написать именно так, не через конструктор
