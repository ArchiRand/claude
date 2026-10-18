---
name: battlepass-energypass
description: Руководство по работе с Battle Pass (БП) и Energy Pass (ЭП) в klone-mobile-server. Используй этот скил всегда, когда задача связана с БП или ЭП: добавление нового типа задания, настройка стадий наград, конфигурация commonPickup, слоты, infinityMode, покупка пропуска, конвертация очков, кастомизация верстки — любые изменения в XML или серверной логике этих сущностей.
---

# BattlePass / EnergyPass Skill

## Архитектурный обзор

БП и ЭП — это **адвенчуры** (`adventure`), реализованные через одну и ту же сущность `battlePass id`.
Тип определяется полем `belong` — у него **три** значения: `BATTLE_PASS`, `ENERGY_PASS`
и `TRADE_COMPANY` (третий используется в торговой компании, к БП/ЭП не относится, но
разветвляет логику статистики).

Два класса на одну сущность, как и у офферов:

| Класс | Путь | Роль |
|---|---|---|
| `BattlePassItem` | `items/BattlePassItem.java` | Конфиг из XML, неизменяемый. Реализует `WebShop.Offer` |
| `BattlePass` | `objects/BattlePass.java` | Runtime в стейте игрока. `extends Component`, реализует `WebShop.Offer.Adapter` |

```
adventures.xml
└─ <adventure id="ADVENTURE_BATTLE_PASS_XXX" specialAdventure="true">
       <dateRange reference="DR_BATTLE_PASS_XXX"/>
       <tabs>
           <item reference="BP_XXX_TASKS"/>      ← вкладка заданий (только БП)
           <item reference="BP_XXX_TAB"/>        ← вкладка наград
       </tabs>

battle_pass/items.xml  (или energy_pass/items.xml)
└─ <battlePass id="BATTLE_PASS_XXX" belong="BATTLE_PASS">   ← конфиг наград
       <stage count="N"> ... </stage>
       <infinityMode ...> ... </infinityMode>
```

---

## Ключевое различие БП vs ЭП

| | БП | ЭП |
|---|---|---|
| `belong` | `BATTLE_PASS` | `ENERGY_PASS` |
| Источник прогресса | Генерируемые задания (`advance_generate_tasks_board.xml`) | Трата энергии на вырубку → commonPickup (1 жетон ≈ 8 энергии) |
| Вкладка заданий | Есть (`advanceGenerateTasksBoardAdventureTab`) | Нет |
| Длительность | ~15 дней | ~8–15 дней |
| Доступен с уровня | 9 | 5 (задания с 9) |
| Название пропуска | Золотой компас | Золотая печать |
| `resized` | Нет | Опционально (`true` для новых верстков) |
| `backIcon` | Нет | Есть (подложка HUD с прогресс-баром) |
| `collectedItemIcon` | Иконка очков заданий | Иконка жетона удачи |

---

## XML: обязательные поля `<battlePass>`

```xml
<battlePass id="BATTLE_PASS_XXX"
    belong="BATTLE_PASS"                          <!-- BATTLE_PASS | ENERGY_PASS -->
    collectedItemIcon="battlepass_sun_coin.png"   <!-- иконка очков -->
    hudIcon="bp_icon_xxx_golden.png"              <!-- иконка HUD после покупки пропуска -->
    name="Золотой компас"                         <!-- название пропуска -->
    notAvailableHint="Доступно для владельцев..." <!-- балун закрытого VIP-слота -->
    buyPeriodExpiredHint="Событие завершается..."> <!-- текст за 5 мин до конца -->

    <vipAccessRealMoneyPrice reference="premium_access_golden_compas_pass"/>
    <collectItem reference="BATTLEPASS_EVENT_POINTS"/>

    <!-- стадии наград -->
    <stage count="0"> ... </stage>
    <stage count="50"> ... </stage>
    ...
</battlePass>
```

### Дополнительные поля только для ЭП

```xml
<battlePass ... belong="ENERGY_PASS"
    backIcon="energy_pass_common_back.png"   <!-- подложка HUD-иконки с прогресс-баром -->
    resized="true">                          <!-- для увеличенных верстков; только ЭП -->
```

### Опциональные поля кастомизации (оба типа)

