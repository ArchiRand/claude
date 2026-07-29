---
name: klone-cacheable-interceptor
description: >
  Method-level AOP-кеш в klone-mobile-server через аннотацию @Cacheable и
  CacheableInterceptor (Guice AOP). Используй когда добавляешь @Cacheable на новый метод,
  разбираешься почему закешированное значение не обновляется / протухло не вовремя,
  настраиваешь инвалидацию по Cache.Tag, работаешь с ConcurrentMapCache,
  PrometheusCacheMetrics или кнопками Refill/Print Cache в тулe.
---

# CacheableInterceptor — method-level кеш

AOP-кеш поверх методов, помеченных `@Cacheable`. Не Guava/Caffeine — своя простая
реализация на `ConcurrentHashMap` с тегами для группового инвалидирования и TTL.

## Ключевые участники

| Класс | Путь | Роль |
|---|---|---|
| `Cacheable` | `guice/annotations/Cacheable.java` | Аннотация метода: `tags()` |
| `CacheableInterceptor` | `guice/interceptor/cacheable/CacheableInterceptor.java` | AOP MethodInterceptor: get-or-compute |
| `Cache` | `guice/interceptor/cacheable/cache/Cache.java` | Интерфейс + `Tag` enum, `BaseKey`/`SignatureKey`, `Value` |
| `ConcurrentMapCache` | `.../cache/impl/ConcurrentMapCache.java` | Единственная реализация, `@Bean(... to = Cache.class)` |
| `AnnotationProcessorModule` | `src_items/.../modules/AnnotationProcessorModule.java` | Явный `bindInterceptor` — вот где всё связывается |
| `CacheExpiredValueEvent` | `services/event/events/CacheExpiredValueEvent.java` | Событие протухания по TTL (сейчас без подписчиков) |
| `DynamicItemCacheComposer` | `services/provider/item/impl/DynamicItemCacheComposer.java` | Прогрев `allItems(version, RU)` при старте и после каждой инвалидации по тегу |
| `PrometheusDynamicItemsMetrics` | `metrics/PrometheusDynamicItemsMetrics.java` | Прогрев `allDynamicItems(version, RU)` при старте и на каждом скрейпе метрик |
| `ItemDeserializer` / `ItemsProvider.findById` | `serialize/ItemDeserializer.java`, `services/provider/item/ItemsProvider.java` | Единственный реальный вызывающий `byId(Criteria)` — реактивно, при десериализации стейта игрока |

---

## Как это связывается (легко не найти grep'ом)

Биндинг лежит в **другом source root** — `klone-mobile-server/src_items/`, не в `src/`:

```java
// src_items/com/social/game/klonemobile/modules/AnnotationProcessorModule.java
CacheableInterceptor cacheableInterceptor = new CacheableInterceptor();
binder().requestInjection(cacheableInterceptor);   // подтягивает @Inject Cache cache
binder().bindInterceptor(
    Matchers.annotatedWith(Bean.class),
    Matchers.annotatedWith(Cacheable.class),
    cacheableInterceptor);
```

Никакой конвенции "класс `XInterceptor` + аннотация `X`" в кодовой базе нет — это
единственный хардкоженный `bindInterceptor`. Матчер по классу — `@Bean` (проектный DI),
матчер по методу — `@Cacheable`. Значит **`@Cacheable` работает только на методах классов,
уже помеченных `@Bean`** — на произвольном POJO аннотация молча не сработает (Guice AOP
не создаёт прокси).

`BeanAnnotationResolver.checkCacheableMethodsNotPrivate` (`guice/resolvers/impl/`) на этапе
биндинга бросает `RuntimeException`, если `@Cacheable` висит на `private`-методе —
Guice-прокси физически не может перехватить приватный метод.

---

## Механика перехвата (`CacheableInterceptor.invoke`)

```
ключ = Cache.SignatureKey(methodName, declaringClass.simpleName, arguments.clone(), tags)
cache.get(ключ) != null?
    да  → вернуть закешированное значение, invocation.proceed() НЕ вызывается
    нет → invocation.proceed() → результат
          → создать Value(result, currentTime, ttl)
          → cache.put(ключ, value)
```

