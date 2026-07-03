---
name: klone-client-architecture
description: Архитектура Java-клиента klone-mobile. Используй когда работаешь с клиентской частью: инициализация, загрузка, FSM, сеть, окна, десктопные API. Содержит справочник ключевых классов, паттернов и точек расширения.
---

# Архитектура клиента klone-mobile

> Java 8, no external libs. Модули: `klone/` (общий), `klone-desktop/` (Desktop обёртка).

---

## Быстрый справочник по задачам

| Задача | Куда смотреть |
|--------|--------------|
| Добавить шаг загрузки | `KlondikeLoadable`, `StartLoadSequence` |
| Добавить новое окно | `Window`, `loadWindowContent()`, R.Ui |
| Добавить состояние NPC | `State`, `AbstractStateMachine`, `FSM` |
| Добавить HTTP запрос | `BaseHttpRequest`, `BaseHttpResponseHandler` |
| Добавить обработчик ответа сервера | `GameEventProcessor` или `GameEventHandler` |
| Добавить Desktop API | `Launcher.initializePlatform()`, `PlatformApis` |
| Добавить горячую клавишу | `ShortCut`, `ShortCutManager` |

---

## Ключевые файлы

```
klone/src/com/vizor/klone/
  Klondike.java                      ← главное приложение, статические аксессоры
  GameState.java                     ← игровое состояние (model)
  loader/
    Loader.java                      ← оркестратор загрузки
    KlondikeLoadable.java            ← интерфейс шага загрузки
    LoadingContext.java              ← DI контейнер для загрузки
    LoadSequence.java                ← список шагов (ArrayList)
    sequence/StartLoadSequence.java  ← ~56 шагов при запуске
    sequence/TravelLoadSequence.java ← ~40 шагов при путешествии
  lifecycle/LifecycleTracker.java    ← UNKNOWN → LOADING → RUNNING
  fsm/
    FSM.java                         ← конечный автомат
    StateMachineBuilder.java         ← fluent API для построения FSM
    StateContext.java                ← текущее состояние + EventContext
    EventContext.java                ← данные события (point, npc, listener)
  ui/
    Window.java                      ← базовый класс окна (1222 строки)
    Dialog.java                      ← диалог
    WindowListener.java              ← lifecycle callbacks окна
    scene/windows/WindowsManager.java ← управление стэком окон

klone/src/com/vizor/mobile/network/
  Network.java                       ← фасад
  RequestSender.java                 ← retry + per-frame обработка ответов
  GameSession.java                   ← игровая сессия, sendEvent()

klone-desktop/src/com/vizor/mobile/
  desktop/launcher/Launcher.java     ← main(), инициализация 32 API
  api/DesktopNetworkApi.java         ← с debug задержками
  api/DesktopBillingApi.java         ← UI диалог вместо реального платежа
```

---

## Инициализация (StartLoadSequence)

```
Klondike.start()
  ↓ инициализация 22 систем (Network, GameSession, Audio, Analytics...)
  ↓
new StartLoadSequence(context)
  ↓
Loader.load():
  LoadingStart           → EVENT_LOADING_START
  OpenSession(ctx)       → async connect
  WaitGameState(ctx)     → ждём gameState != null
  ValidateGameState
  LoadLocation → LoadTileMap → CreateWorld → PopulateWorld
  CreateGameScene
  LoadingSceneFinish     → setScene(gameScene) → EVENT_LOADING_FINISH
  ApplicationLoadingFinish → /status, APP_LOADED
```

**LifecycleTracker:** `UNKNOWN → LOADING → RUNNING`

### Добавить шаг загрузки
```java
// 1. Создать класс
public final class MyLoadable extends KlondikeLoadable {
    public MyLoadable(LoadingContext ctx) { this.context = ctx; }
    
    @Override public void load() { context.gameState.doSomething(); }
    @Override public boolean isDone() { return true; } // или условие
    @Override public String info() { return "Loading my feature..."; }
}

// 2. Добавить в StartLoadSequence
add(new MyLoadable(context));
```

---

## FSM (конечные автоматы NPC)

```java
// Создание
Transition stand = transit(event(Events.EVENT_STAND), state(States.STATE_STAND));
Transition walk  = transit(event(Events.EVENT_WALK),  state(States.STATE_WALK));
stand.transit(walk);   // из STAND можно в WALK
walk.transit(stand);   // из WALK можно в STAND

FSM machine = StateMachineBuilder
    .from(state(States.STATE_STAND))
    .transit(true, stand, walk);

machine.whenEnter(state(States.STATE_WALK), ctx ->
    startState(new WalkState(npc, ctx)));

machine.start(stateContext);

// Триггер
stateMachine.addEvents(new EventContext(event(Events.EVENT_WALK))
    .setPoint(target)
    .setStateListener(() -> onDone()));
```

### Добавить состояние NPC
1. `enum States` — добавить `STATE_MY_NEW`
2. `enum Events` — добавить `EVENT_MY_NEW`  
3. Создать `MyNewState extends State` → переопределить `onStateStart()`, `onAnimationEnd()`
4. В StateMachine: `transit(EVENT_MY_NEW, STATE_MY_NEW)`, связать, добавить `whenEnter`

---

## Сеть

### Отправка запроса
```java
// Игровые пакеты
gameSession.sendEvent(new ClientActionEvent(ACTION, new MyEvent(params)));

// HTTP запрос
Klondike.getNetwork().sendRequest(new MyRequest(networkConfig, callback));
```

**Путь:** `Network` → `RequestSender` (retry proxy) → `networkApi.sendHttpRequest()` → HTTP POST `/go`