| Параметр | Назначение |
|---|---|
| `backgroundColor` | Цвет фона окна покупки пропуска |
| `layoutId` | Верстка окна покупки пропуска |
| `slotsLayoutId` | Верстка слотов |
| `rewardLayoutId` | Верстка главной награды / пьедестала |
| `passBoughtLayoutId` | Верстка окна после покупки |
| `infoLayoutId` | Верстка окна "Как играть" |
| `startWindowLayoutId` | Верстка стартового окна |
| `rewardsTabLayoutId` | Верстка вкладки наград (только БП) |
| `infinitySafe="true"` | Бесконечный режим показывается через сейф. Применяется и в БП, и в ЭП. При нём `commonPrize` из `infinityMode` не используются — только `vipPrize` |

---

## Стадии наград `<stage>`

```xml
<stage count="150">   <!-- накопительный порог collectItem для открытия стадии -->
    <commonSlot id="BP_7">               <!-- бесплатный слот; id оканчивается на _N по возрастанию -->
        <prize count="3">
            <item reference="CASH"/>
        </prize>
        <!-- или: <prizesContainer reference="CONTAINER_ID"/> -->
    </commonSlot>
    <vipSlot id="BP_VIP_7"              <!-- платный слот -->
             special="true"             <!-- диспенсер остается виден после сбора -->
             icon="dispenser_icon.png"> <!-- иконка для пьедестала (вместо shopImage) -->
        <prize count="1">
            <item reference="B_DISPENSER_XXX"/>
        </prize>
    </vipSlot>
</stage>
```

**Критичные правила:**
- `stage count` — **накопительное** количество очков, не дельта между стадиями.
- Первая стадия всегда `count="0"` — игрок получает её без очков.
- ID слотов **уникальны** в рамках всего БП/ЭП, суффикс после последнего `_` должен парситься
  как число.
- Стадии должны идти по **возрастанию** `count`, а суффиксы слотов — по возрастанию номера.

**Что из этого реально проверяет сборка** (важно, чтобы не искать несуществующую ошибку):

`BattlePassItem.postConstruct()` падает только на: пустом списке `stages`; а также — **только если
задан `infinityMode`** — на дубликатах id слотов (`checkDuplicateIdSlots`) и на непарсящемся
числовом суффиксе (`checkPatternIdSlots`).

**Возрастание порядка НЕ валидируется.** Сервер соберётся, но сломается рантайм:
- `calculateMaxNeedAmount()` берёт `count` **последней** стадии как максимум прогресс-бара —
  если стадии не по возрастанию, максимум будет неверным и БП завершится раньше или позже срока;
- `generateNewId(lastId)` инкрементирует номер **последнего** слота — при нарушенном порядке
  сгенерированный id может совпасть с существующим.

То есть без `infinityMode` дубликаты id вообще никто не поймает на сборке.

---

## Бесконечный режим `<infinityMode>`

Включается после последней стадии. Генерирует случайные награды из пула.

```xml
<!-- Обязательно добавить configString для балуна закрытой награды -->
<configString id="DESCRIPTION" value="Награда откроется, когда ты соберёшь предыдущую"/>

<infinityMode baseIncrement="200" increment="25" repeatPrize="4">
    <!-- бесплатные призы: случайный из списка -->
    <commonPrize item="ENERGY" minCount="140" maxCount="160"/>
    <commonPrize item="CR_GOLD_GEAR" minCount="15" maxCount="15"/>

    <!-- VIP-призы: случайный из списка -->
    <vipPrize item="BOMB_01" minCount="2" maxCount="2"/>
    <vipPrize item="ENERGY" minCount="240" maxCount="260"/>
</infinityMode>
```

| Параметр | Значение |
|---|---|
| `baseIncrement` | База прироста порога для каждого генерируемого этапа |
| `increment` | Множитель, растущий с числом уже сгенерированных этапов |
| `repeatPrize` | Сколько генераций не повторяется один и тот же предмет |

**Формула порога** (`generateStageCount()`):

```
первый генерируемый этап:  count последней предефайненой стадии + baseIncrement + increment
последующие:               count последнего сгенерированного   + baseIncrement + increment * (stages.size() + 1)
```