TTL для `Value` берётся из тега с **минимальной** `ttlDuration` среди тегов метода,
у которых `hasTtl() == true` (`Tag.getTtlDuration() != Duration.ZERO`). Если ни у одного
тега нет TTL — `Value` бессрочный (`ttlMillis = -1`).

**Важно про идентичность ключа**: `SignatureKey.equals()/hashCode()` сравнивают только
`functionName + classDeclarationName + params` (deep equals по массиву аргументов).
**Теги в идентичность ключа не входят** — они используются только для инвалидации и выбора
TTL. На практике это не проблема: аннотация на методе фиксирована, поэтому теги у ключа
для конкретного метода всегда одни и те же.

---

## `Cache.Tag` — теги и текущий TTL

| Tag | TTL | Используется в |
|---|---|---|
| `MONETIZATION_TOOL` | нет (0) | Провайдеры офферов/фичей монетизационной тулы |
| `ENTITY_MANAGER` | нет (0) | `CassandraEntityManager.get()` |
| `SPLIT_CONFIGURATION` | нет (0) | `SplitConfigurationProviderImpl` |
| `COMMUNITY_NEWS` | нет (0) | Новости сообщества |
| `CLEAN_BY_ANY_TAG` | нет (0) | `CassandraGameConfigProvider` — спец-тег, см. ниже |

На момент изучения **ни у одного тега TTL не задан** (`Duration.ZERO` у всех) — вся
инвалидация в проекте идёт вручную, через `cache.remove(Tag...)`, а не по времени.
TTL-механизм (`tagWithMinimalTTL`, `Value.isExpired()`, фоновая чистка раз в 24ч) в коде
есть и работает, но реально им сейчас никто не пользуется.

**`CLEAN_BY_ANY_TAG`** — не обычный тег: в `ConcurrentMapCache.remove(Tag, Tag...)` он
**автоматически добавляется** к любому набору тегов для удаления:
```java
tagList.add(tag);
tagList.add(Tag.CLEAN_BY_ANY_TAG);
```
Значит **любая** инвалидация по любому тегу попутно удаляет из кеша все записи,
помеченные `CLEAN_BY_ANY_TAG` — это "удаляется при любой чистке" тег для данных, у которых
нет собственного триггера инвалидации (см. `CassandraGameConfigProvider`).

---

## Явная инвалидация — цепочки по тегам

Общий паттерн (одинаковый для всех трёх тегов, у которых вообще есть инвалидация):
кнопка в туле → `*Services.updateXVersion()` → пишет новую версию/хэш в Cassandra-сущность
→ `EntityDao.ChangeListener` ловит изменение (на **каждом** из инстансов флота — это не
локальное событие одного процесса, а Cassandra change-feed, на который подписан
каждый инстанс отдельно) → `cache.remove(Tag...)` → сразу же `dynamicItemCacheComposer.compose()`.

| Tag | Кнопка в туле | Service | ChangeListener |
|---|---|---|---|
| `MONETIZATION_TOOL` | `RefillCacheButtonActionHandler` | `ToolConfigurationServices.updateStateVersion()` | `ToolConfigurationChangeListener` (`offers/persistence/dao/`) |
| `SPLIT_CONFIGURATION` | `RefillSplitCacheButtonActionHandler` | `SplitConfigurationCacheServices.updateSplitVersion()` | `SplitConfigurationCacheChangeListener` |
| `COMMUNITY_NEWS` | `RefillNewsCacheButtonActionHandler` (кнопка "Update news" на самой `NewsModel`) | `CommunityNewsConfigurationServices.updateNewsVersion()` | `CommunityNewsConfigurationChangeListener` |

Все три `ChangeListener` устроены идентично, например `ToolConfigurationChangeListener.onEntityChange`:
```java
cache.remove(Tag.MONETIZATION_TOOL);
dynamicItemCacheComposer.compose();
serverStateConfigurationProvider.currentModel().setToolHash(entity.getToolState());
```
(у `ToolConfigurationChangeListener` там ещё и `container.refillProcessorsContainer()` —
это **другой, независимый** кеш/контейнер, не путать с `Cache` из этого пакета).

