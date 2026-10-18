---
name: model-mapper-provider-validator
description: Добавление новой сущности в монетизационную тулу: Model, Mapper, CassandraProvider, Validator. Использовать при добавлении любой сущности с управлением через веб-интерфейс, не обязательно OfferItem. Для наследника OfferItem нужен дополнительно скилл naslednik-offera-v-tyly.
---

# Сущность в монетизационной туле

## Когда применять

Нужно управлять игровой сущностью (`XItem`) через веб-тулу: CRUD, валидация при сохранении,
кеширование. Источник данных — Cassandra через `ModelProvider`.

Если `XItem` — наследник `OfferItem`, этого скилла **недостаточно**: у офферов есть своя
дельта (правка самого айтема, специфичные поля модели, порядок маппинга, Soft Launch кнопки) —
см. скилл `naslednik-offera-v-tyly`.

---

## Каркас: Model → Mapper → Provider → Validator

Все четыре шага с шаблонами кода, сигнатурами и ловушками:

**[`~/.claude/skills/model-mapper-provider-validator/references/tool-entity-skeleton.md`](references/tool-entity-skeleton.md)**

Это общий файл — на него же ссылается `naslednik-offera-v-tyly`. Правки вносить только туда,
чтобы два скилла не разъезжались.

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

Канонический провайдер, с которого снят шаблон в общем файле —
`offers/provider/offer/impl/CassandraOfferItemProvider.java`. При любом расхождении верь ему.

---

## Порядок работы

1. Прочитать эталонные файлы своей сложности из таблицы выше.
2. Пройти четыре шага каркаса по общему файлу.
3. Определить, нужны ли `CrossVersionItemProvider` (экстракция ресурсов) и `extractInnerItems`
   (только при вложенных айтемах).
4. Выбрать кеш-тег: `MONETIZATION_TOOL` — дефолт; `COMMUNITY_NEWS` — только новости.
5. Кнопки на модели, если нужны — скилл `knopki-dlya-modeli`.
6. **Обязательно — скилл `klone-tool-entity-on-client`.** Серверным каркасом работа
   не заканчивается: доставка айтема, патчинг заглушек, ресурсы, платежи и биллинг
   живут вне серверного модуля и не ловятся ни компиляцией, ни тестами.

---

## Связанные скиллы

- `naslednik-offera-v-tyly` — офферная дельта поверх этого каркаса
- `knopki-dlya-modeli` — `TableButtonActionHandler` и цепочка инвалидации кеша тулы
- `klone-cacheable-interceptor` — как устроен `@Cacheable` и инвалидация по тегам
- `klone-tool-entity-on-client` — обязательное продолжение: что доделать за пределами сервера