То есть шаг между наградами не постоянный, а растущий — чем дальше в бесконечном режиме,
тем дороже следующая награда.

**Правила minCount/maxCount**: оба > 0, `minCount <= maxCount`.

---

## Типы заданий БП (advance_generate_tasks_board.xml)

Каждый тип задания — отдельный XML-тег с обязательными полями: `id`, `image`, `hint`, `description`, `reward`.

### Базовые (домашняя локация)

| Тег | Что делает игрок |
|---|---|
| `pick` | Сбор урожая / крафт на фабриках |
| `destroy` | Рубка/выкопка объектов (тратит энергию) |
| `craftTask` | Производство айтемов/энергии |
| `removeStorageItems` | Трата предмета на производство |
| `addXp` | Получение опыта |
| `addEnergyTask` | Получение энергии из источников (`originType`) |
| `orderTask` | Выполнение заказов на доске заказов |

### Ивентовые (с `requireEventLocation` и `finishEventTaskTimerDuration`)

| Тег | Что делает игрок |
|---|---|
| `destroyOnEvent` | Рубка/открытие объектов на ивентовой локации |
| `pickPickupOnEventTask` | Получение айтемов из пикапов на ивенте |
| `addRestartableItemTask` | Получение валюты в Машине времени |
| `completeEventMissionTask` | Выполнение квестов на ивентовых локациях |
| `spendEnergyOnEvent` | Трата энергии на ивентовых локациях |
| `rotateRouletteOnEvent` | Вращение рулетки |
| `updateRatingPoints` | Получение очков рейтинга |

### Микроцели (доступны с 9 уровня)

| Тег | Что делает игрок |
|---|---|
| `microGoalCompleteTask` | Выполнение микроцелей |
| `microGoalPointsTask` | Получение очков в микроцелях |

### Параметры ивентовых заданий

```xml
<destroyOnEvent id="..." ... 
    requireEventLocation="true"          <!-- засчитывать только на ивентовых локациях -->
    finishEventTaskTimerDuration="3h"    <!-- автозакрытие после закрытия ивент-локации -->
    helpMessage="Текст если нет хелпера">
    <help automatic="true"/>
    <item reference="ITEM_ID"/>
</destroyOnEvent>
```

**Важно:** `finishEventTaskTimerDuration` требует `requireEventLocation="true"`. Для заданий, которые можно выполнять и на домашней, и на ивентовых локациях — не указывать.

---

## Структура `<adventure>` в adventures.xml

```xml
<adventure id="ADVENTURE_BATTLE_PASS_XXX"
    minLevel="9"
    viewId="adventure_halloween22_decor"
    specialAdventure="true">             <!-- true = отдельная иконка на HUD -->

    <dateRange reference="DR_BATTLE_PASS_XXX"/>
    <convertAfterClose reference="BATTLE_PASS_XXX_CONVERSION"/> <!-- опционально -->
    <tabs>
        <item reference="BP_XXX_TASKS"/> <!-- вкладка заданий (только БП) -->
        <item reference="BP_XXX_TAB"/>   <!-- вкладка наград -->
    </tabs>
    <configString id="SHOW_ADVENTURE_TIMER"/>
    <configString id="HUD_ICON" value="bp_icon_xxx.png"/>  <!-- бронзовая иконка до покупки -->
</adventure>
```

---

## Серверная логика

### Жизненный цикл `BattlePass`

Объект живёт не сам по себе, а внутри вкладки адвенчуры — `BattlePassAdventureTab`:

```
BattlePassAdventureTab.onStart() / initActive()
    → initBattlePass()
        eventController.createComponent(item.getBattlePass())   ← создание
        eventController.initComponent(battlePass)               ← BattlePass.init(session)
        battlePass.initListeners()                              ← подписки
```

`BattlePass.init(session)`:
1. Резолвит `price` через `getVipAccesPrice()` — если заданы `vipAccessDiscountPrice` и
   `discountProbability`, бросается кубик: `Math.random() * 100 < discountProbability` → цена
   со скидкой. **Цена фиксируется в стейте при первом ините** и дальше не пересчитывается.
