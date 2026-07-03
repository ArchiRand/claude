---
name: battlepass-energypass
description: Руководство по работе с Battle Pass (БП) и Energy Pass (ЭП) в klone-mobile-server. Используй этот скил всегда, когда задача связана с БП или ЭП: добавление нового типа задания, настройка стадий наград, конфигурация commonPickup, слоты, infinityMode, покупка пропуска, конвертация очков, кастомизация верстки — любые изменения в XML или серверной логике этих сущностей.
---

# BattlePass / EnergyPass Skill

## Архитектурный обзор

БП и ЭП — это **адвенчуры** (`adventure`), реализованные через одну и ту же сущность `battlePass id`.
Тип определяется полем `belong`.

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
| `infinitySafe="true"` | Заменяет infinityMode на режим сейфа (только БП) |

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
- ID слотов **уникальны** в рамках всего БП/ЭП.
- Числовые суффиксы `_N` идут строго по возрастанию: `BP_1`, `BP_2`, `BP_3` — иначе сервер не собирается.
- `stage count` — **накопительное** количество очков, не дельта между стадиями.
- Первая стадия всегда `count="0"` — игрок получает её без очков.

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
| `baseIncrement` | Стоимость первой генерируемой награды в очках |
| `increment` | Рост стоимости каждой следующей |
| `repeatPrize` | Сколько генераций не повторяется один и тот же предмет |

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

## Частые ошибки

| Проблема | Следствие |
|---|---|
| ID слотов не по возрастанию или не уникальны | Сервер не собирается |
| `finishEventTaskTimerDuration` без `requireEventLocation="true"` | Некорректная работа таймера |
| `resized="true"` в БП | Только для ЭП, в БП запрещено |
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