Важно: `compose()` вызывается не только чтобы "на всякий случай" — без него после
`cache.remove(tag)` кеш остался бы полностью холодным до первого реального запроса.

---

## Прогрев кеша — два независимых механизма

Есть **два** источника прогрева `@Cacheable`-методов `DynamicItemsProvider`, и они
прогревают **разные** методы:

**1. `DynamicItemCacheComposer.compose()`** — вызывается при старте процесса (сразу после
того, как `ItemLoader` загрузит айтемы) и после каждой инвалидации по тегу (см. таблицу
выше, вызывается из `*ChangeListener.onEntityChange`):
```java
versionProvider.getVersions().parallelStream().forEach(
    version -> providers.forEach(p -> p.allItems(version.getVersion(), Languages.RU)));
```
Прогревает `allItems(version, RU)` для каждого провайдера, по всем версиям.

**2. `PrometheusDynamicItemsMetrics.updateItemsAmountMetric()`** (`metrics/`) — вызывается
`PrometheusMetricsUpdater`'ом сразу в конструкторе (эффективно — при старте процесса) и
дальше **при каждом реальном скрейпе Прометеуса** (не чаще раза в 3с, но на практике —
почти сразу и постоянно):
```java
versionProvider.getVersions().parallelStream().forEach(version ->
    dynamicItemsProviders.get().allDynamicItems(version.getVersion(), Languages.RU));
```
Прогревает `allDynamicItems(version, RU)` через агрегатор `DynamicItemsProviders`, тоже по
всем версиям, тоже только RU.

**Важно**: версии игры на сервере фиксированы (не меняются в рантайме), поэтому оба этих
метода — `allItems(version, RU)` и `allDynamicItems(version, RU)` (и транзитивно
`loadNewsItems(version)`, который они оба вызывают внутри себя через self-invocation) —
получают **полный, конечный набор ключей почти сразу после старта процесса** и дальше
остаются плоскими. Разные языки тут ни при чём — `allDynamicItems` для айтем-провайдеров
в проекте реально вызывается только с `Languages.RU`.

**Единственный метод из четырёх `@Cacheable` на `CassandraNewsItemProvider`/
`CassandraFullNewsItemProvider`, который НЕ прогревается ни одним из двух механизмов
выше — `byId(Criteria)`.** Он заполняется только реактивно: боевой вызывающий —
`ItemDeserializer.getItem()` → `ItemsProvider.findById(version, itemId)` (default-метод в
`ItemsProvider.java`) → `byId(Criteria.builder().version(version).id(itemId).build())`.
Срабатывает при десериализации стейта игрока, если ссылка на айтем не находится среди
статичных XML-айтемов и не в `removedIds`/deprecated. `userId`/`sig` в `Criteria` при этом
**всегда null** (проверено по всей кодовой базе — `Criteria.builder()` для `byId()`
встречается только в `ItemIdToItemMapper` и в этом `findById()`, оба раза без `userId`),
так что ключевое пространство ограничено `(version, id)` — рост конечен, но набирается
**постепенно**, по мере того как через конкретный инстанс проходит достаточно
разнообразный трафик игроков, ссылающихся на разные конкретные id.

Отсюда форма графиков `klone_cache_size_by_tag`: `allItems`/`allDynamicItems` — плоские
почти сразу после старта; `byId` — плавно растёт часы/сутки, пока не исчерпает
реальное пространство `(version, id)`, и только тогда выходит на плато. Сейчас
`PrometheusCacheMetrics` не бьёт метрику по имени метода (`SignatureKey.functionName`
есть, но в лейблы не выведен) — чтобы разделить вклад `byId` и `allItems`/`allDynamicItems`
на графике явно, это стоит туда добавить.

---

## Метрика в проде — почему `sum by (tag) (klone_cache_size_by_tag)` выглядит как рост/утечка