2. Создаёт `BattlePassStatistics`.
3. Регистрирует все слоты в `PrizesContainersManager`.
4. Миграционный хотфикс `vipPresented`: если пропуск уже куплен, а флаг ещё `null` и покупка
   не внешняя — гасит флаг, чтобы окно начисления не всплыло задним числом тем, кто купил
   пропуск до появления механики. Исключение для `externalPurchase`: покупка из вебшопа
   совершается вне игры, окна игрок не видел, и показать его нужно при следующем заходе.
   (Проверка версии клиента `V_2_149` из условия убрана — в релизе таких клиентов больше нет.)

`simpleInit(session)` — урезанный инит **только для платежа вне игровой сессии** (вебшоп):
ставит сессию и `initRealMoneyListener()`, больше ничего. Не путать с `init()`.

### Накопление очков и открытие стадий

Ядро — `initCompletedListener()`, слушатель `KloneSessionEvent.Type.ADD_STORAGE`:

```
на склад пришёл айтем
    → item.getCollectItem().equals(event.getItem())?  ← фильтр по айтему прогресса
        statistics.addStats(count)
        collected += count
        maxNeedAmount = calculateMaxNeedAmount()      ← count последней стадии
                                                        (или последней сгенерированной)
        collected >= maxNeedAmount?
            infinityMode задан → do { generateStage(); saveStageInState(); 
                                      addEvent(ACTION_SEND_STAGE) }
                                 while (collected >= stage.count)   ← догоняем в цикле
            иначе              → notifyListeners(); complete(reason)
```

Цикл `do/while` важен: если игрок за раз получил очков больше, чем стоит следующий этап,
генерируется столько этапов, сколько нужно, чтобы порог обогнал `collected`.

`complete(reason)` идемпотентен: выставляет `completed = true` и **снимает** слушатель
`ADD_STORAGE`. После завершения очки больше не капают.

### Ключевые поля стейта (`BattlePass`)

| Поле | Что хранит |
|---|---|
| `collected` | Накоплено очков `collectItem` |
| `vip` | Пропуск куплен |
| `vipPresented` | Окно начисления (`PassBoughtWindow`) игроку **уже показано**. Гасится по `ACTION_SHOW_ACCESS` от клиента. Тип `Boolean` ради миграции: `null` = стейт из времён, когда механики окна не было |
| `completed` | БП завершён, слушатель снят |
| `processedSlots` | ID собранных слотов |
| `flippedSlots` | ID слотов с проигранной анимацией переворота. `final` + `@Getter`, но **сохраняется в базу** — `final` сериализации не мешает |
| `stages` | Сгенерированные этапы бесконечного режима |
| `lastViewedCheckpoint` | До какого чекпоинта доскроллил игрок |
| `price` | Зафиксированная цена пропуска (со скидкой или без) |
| `externalPurchase` | `@ModelIgnore` + `@JsonView(Full)` — покупка пришла извне (вебшоп) |

Поля с `@JsonIgnore` (`session`, `statistics`, `prizesContainersManager`, оба слушателя,
`uncollectedPrizes`) в базу не сохраняются — восстанавливаются при ините.

### Покупка пропуска — две ветки

| За что | Точка входа | Механизм |
|---|---|---|
| Внутриигровая валюта | `processActionBuyAccessEvent()` (`ACTION_BUY_ACCESS`) | `canRemoveStorageItem` → `removeStorageItem` → `vip = true`. Нет `vipAccessPrice` или не хватает средств → `errorWithClientAndTerminate` |
| Реальные деньги | `initRealMoneyListener()` | Слушает `REAL_PAYMENT_COMPLETE`, сверяет айтем с `vipAccessRealMoneyPrice` → `vip = true`, снимает слушатель. При `externalPurchase` и клиенте ≥ `V_2_149` дополнительно диспатчит `BattlePassEvent.ACTION_BOUGHT` |

Регистрация платёжного процессора для `vipAccessRealMoneyPrice` (это `AccessProductItem`) —
не здесь, а в скилле `klone-feature-pack-purchase-flow`, раздел «Путь 2 — AccessProductItem».

### Сбор наград

