---
name: pyramid-roulette
description: Пирамидальная рулетка (PyramidRouletteFeature) в klone-mobile — устройство фичи, её файлы на сервере, в туле монетизации, правила ГДД и ловушки. Используй при любой правке пирамиды: ряды и награды, цены спинов, прогресс-бар, статистика, настройка из монетизационной тулы, soft launch, разбор багов по ней.
---

# Пирамидальная рулетка

Рулетка, где награды разложены по рядам. Игрок крутит только пул своего ряда; выбив
награду с `levelUp`, поднимается на ряд выше. Ряд с главным призом закрывает пирамиду,
следующий за ним начинает новую. Спины стоят токенов, реала или бесплатны — цена задаётся
на ряду и зависит от номера спина в нём.

Фича размазана по пяти местам, и это её главная сложность. Ниже — карта, инварианты
и грабли. Что именно делает класс — смотри в его джавадоке, здесь этого нет специально.

## Карта файлов

Все пути от корня репы. Серверные — в `klone-mobile-server/src/com/social/game/klonemobile/`.

**Рантайм (стейт игрока и обработка спина)**
- `game/feature/randomprize/pyramid/PyramidRouletteFeature.java` — стейт: индекс активного
  ряда, список выбитых наград, прогресс-бар. Наследник `PurchasableSpinFeature`
  (`game/feature/randomprize/PurchasableSpinFeature.java`) — оттуда покупка спина за реал.
- `game/feature/randomprize/pyramid/event/PyramidRouletteEventHandler.java` — вся логика
  спина: выбор награды, оплата, выдача призов, переход ряда, прогресс-бар, стата,
  завершение фичи. Экшен от клиента — `pickPyramidPrize`.
- `game/feature/randomprize/pyramid/event/PyramidRouletteEvent.java` — пакет клиент↔сервер.
- `game/feature/randomprize/pyramid/PyramidRouletteStatSender.java` — статистика.

**Конфиг (айтемы, общие для клиента и сервера)**
- `items/feature/PyramidRouletteFeatureItem.java` — конфиг фичи, вся валидация формы
  пирамид в `postConstruct`.
- `items/feature/RouletteRoundItem.java` — ряд: пул наград и прогрессия цен. Общий
  с `RandomGiftFeatureItem`, правки задевают обе фичи.
- `items/AwardItem.java` — награда, флаги `levelUp` и `grandPrize`.
- `items/feature/AutoOpenMode.java` — режим автооткрытия окна, общий с `RandomGiftFeatureItem`.

**Монетизационная тула (фича настраивается из БД, XML в репе нет)**
- `offers/model/features/pyramid/PyramidRouletteFeatureModel.java` — модель диалога настройки.
- `offers/mapper/PyramidRouletteModelToItemMapper.java` — модель → айтем фичи, включая ряды.
- `offers/mapper/PyramidRouletteModelToFeatureContainerItemMapper.java` — модель → контейнер
  (расписание, сегменты, триггеры).
- `offers/provider/CassandraPyramidRouletteItemProvider.java` — отдаёт настроенные фичи в игру.
- `offers/services/validator/features/PyramidRouletteValidator.java` — проверки при сохранении.
- `offers/services/instances/PyramidFeatureModelInstanceProvider.java` — заготовка новой фичи.
- `offers/handler/button/dialog/PyramidRouletteSoftLaunchButtonHandler.java` — тестовый запуск
  на устройстве менеджера, минуя БД.

**Прочее на сервере**
- `statistics/StorageAddOrigin.java` — `PYRAMID_ROULETTE_FEATURE`, `PYRAMID_ROULETTE_PROGRESS_BAR`.
- `game/progressbar/` — `ProgressBarOwner`, `ProgressPointService`, `ProgressBarProducer`:
  сквозной прогресс-бар фичи.

**Тесты** — `klone-mobile-server/test/.../pyramid/PyramidRouletteFeatureTest.java`,
`PyramidRouletteStatSenderTest.java`, `.../items/feature/PyramidRouletteFeatureItemTest.java`.

## Инварианты ГДД

Нарушение любого — исключение валидации на старте сервера или при сохранении из тулы,
а не тихая деградация. Все проверки живут в `postConstruct` айтемов.

- Пирамида — от 3 до 5 рядов и **не расширяется кверху**: в ряду не больше наград,
  чем в ряду под ним.
- Вершина пирамиды — ряд ровно с **одной** наградой, у которой `grandPrize=true`.
  Больше одного `grandPrize` в ряду запрещено.
- **Последний ряд фичи обязан быть вершиной.** Иначе последняя пирамида никогда
  не завершится и фича повиснет.