`Cache` — **in-memory, per-JVM** хранилище: у каждого запущенного инстанса (в проде это
десятки серверов × несколько параллельно живущих версий игры — т.е. сотни независимых
процессов) свой собственный стор. Prometheus сам добавляет к каждой метрике label
`instance` при скрейпе, поэтому запрос `sum by (tag) (...)` складывает значение **по всем
инстансам сразу**, а не показывает состояние одного процесса.

Из этого вытекают два разных паттерна на графике для одного и того же механизма:

- **Пилообразный график с резкими обвалами** (пример: `MONETIZATION_TOOL`) — значит по
  этому тегу реально происходят инвалидации (кто-то жмёт Refill-кнопку/меняет конфиг в
  туле), и все инстансы синхронно чистят кеш одновременно (см. предыдущий раздел),
  дальше — lazy-fill до следующего обвала.
- **Плавный монотонный рост, который выходит на плато** (пример: `COMMUNITY_NEWS`,
  когда никто давно не жал "Update news") — это **не утечка**, а lazy-fill конкретно
  метода `byId(Criteria)` (единственный `@Cacheable`-метод, не входящий ни в
  `DynamicItemCacheComposer.compose()`, ни в `PrometheusDynamicItemsMetrics` — см. раздел
  про прогрев выше) без единого сброса за наблюдаемый период. `allItems`/`allDynamicItems`
  при этом уже плоские с первых секунд — растёт именно `byId`, по мере того как реальный
  трафик игроков постепенно покрывает всё пространство `(version, id)`. Если рост со
  временем выполаживается — это пространство ограничено (версии фиксированы, `id` —
  конечный набор реальных сущностей), а не бесконечно.

**Как отличить реальную утечку от нормального lazy-fill**, не трогая код:
- `sum by (tag, instance) (...)` — если растёт число `instance`-серий, это раскатка/скейлинг,
  а не рост кеша внутри процесса.
- `count(klone_cache_size_by_tag{tag="..."})` — если эта кривая повторяет форму исходного
  графика, рост суммы объясняется ростом количества таргетов, а не данных.
- `max by (tag) (...)` — если максимум по инстансам стабилен, а `sum` растёт, дело в
  количестве инстансов, а не в утечке на одном из них.
- Если ни один из этих запросов не объясняет рост — тогда стоит подозревать конкретный
  `@Cacheable`-метод с неограниченным пространством ключей (например, `Criteria` с
  реальным `userId`/`sig`, которые меняются на каждый запрос — тогда каждый вызов создаёт
  новую запись, которая никогда не переиспользуется и не удаляется иначе как через
  `cache.remove(tag)` целиком).

---

## Диагностика

| Инструмент | Что показывает |
|---|---|
| `PrintCacheButtonActionHandler` (кнопка в туле) | Дамп всего стора в лог: ключ + количество значений (для `Collection`/`Map` — размер, иначе 1) |
| `PrometheusCacheMetrics` (`metrics/`) | `klone_cache_key_size`, `klone_cache_total_size`, `klone_cache_size_by_tag{tag=...}` |
| `PrintModelCacheButtonActionHandler` | **Не это кеш** — дампит `ModelCache` (`com.social.model.cache`), отдельный механизм тулы |

`ConcurrentMapCache.cleanUp()` (полная очистка стора) и `CacheExpiredValueEvent`
(диспатчится при TTL-протухании) на момент изучения **не имеют вызывающих/подписчиков**
в кодовой базе — метод и событие существуют, но ничем не используются.

---

## Ловушки

