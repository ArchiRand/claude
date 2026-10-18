# Каркас сущности в монетизационной туле: Model → Mapper → Provider → Validator

Общая часть для любой сущности, управляемой через веб-тулу. Используется двумя скиллами:
`model-mapper-provider-validator` (общий случай) и `naslednik-offera-v-tyly` (наследник `OfferItem`).
Правки вносить **только здесь** — оба скилла ссылаются на этот файл, чтобы не разъезжаться.

Источник истины — не этот файл, а реальный код: `offers/provider/offer/impl/CassandraOfferItemProvider.java`.
Если что-то не сходится, верь коду и поправь этот файл.

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
public Item byId(Criteria criteria)
{
    return getItems(criteria.version)
            .stream()
            .filter(item -> item.getId().equals(criteria.id))
            .findFirst()
            .orElse(null);
}

@Override
@Cacheable(tags = Cache.Tag.MONETIZATION_TOOL)
public List<Item> allItems(String version, String language)
{
    return getItems(version);
}

@Override
@Cacheable(tags = Cache.Tag.MONETIZATION_TOOL)
public List<Item> allDynamicItems(String version, String lang)
{
    List<Item> result = new ArrayList<>();
    getItems(version)
            .forEach(item ->
            {
                result.add(item);
                extractInnerItems(item, result);
            });
    return result;
}

// Единственное место, где реально строятся айтемы. Все три метода выше делегируют сюда.
@Cacheable(tags = Cache.Tag.MONETIZATION_TOOL)
public List<Item> getItems(String version)
{
    return modelProvider.getByClass(XModel.class)
                        .stream()
                        .map(m -> itemMapper.convertFromWithExceptionWrapper(new VersionDataStoreDTO<>(version, m)))
                        .filter(Optional::isPresent)
                        .map(Optional::get)
                        .collect(Collectors.toList());
}

// Нужен ТОЛЬКО если у твоей сущности есть вложенные айтемы.
// Нет вложенных — метод не пишется вообще, allDynamicItems возвращает getItems(version) напрямую.
// Общего варианта нет: что именно разворачивать — зависит от типа.
private void extractInnerItems(Item item, List<Item> result)
{
    if (item instanceof XItem)
    {
        XItem xItem = (XItem) item;
        if (xItem.getItems() != null)
        {
            result.addAll(xItem.getItems());
        }
        if (xItem.getDateRange() != null)
        {
            result.add(xItem.getDateRange());
        }
    }
}

// Только если реализуется CrossVersionItemProvider:
@Override
@Cacheable(tags = Cache.Tag.MONETIZATION_TOOL)
public List<Item> getCrossVersionItems()
{
    return modelProvider.getByClass(XModel.class)
                        .stream()
                        .map(extractor::extracted)
                        .collect(Collectors.toList());
}
```

**Что здесь легко сделать неправильно:**

- **Направление вызовов — `allItems`/`byId`/`allDynamicItems` → `getItems()`, не наоборот.** Если `getItems()` вызывает `allItems()`, а `@Cacheable` висит на обоих, один и тот же результат кешируется дважды под разными ключами.
- **`extractInnerItems` обязателен в `allDynamicItems` — но только если вложенные айтемы есть.** Есть (`getItems()`, `getDateRange()` внутри твоего айтема) и не развернул → они не попадут в выдачу и не зарезолвятся, это функциональная дырка. Вложенных нет (плоская сущность вроде `NewsModel`) → метод не нужен, `allDynamicItems` просто возвращает `getItems(version)`.
- **Возвращаемые типы — всегда `Item` / `List<Item>`**, как в `ItemsProvider` и `DynamicItemsProvider`. Не `List<XItem>`, не `Optional<XItem>`, не `List<? extends DynamicItem>` — иначе не скомпилируется.
- **`byId` возвращает `Item`, не `Optional<Item>`.** `Optional` появляется только в default-методе `ItemsProvider.findById(version, id)`, который сам оборачивает `byId`.
- **Язык — `String`, не какой-либо enum.** В сигнатурах именно `String version, String language` / `String version, String lang`; константа для значения — `Languages.RU`.
- **`Criteria` — `public final` поля, геттеров нет:** `criteria.version`, `criteria.lang`, `criteria.userId`, `criteria.sig`, `criteria.id`, `criteria.place`. Поля `language` не существует.
- **`ResourcesItemExtractor` — метода `extract(this)` нет.** Интерфейс: `extracted(List<Item>, Item)`, `extracted(List<Item>, String)`, `extracted(Model)`. Для `getCrossVersionItems()` нужен `extracted(Model)` на каждой модели.
- **`@Cacheable` ставится на все методы провайдера**, включая `allDynamicItems` и `getItems`.

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

## Итоговый набор файлов

```
offers/model/XModel.java
offers/mapper/XModelToXItemMapper.java
offers/provider/CassandraXItemProvider.java
offers/services/validator/<feature>/XModelValidator.java
```

Ручной биндинг в Guice-модулях **не нужен** для провайдера и валидатора — `@CollectionBinder` подхватывает автоматически. Маппер нужен с `to = Mapper.class` в `@Bean`.

---

## Общие ловушки

- **`@Bean(scope = Scope.SINGLETON, to = Mapper.class)`** — без `to = Mapper.class` маппер не инъектируется как `Mapper<F, T>`; провайдер и валидатор пишутся без `to`
- **`convertFromWithExceptionWrapper`** в провайдере — не `convertFrom`, иначе один сломанный айтем кладёт весь провайдер
- **`onMappingFinished`** — резолвит ссылки на игровые предметы; если не вызвать, айтем будет с пустыми слотами
- **`@JsonTypeInfo`** — нужен на модели если она используется полиморфно (хранится в коллекции вместе с другими типами)
- **`ServerReviewInfoProvider`** — обязателен если используется `ModelToItemConversionValidation`; без него при несовместимости с версией будет `ToolRuntimeException` вместо предупреждения
- **`@Getter private final Class<XModel> modelClass = XModel.class`** — Lombok не видит инициализатор поля без `@Getter`; написать именно так, не через конструктор