**ВАЖНО:** Ответы обрабатываются 1 раз за кадр (TickTimer в RequestSender).

### Формат запроса на /go
```
data={"id":N,"timestamp":T,"events":[{"id":"e1","action":"buy","data":{...}}]}&crc=MD5
```

### Обработка ответа
```
GoRequest.ResponseHandler → проверить MD5 → десериализация JSON
  → EventPacketHandler:
       customHandler = CUSTOM.get(eventId) → handle() или
       GameEventProcessor.process(event)   → обновить GameState
```

### Добавить обработчик события
```java
public class MyProcessor implements GameEventProcessor {
    @Override public boolean canProcess(GameEvent e) {
        return "myAction".equals(e.getAction());
    }
    @Override public void process(GameEvent e) {
        gameState.doSomething(e.getData());
    }
}
// Регистрация в GameSession:
eventPacketHandler.addGameEventProcessor(new MyProcessor());
```

---

## Окна

### Открыть окно
```java
Klondike.events().fireEvent(Events.OPEN_WINDOW, new MyWindow(gameState));
// С поведением:
Klondike.events().fireEvent(Events.OPEN_WINDOW, window, OpenBehavior.OVER_CURRENT);
```

**OpenBehavior:** `OVER_CURRENT` | `CLOSE_CURRENT` | `HIDE_CURRENT` | `NONE`

**Приоритеты:** `VERY_LOW < LOW < NORMAL < HIGH < DOWNLOAD_GATE < MATCH3 < CRITICAL`

### Lifecycle окна
```
new Window()
  → [первый attach] load() → loaded() → loadWindowContent()
  → listener.onAttach() → анимация → listener.onOpen() → hasFocus=true
  → [закрытие] close() → detach() → анимация → destroy() → listener.onClose()
```

### WindowListener
```java
window.addListener(new WindowListener.Default() {
    @Override public void onOpen() { }
    @Override public void onClose() { }
    @Override public void onClosePlayer() { }  // крестик/back/клик вне
});
```

### Создать окно
```java
public class MyWindow extends Window implements R.Ui.MyWindow {
    @Override public String getId() { return id; }

    @Override
    protected void loadWindowContent() {
        Button btn = getById(b_action);
        btn.addListener(b -> { close(); });
    }

    @Override public boolean canCloseByMotionOutsideWindow() { return true; }
    @Override public Priority getPriority() { return Priority.NORMAL; }
}
```

### Обработка кнопки
```
MotionEvent → View.processMotionEvent() → ButtonTapGestureRecognizer
  → onPointerUp если внутри → onButtonClick()
  → ButtonListener.onButtonClick(button)
```

---

## Desktop API (Launcher)

```java
// Точка входа
main(args) → new Launcher(args)
  → Config.parseCli()
  → new Klondike()
  → ApplicationFrame (JFrame + JOGL Canvas)
  → initializePlatform():
       PlatformApis platform = new PlatformApis();
       platform.addApi(new DesktopNetworkApi(...), NetworkApi.class);
       platform.addApi(new DesktopBillingApi(), BillingApi.class);
       // ... 32 API
       PlatformApisProvider.setPlatform(platform);
  → FPSAnimator 60fps → Klondike.onStart()

// Доступ к API
Klondike.getApi(NetworkApi.class)
```

### Добавить Desktop API
```java
// 1. Создать
public final class DesktopMyApi extends MyApi {
    public DesktopMyApi() { super(new DesktopMyProtocol()); }
    
    private static final class DesktopMyProtocol implements MyProtocol {
        @Override public void doSomething(Callback cb) { cb.onSuccess(); }
    }
}

// 2. Зарегистрировать в Launcher.initializePlatform()
platform.addApi(new DesktopMyApi(), MyApi.class);
```

---

## DI — как компоненты находят друг друга

**Нет Guice.** Вместо этого:

```java
Klondike.gameSession()           // GameSession
Klondike.getNetwork()            // Network
Klondike.scenes()                // SceneManager
Klondike.features()              // FeatureToggles
Klondike.getApi(XxxApi.class)    // Platform API
gameState.getComponent(KEY)      // StateComponent
```

---

## События (KlondikeEventManager)

```java
// Подписка
Klondike.events().subscribe(new KlondikeEventHandler() {
    @Override public Events[] getEvents() {
        return new Events[] { Events.GAME_RESTART };
    }
    @Override public void onFire(KlondikeEvent e) {
        if (Events.GAME_RESTART.is(e)) { reset(); }
    }
});

// Отправка
Klondike.events().fireEvent(Events.GAME_RESTART);
Klondike.events().fireEvent(Events.OPEN_WINDOW, window);
```

Ключевые события: `GAME_RESTART`, `CHANGE_LOCATION`, `OPEN_WINDOW`, `CLOSE_WINDOW`, `PAUSE/UNPAUSE`, `SUSPEND/RESUME`, `EVENT_LOADING_START`, `EVENT_LOADING_FINISH`.

---

## Книга знаний (Obsidian)

Полная документация с диаграммами и примерами:
`/Users/artyom.lisaev/obsidian/klone/`

- `00-index.md` — карта всего
- `flows/01-app-startup.md` — запуск приложения
- `flows/02-window-lifecycle.md` — окна и кнопки
- `flows/03-server-request.md` — отправка запросов
- `flows/04-server-response.md` — обработка ответов
- `topics/initialization.md` — инициализация
- `topics/loader.md` — Loader, KlondikeLoadable
- `topics/fsm.md` — FSM, состояния NPC
- `topics/network.md` — сетевой слой
- `topics/windows.md` — система окон
- `topics/desktop-apis.md` — Desktop Launcher и API