| Проблема | Разбор |
|---|---|
| `@Cacheable` на методе — не кешируется | Класс метода не помечен `@Bean` (матчер `bindInterceptor` требует `@Bean` на классе) |
| `RuntimeException` при старте: "marked with Cacheable annotation cannot be private" | Метод `private` — сделать хотя бы package-private, Guice-прокси не видит private |
| Изменил конфиг в туле — кеш не обновился | Проверь, что для этого тега вообще есть `ChangeListener`, вызывающий `cache.remove(tag)` — не у всех тегов есть выделенная кнопка/цепочка (см. таблицу выше) |
| Кеш "сам" не протухает по времени | Ожидаемо: у всех тегов сейчас `ttlDuration = Duration.ZERO` → `hasTtl() == false` → `Value` бессрочный |
| Добавил новый метод с `@Cacheable(tags = MyTag)`, но записи всё равно чистятся при инвалидации другого тега | Это `CLEAN_BY_ANY_TAG`-эффект: `remove(Tag, Tag...)` всегда попутно чистит `CLEAN_BY_ANY_TAG`-записи — если твой метод помечен и своим тегом, и `CLEAN_BY_ANY_TAG`, он чистится при любой инвалидации |
| Ищешь, где биндится интерцептор, и не находишь через grep по `src/` | Биндинг в `src_items/`, отдельном source root — не в основном `src/guice/` |
| `klone_cache_size_by_tag{tag=X}` в проде монотонно растёт, похоже на утечку | Сначала проверь `sum by (tag, instance)` / `count(...)` / `max by (tag)` — почти наверняка это `sum` по всем инстансам флота + lazy-fill без недавней инвалидации (см. раздел про метрику), а не реальный рост в одном процессе |
| После инвалидации кеш "не до конца" прогрелся | Ожидаемо: `compose()` прогревает `allItems(version, RU)`, `PrometheusDynamicItemsMetrics` — `allDynamicItems(version, RU)`, но `byId(Criteria)` не прогревается ничем — дозаполняется лениво через `ItemDeserializer`/`findById` по реальным запросам |

---

## Файлы

```
klone-mobile-server/src/com/social/game/klonemobile/
  guice/annotations/
    Cacheable.java                        ← аннотация, tags()
  guice/interceptor/cacheable/
    CacheableInterceptor.java              ← MethodInterceptor: get-or-compute + TTL
    cache/
      Cache.java                            ← интерфейс, Tag enum, SignatureKey, Value
      impl/ConcurrentMapCache.java          ← ConcurrentHashMap, 24ч cleanup, remove по тегам
  guice/resolvers/impl/
    BeanAnnotationResolver.java             ← checkCacheableMethodsNotPrivate
  services/event/events/
    CacheExpiredValueEvent.java             ← событие TTL-протухания (без подписчиков)
  services/provider/item/impl/
    DynamicItemCacheComposer.java           ← прогрев allItems(version, RU): старт + после каждой инвалидации
  services/provider/item/
    ItemsProvider.java                      ← default findById(version, id) → byId(Criteria) без userId/sig
  services/item/
    Criteria.java                            ← version, lang, userId, sig, id, place — все участвуют в equals
  serialize/
    ItemDeserializer.java                   ← реальный вызывающий findById() при десериализации стейта игрока
  metrics/
    PrometheusCacheMetrics.java              ← klone_cache_* gauges (по тегу/классу, НЕ по методу)
    PrometheusDynamicItemsMetrics.java       ← прогрев allDynamicItems(version, RU): старт + каждый скрейп
  offers/handler/button/table/
    PrintCacheButtonActionHandler.java       ← дамп стора в лог
    RefillCacheButtonActionHandler.java      ← invalidate MONETIZATION_TOOL (через ToolConfigurationServices)
    RefillSplitCacheButtonActionHandler.java ← invalidate SPLIT_CONFIGURATION
    RefillNewsCacheButtonActionHandler.java  ← invalidate COMMUNITY_NEWS (через CommunityNewsConfigurationServices)
  offers/persistence/dao/
    ToolConfigurationChangeListener.java     ← слушатель DAO → cache.remove(MONETIZATION_TOOL) + compose()
    SplitConfigurationCacheChangeListener.java
    CommunityNewsConfigurationChangeListener.java

klone-mobile-server/src_items/com/social/game/klonemobile/modules/
  AnnotationProcessorModule.java            ← ЕДИНСТВЕННОЕ место bindInterceptor
```

## Связанные скиллы

- `knopki-dlya-modeli` — `TableButtonActionHandler` и цепочка инвалидации кеша тулы
  (Refill/Print-кнопки из этого скилла — конкретный пример применения)