`processActionPickupSlotsEvent` / `processActionClaimEvent` → `pickupSlots(stages, ...)` →
`checkProcessedSlot` → `pickupSlotPrize` → `addPrizeGiftToStorage`.
Автосбор открытых-но-не-забранных слотов происходит при завершении события (локации),
недобранное уезжает в `UncollectedRewards`.

`canBeFinished()` / `containUnprocessedPrizes()` — можно ли гасить БП: если остались
необработанные призы, завершать нельзя.

### Конвертация очков после закрытия

`convertAfterClose` — атрибут **не самого `battlePass`**, а `LocationItem`. Обрабатывается в
`KloneGameState` (~4660): `locationItem.getConvertAfterClose()` → `storageConverter
.checkConversions(convertGroup, StorageConversion.TYPE_LOCATION_CLOSED, locationItem)`.
То есть остатки `collectItem` конвертируются механизмом конвертации склада при закрытии
локации, а не логикой БП.

---

## Файлы

```
klone-mobile-server/src/com/social/game/klonemobile/
  items/
    BattlePassItem.java                  ← конфиг из XML: stages, InfinityMode,
                                           BuyWindowConfig, enum Belong, postConstruct-валидация
    BattlePassCompositionItem.java       ← конфиг БП, живущего на объекте локации
    adventure/BattlePassAdventureTabItem.java  ← конфиг вкладки адвенчуры
  objects/
    BattlePass.java                      ← runtime-объект в стейте игрока (основной класс)
    BattlePassComposition.java           ← БП на объекте локации + таймер и нотификация
  game/adventure/
    BattlePassAdventureTab.java          ← создаёт и инитит BattlePass внутри адвенчуры
  events/
    BattlePassEvent.java                 ← клиентские экшены (claim, buyAccess, pickupSlots, sendStage)
    BattlePassAdventureEvent.java
  statistics/
    BattlePassStatistics.java            ← статистика прогресса
    gamedata/content/PassGameData.java, PassStepsGameData.java
    gamedata/creators/PassGameDataCreator.java
  items/conditions/
    BattlePassCompositionFinishedCondition.java
    PassTabActiveCondition.java
  items/gametask/
    BattlePassFinishedTaskItem.java      ← задание «завершить БП»
  external/webshop/
    provider/offer/impl/BattlePassAsWebshopOfferProvider.java   ← БП как оффер вебшопа
    service/configurator/impl/BattlePassProductDataConfigurator.java
    interfaces/PassDetailsInfo.java, model/PassDetails.java
  gamestate/hotfixes/
    BattlePassPrizesHotfix.java

klone-common/res/items/release/
  battle_pass/items.xml                  ← конфиги БП
  energy_pass/items.xml                  ← конфиги ЭП
  adventures.xml                         ← adventure-обёртки
  advance_generate_tasks_board.xml       ← типы заданий БП
```

> Продажа БП/ЭП в вебшопе — отдельный скилл `custom-gameobject-v-webshop`
> (паттерн интеграции не-`OfferItem` объекта). Покупка пропуска как `AccessProductItem` —
> `klone-feature-pack-purchase-flow`.

---

## Частые ошибки

| Проблема | Следствие |
|---|---|
| ID слотов не уникальны, при заданном `infinityMode` | Сервер не собирается (`checkDuplicateIdSlots`) |
| ID слотов не уникальны, `infinityMode` не задан | **Сборка проходит**, ловится только рантаймом — `getSlotById` найдёт первый совпавший |
| Стадии не по возрастанию `count` | **Сборка проходит**, но `calculateMaxNeedAmount` берёт последнюю стадию как максимум → БП завершится не вовремя |
| `finishEventTaskTimerDuration` без `requireEventLocation="true"` | Некорректная работа таймера |
| `resized="true"` в БП | По коду не запрещено (обычный `Boolean` на `BattlePassItem`), но по договорённости используется только в ЭП — уточняй у пользователя, а не считай ошибкой |
| `minCount > maxCount` в infinityMode | Сервер не собирается |
| `configString id="DESCRIPTION"` не добавлен при включённом infinityMode | Балун закрытой награды пустой |
| `belong` в нижнем регистре | Значение не распознаётся |
| `microGoalCompleteTask`/`microGoalPointsTask` генерируется до инициализации вкладки микроцелей | Задание не должно генерироваться |
| `special="true"` не указан на слоте с диспенсером | Диспенсер пропадает из слота после сбора |

