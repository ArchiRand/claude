---
name: knopki-dlya-modeli
description: Реализация TableButtonActionHandler для кнопок в UI монетизационной тулы, включая 11-шаговую цепочку инвалидации кэша. Используй при добавлении кнопок в @TableModel или реализации инвалидации кэша для модели.
---

## Интерфейс

```java
// com.vizor.server.model.editor.component.handlers
public interface TableButtonActionHandler extends BaseButtonActionHandler
{
    // Переопределить onClick(ButtonContext) если нужен доступ к данным строки
    default ModelEditingResponse onClick(ButtonContext buttonContext)
    {
        onClick();
        return new ModelEditingResponse(ModelEditingResponse.Status.SUCCESS,
                getClass().getName() + " worked without errors");
    }

    void onClick(); // Переопределить для простых глобальных операций
}
```

`ButtonContext` содержит:
- `model` (`TableModelBody`) — строка модели, на которой нажата кнопка
- `dialogData` (`TableModelBody`) — дополнительные данные из диалога перед действием (опционально)
- `getModel()` — типизированный геттер с unchecked cast

`ModelEditingResponse(Status, String)` — ответ в UI. Статусы: `SUCCESS`, `WARNING`, `ERROR`.

---

## Базовая структура любого хендлера

```java
package com.social.game.klonemobile.offers.handler.button.table;

import com.google.inject.Inject;
import com.social.game.klonemobile.guice.annotations.Bean;
import com.social.game.klonemobile.guice.annotations.Scope;
import com.vizor.server.model.editor.component.handlers.TableButtonActionHandler;
import lombok.RequiredArgsConstructor;

@Bean(scope = Scope.SINGLETON)
@RequiredArgsConstructor(onConstructor_ = {@Inject})
public class MyButtonActionHandler implements TableButtonActionHandler
{
    // инжектировать нужные зависимости через конструктор

    @Override
    public void onClick()
    {
        // логика
    }
}
```

---

## Два режима использования

### Режим 1 — простой (глобальная операция, строка не важна)
Переопределить только `onClick()`. Подходит для: инвалидации кеша, дампа в лог, перезагрузки контейнеров.

### Режим 2 — контекстный (операция над конкретной строкой)
Переопределить `onClick(ButtonContext context)` вместо `onClick()`:
```java
@Override
public ModelEditingResponse onClick(ButtonContext context)
{
    MyModel model = context.getModel(); // unchecked cast к нужному типу
    // логика над конкретной строкой
    return new ModelEditingResponse(ModelEditingResponse.Status.SUCCESS, "done");
}
```
Если операция может частично не получиться — вернуть `WARNING` или `ERROR` со значимым сообщением.

---

## Регистрация кнопки на модели

```java
import com.vizor.server.model.editor.annotations.Button;
// ...

@TableModel(header = "...", tab = @Tab(...),
        buttons = {@Button(labels = "Button label", handler = MyButtonActionHandler.class)})
// или с описанием:
//  @Button(labels = "Label", description = "Hint text", handler = MyButtonActionHandler.class)
public class MyModel implements Model { ... }
```

Импорт `Button` и хендлера добавить в алфавитном порядке среди других com.* импортов (checkstyle).
Несколько кнопок — несколько `@Button` в массиве.

---

## Существующие хендлеры (эталоны)

| Класс | Режим | Что делает |
|---|---|---|
| `RefillCacheButtonActionHandler` | простой | Инвалидирует весь `MONETIZATION_TOOL` кеш |
| `RefillNewsCacheButtonActionHandler` | простой | Инвалидирует `COMMUNITY_NEWS` кеш |
| `RefillSplitCacheButtonActionHandler` | простой | Инвалидирует `SPLIT_CONFIGURATION` кеш |
| `PrintCacheButtonActionHandler` | простой | Дампит все записи `Cache` в лог |
| `PrintModelCacheButtonActionHandler` | простой | Дампит `ModelCache` (классы + id) в лог |

---

## Паттерн: инвалидация кеша для конкретной модели (11 шагов)

Применять когда нужна отдельная кнопка для инвалидации и прогрева кеша одной модели.
Эталон для копирования: `CommunityNews*` классы (самая чистая реализация).

**Шаг 1 — Cache.Tag**
`klone-mobile-server/src/.../guice/interceptor/cacheable/cache/Cache.java`
Добавить в enum `Tag` без TTL: `MY_FEATURE,`

**Шаг 2 — Entity**
Пакет: `offers.persistence.entity`
`@Data class MyFeatureCacheEntity { private String myFeatureState; }`

**Шаг 3 — DAO**
Пакет: `offers.persistence.dao`
Extends `AbstractEntityDao<MyFeatureCacheEntity>`. Ключ — `"MY_FEATURE_CACHE_ENTITY"`.
`load()` создаёт entity если `super.load() == null`.
Эталон: `CommunityNewsConfigurationDAO`

**Шаг 4 — Provider interface**
Пакет: `offers.provider.configuration`
`interface MyFeatureCacheProvider { void setMyFeatureStateVersion(String v); }`

**Шаг 5 — Provider impl**
Пакет: `offers.provider.configuration.impl`
`@Bean(scope = Scope.SINGLETON, to = MyFeatureCacheProvider.class)`
Загружает entity → ставит значение → сохраняет.
Эталон: `CassandraCommunityNewsConfigurationProvider`

**Шаг 6 — Service interface**
Пакет: `offers.services.configuration.myfeature`
`interface MyFeatureCacheServices { void updateMyFeatureVersion(); }`

**Шаг 7 — Service impl**
Пакет: `...myfeature.impl`
`@Bean(scope = Scope.SINGLETON, to = MyFeatureCacheServices.class)`
Генерирует `UUID.randomUUID().toString()` → передаёт в Provider.
Эталон: `CommunityNewsConfigurationServicesImpl`

**Шаг 8 — ChangeListener**
Пакет: `offers.persistence.dao`
Implements `EntityDao.ChangeListener<MyFeatureCacheEntity>`.
`@PostConstruct` → `dao.addChangeListener(this)`.
В `onEntityChange` (только если поле не null):
```java
cache.remove(Cache.Tag.MY_FEATURE);
dynamicItemCacheComposer.compose();
serverStateConfigurationProvider.currentModel().setToolHash(entity.getMyFeatureState());
```
Зависимости: `Cache`, `MyFeatureCacheDAO`, `DynamicItemCacheComposer`, `ServerStateConfigurationProvider`.
> `ToolConfigurationChangeListener` дополнительно вызывает `container.refillProcessorsContainer()` — только для offers (платёжные провайдеры). Для новых цепочек не нужно.

**Шаг 9 — ButtonActionHandler** (см. базовую структуру выше)

**Шаг 10 — @Cacheable на DynamicItemsProvider**
Добавить тег рядом с `MONETIZATION_TOOL`:
```java
@Cacheable(tags = {Cache.Tag.MONETIZATION_TOOL, Cache.Tag.MY_FEATURE})
```
Гарантирует: кнопка offers чистит всё (без регрессии), кнопка MY_FEATURE — только свой кеш.

**Шаг 11 — кнопка на модели** (см. регистрацию выше)

### Ключевые инварианты кеш-цепочки
- UUID — сигнал об изменении, само значение смысла не несёт
- Прогрев сразу после инвалидации в `onEntityChange` (eager, не lazy)
- `compose()` вызывает `allItems()` на ВСЕХ `DynamicItemsProvider` — незатронутые вернут из кеша мгновенно
- `ChangeListener` срабатывает на каждом узле кластера (Hazelcast propagation)