- Список рядов плоский и сквозной через все пирамиды фичи; отдельной сущности пирамиды нет.
  Границы определяются рядами-вершинами. Клиенту координаты (`pyramidIndex`, `rowIndex`)
  проставляет сам айтем при валидации.
- В ряду число цен равно числу наград: спин выбивает ровно одну награду, поэтому
  спинов в ряду не может быть больше, чем наград.
- В каждом не-вершинном ряду должна быть хотя бы одна награда с `levelUp`, иначе
  из ряда нет выхода.
- Токен обязателен, только если хотя бы один спин продаётся за токены.
- Прогресс-бар необязателен. Он **сквозной через все пирамиды** и двигается на один шаг
  на каждый переход ряда, а не на каждый спин. Поэтому вес чекпоинта — это номер перехода,
  и он не может превышать число рядов фичи.

## Грабли

- **Номер спина в ряду нигде не хранится.** Он равен числу выбитых в этом ряду наград
  (`spinsDoneInRound`), потому что спин всегда выбивает ровно одну. Не заводи отдельный
  счётчик — разъедется со стейтом.
- **У фичи два разных `StorageAddOrigin`, и они не взаимозаменяемы.**
  `getStorageAddOrigin()` → `PYRAMID_ROULETTE_FEATURE` («Pyramid Roulette»): награды ячеек,
  списание токенов, а ещё покупки паков через `BuyHandler` и
  `FeaturePackToPaymentProcessorMapper` — они дёргают этот метод через `PurchasableFeature`.
  `getProgressBarStorageAddOrigin()` → `PYRAMID_ROULETTE_PROGRESS_BAR` («Pyramid Roulette
  Progress Bar»): только награды чекпоинтов, его зовёт `ProgressPointService.pickPrizes`.
  Свести их в один метод нельзя — аналитика считает эти начисления раздельно.
- **Статистика шлётся под именами событий обычной рулетки** — `Random Gift Feature Started`
  и `Random Gift Feature Box Opened`. Это не копипаста: для аналитики пирамида — ещё один
  тип рулетки, различает их `feature_type = PYRAMID_ROULETTE`. Не переименовывай.
- **Цена спина в стату берётся из `ActionPrice`, а не из состояния фичи.** К моменту
  отправки оплаченный продукт уже сброшен списанием, и `getBoughtProduct()` пуст.
- **`attempt_number` сквозной по всей фиче** — не сбрасывается ни на переходе ряда,
  ни на новой пирамиде.
- **Бесплатный спин — значения, которых у обычной рулетки нет:** `open_currency = "FREE"`
  (капсом), `open_cost = "0"`, а в `feature_currency_list` тот же способ оплаты записан
  строчными — `free`. Разнобой регистра сделан по ТЗ аналитиков, а не по ошибке.
- **Награда выбирается до списания.** Пустой пул означает рассинхрон стейта и конфига,
  и ловить его надо до того, как с игрока что-то снято.
- **Вероятности после спина не пересчитываются вручную.** Выбитая награда просто уходит
  из пула, и веса перераспределяются сами — это и есть требование ТЗ.
- **`RouletteRoundItem` и `AutoOpenMode` общие с `RandomGiftFeatureItem`.** Правка задевает
  обе фичи, проверять надо обе.
- **Мапу статистики собирай обычным `HashMap`.** Фреймворк (`GameSession.addPeruserStatsEvent`)
  дописывает в неё `game_time` — immutable-мапа приводит к defensive copy, а `null`
  в `expiration_time` на ней падал бы NPE.

## Типовые правки

**Новое поле в статистику** — `PyramidRouletteStatSender`, плюс тест в
`PyramidRouletteStatSenderTest`. Поля `game_time` фреймворк добавляет сам, руками не надо.

**Новый тип награды** — флаг в `AwardItem`, обработка в `rewardType()` сендера, учёт
в переходе ряда (`handleRoundTransition` хендлера) и в валидации ряда. Помни про приоритет:
`grandPrize` перекрывает `levelUp`.

**Новое поле конфига** — цепочка целиком: `PyramidRouletteFeatureItem` (+ валидация
в `postConstruct`), `PyramidRouletteFeatureModel`, `PyramidRouletteModelToItemMapper`,
при необходимости `PyramidRouletteValidator` и патчинг в `DynamicItemsManualPatcher`.
Пропуск маппера — самая частая ошибка: поле молча приезжает пустым из тулы.

**Отладка «фича не стартует»** — сначала валидация: исключение из `postConstruct` айтема
или из валидатора тулы. Потом приватность на клиенте (`PermissionUtils`) — без трёх
разрешений фича не покажется вообще.