---

## Чеклист нового БП/ЭП

- [ ] Уникальный `id` для `adventure`, `battlePass`, всех `commonSlot`/`vipSlot`
- [ ] `belong` указан в верхнем регистре (`BATTLE_PASS` / `ENERGY_PASS`)
- [ ] ID слотов с числовыми суффиксами по возрастанию
- [ ] `stage count="0"` — первая стадия
- [ ] `special="true"` и `icon` на слоте главной награды (диспенсер)
- [ ] `vipAccessRealMoneyPrice` и `collectItem` настроены
- [ ] Если `infinityMode` — добавлен `configString id="DESCRIPTION"`, все `minCount <= maxCount`
- [ ] Если `finishEventTaskTimerDuration` — добавлен `requireEventLocation="true"`
- [ ] HUD-иконка до покупки — в `configString id="HUD_ICON"` в adventures.xml
- [ ] HUD-иконка после покупки — в `hudIcon` в items.xml
- [ ] `dateRange` настроен в date_ranges.xml
- [ ] Пропуск (`vipAccessRealMoneyPrice`) настроен в products.xml в группе `access_products`
- [ ] Для ЭП: `backIcon` указан, `resized` только если новая верстка
- [ ] Для БП: вкладка заданий (`BP_XXX_TASKS`) подключена в tabs

---

## Мультипассы — третья линейка (KA-54427)

> **Статус: сделано в ветке `KA-54427-multipass-server` (репа №2), в `develop` ещё нет.**
> Пока ветка не влита, всё описанное выше про две линейки верно как есть.

Коротко, что меняется, когда ветка приедет:

- Признак режима — `diamondAccessRealMoneyPrice` у `battlePass`. Задан → мультипасс, и тогда
  **обязательны** `diamondSlot` в каждой стадии, `diamondPrize` при `infinityMode` и
  `buyWindowConfig` с двумя списками по 7 `showReward`. Не задан → всё алмазное запрещено.
  Оба формата живут в айтеме постоянно: сервер держит наборы айтемов под разные версии клиента,
  плюс A/B гоняет обе конфигурации на одной версии.
- Платные линейки **независимы**: в стейте рядом с `vip` появляется `diamond` (тип `Boolean`,
  чтобы поле не уезжало старому клиенту). Читать и писать — только через
  `isLineBought(PassLine)` / `setLineBought(PassLine, boolean)`.
- Один платёжный listener на оба продукта; снимается только когда куплены **все** настроенные
  линейки. У алмазной линейки нет аналога `vipAccessPrice` — она продаётся только за реал.
- `exclusiveBonuses` — временные бонусы, выдаются при покупке линейки. Тип задаётся тегом:
  `avatarFrameBonus` (ссылка на `avatarFrameWrapper`) и `vipTasksAccessBonus` (ничего не выдаёт,
  это условие доступа к VIP-заданиям). Срок жизни ведёт сам бонус, пасс его не отслеживает.
- Доступ к VIP-заданиям теперь читается из бонусов купленных линеек
  (`AdvanceGenerateTaskBoard.hasVipTasksAccessBonus`). У пассов **без блока** `exclusiveBonuses`
  доступ по-прежнему открывает сама покупка — старый контент не ломается.
- `infinitySafe` в мультипассе **запрещён** валидацией: автосбор генерируемых стадий завязан
  на золотую линейку, и покупатель одной алмазной терял бы призы.
- Мультипасс **не отдаётся в вебшоп** — отфильтрован в `BattlePassAsWebshopOfferProvider`.
  Поддержка вебшопа вынесена в отдельную задачу.

Спек и план — в репе №2: `docs/specs/2026-09-22-multipass-server-design.md`,
`docs/plans/2026-09-22-multipass-server.md`.

## Связанные скиллы

- `custom-gameobject-v-webshop` — продажа БП/ЭП в вебшопе (паттерн интеграции не-`OfferItem` объекта)
- `klone-feature-pack-purchase-flow` — покупка пропуска как `AccessProductItem`, платёжные процессоры
- `webshop-controller-chains` — цепочки вызовов вебшопа, если БП продаётся там
