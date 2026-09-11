import 'state_storage.dart';
import '../internal/internal.dart';
import '../dispatch.dart';
import '../equality.dart';
import '../middleware.dart';
import '../command/command.dart';

/// Центральный Store — единственная точка входа для чтения состояния и
/// диспатча команд.
///
/// **Не знает ничего о Flutter или о каком-либо конкретном UI-фреймворке**:
/// весь файл — чистый Dart без единого импорта из `package:flutter`. Это
/// не случайность, а инвариант архитектуры (Dependency Inversion): любой
/// мост к конкретному фреймворку (см. `package:helm/flutter.dart`) зависит
/// от `StateStore`, а не наоборот. Store можно использовать в CLI, на
/// сервере (`dart:io`), в изоляте — где угодно, где есть Dart.
///
/// ### Матрица dispatch-методов
///
/// |        | без эффекта              | с эффектом                   |
/// |--------|--------------------------|------------------------------|
/// | Stream | [dispatchStream]         | [dispatchStreamWithEffect]   |
/// | Async  | [dispatchAsync]          | [dispatchAsyncWithEffect]    |
/// | Sync   | [dispatchSync]           | [dispatchSyncWithEffect]     |
///
/// Каждая пара реализована через общий приватный метод ([_dispatchAsync],
/// [_dispatchStream], [_dispatchSyncInternal]) — единственное отличие
/// внутри пары в том, возвращает ли `execute()` команды ещё и side-эффект.
///
/// ### Учёт активных токенов/подписок — `DispatchRegistry`
///
/// Store не хранит `Map`-ы токенов отмены и stream-подписок сам — этим
/// занимается `internal/dispatch_registry.dart`. Store остаётся
/// оркестратором самого диспатча; какой ключ сейчас "в полёте" и как его
/// отменить — забота реестра, тестируемая отдельно от Store.
///
/// ### Реактивность — прямые синхронные слушатели, без `Stream`-накладных
///
/// [addOnChanged]/[addOnEffect]/[addDispatchListener]/[addErrorListener] —
/// тот же паттерн Observer, на котором построен `ChangeNotifier` в самом
/// ядре Flutter: список колбэков, вызываемых синхронно, без буферизации в
/// микрозадаче. Регистрация возвращает функцию отписки — снять слушателя
/// можно без хранения отдельного объекта подписки:
///
/// ```dart
/// final unsubscribe = store.addOnChanged((s) => print(s));
/// // ...
/// unsubscribe();
/// ```
///
/// [states]/[effects] — тонкая надстройка поверх того же механизма как
/// обычный `Stream`, для интеропа с кодом, ожидающим `Stream` (например,
/// `StreamBuilder` вне Flutter-моста, `await for`). [states] дополнительно
/// "seed"-ит каждого нового подписчика текущим состоянием (см. докстринг
/// геттера) — [effects] остаётся чистым потоком событий, без семантики
/// "текущего значения".
///
/// ### Middleware
///
/// [addMiddleware] — именованная альтернатива [addDispatchListener] для
/// кросс-катаных забот (логирование, аналитика, DevTools-мост), которые
/// удобнее оформить отдельным классом [StoreMiddleware], а не анонимным
/// замыканием на месте вызова. Внутри это тонкая обёртка: не даёт новых
/// возможностей сверх [addDispatchListener], только форму.
///
/// ### Согласованность
///
/// [state] (синхронное чтение) и [states]/[addOnChanged] всегда
/// согласованы: любой успешный `StateWriter.commit` публикуется сразу в
/// момент вызова, независимо от итогового исхода dispatch'а и от того,
/// сколько раз команда коммитит за одно выполнение.
///
/// ### Неизменяемость состояния
///
/// `S` должен быть неизменяемым value-объектом. Никогда не меняй текущий
/// `List`/`Map`/`Set` на месте: Store хранит только ссылку на прошлое
/// значение, поэтому такая мутация неотличима от отсутствия изменения.
/// Создавай новый state и неизменяемые копии его коллекций в каждой команде.
///
/// ### Изоляция ошибок слушателей
///
/// Исключение одного слушателя [addOnChanged]/[addOnEffect]/
/// [addDispatchListener]/[addErrorListener] не мешает доставить событие
/// остальным — см. `internal/store_event_bus.dart`. Это касается только
/// *слушателей самого Store*: исключение внутри команды (`execute()`)
/// по-прежнему приводит к [DispatchFailure] обычным путём.
///
/// ### Жизненный цикл
/// 1. Создать через конструктор или `StoreBuilder`.
/// 2. Подписаться через [addOnChanged]/[addOnEffect] или [states]/[effects].
/// 3. Диспатчить команды.
/// 4. Вызвать [close] при уничтожении.
final class StateStore<S, E> {
  /// Создаёт Store с начальным состоянием. Если [storage] не передан —
  /// [StateMemoryStorage].
  ///
  /// [logStreamEvents] — по умолчанию `true`: каждая итерация активной
  /// Stream-команды с изменением состояния порождает [DispatchEvent] в
  /// [addDispatchListener]. На публикацию состояния это не влияет — она
  /// происходит всегда, на каждый реальный коммит.
  ///
  /// [_onDroppedCommit] — см. `GuardedWriter`, раздел "Диагностика
  /// отброшенного коммита": опциональный хук для коммитов, отброшенных
  /// из-за коммита после отмены async-команды, работающий и в release.
  new({
    required S initialState,
    StateStorage<S>? storage,
    bool Function(S a, S b)? equals,
    this.logStreamEvents = true,
    this._onDroppedCommit,
  }) : _accessor = StateAccessorImpl(
         storage ?? StateMemoryStorage(initialState),
       ),
       _equals = equals ?? defaultEquals<S>;

  /// Создаёт Store из готового хранилища — начальное состояние берётся из
  /// `storage.read()`.
  new fromStorage(
    StateStorage<S> storage, {
    this.logStreamEvents = true,
    bool Function(S a, S b)? equals,
    this._onDroppedCommit,
  }) : _accessor = StateAccessorImpl(storage),
       _equals = equals ?? defaultEquals<S>;

  final StateAccessorImpl<S> _accessor;

  /// Компаратор "состояние не изменилось" — по умолчанию структурное `==`.
  /// Передай свой в конструктор, если `S` — мутируемая коллекция или тип с
  /// дорогим/неверным `==` (см. `listEquals`/`setEquals`/`mapEquals`/
  /// `deepEquals` в `equality.dart`).
  final bool Function(S a, S b) _equals;

  /// См. докстринг конструктора, параметр `onDroppedCommit`.
  final void Function(String commandLabel, S nextState)? _onDroppedCommit;

  /// Единственный владелец Observer-каналов и их Stream-адаптеров.
  final _events = StoreEventBus<S, E>();

  /// Реестр активных async-токенов и stream-подписок — см.
  /// `internal/dispatch_registry.dart`.
  final _dispatch = DispatchRegistry();

  late final _committer = StateCommitter<S, E>(
    accessor: _accessor,
    events: _events,
    equals: _equals,
    onDroppedCommit: _onDroppedCommit,
  );

  late final _commands = CommandDispatcher<S, E>(
    accessor: _accessor,
    events: _events,
    registry: _dispatch,
    committer: _committer,
    isClosed: () => _closed,
  );

  late final _stream = StreamDispatcher<S, E>(
    accessor: _accessor,
    events: _events,
    registry: _dispatch,
    committer: _committer,
    logEvents: logStreamEvents,
    isClosed: () => _closed,
  );

  bool _closed = false;

  /// См. докстринг конструктора.
  final bool logStreamEvents;

  // ── Реактивность ─────────────────────────────────────────────────────────

  /// Регистрирует слушателя каждого реального изменения состояния —
  /// сравнение по компаратору из конструктора. Возвращает функцию отписки.
  void Function() addOnChanged(void Function(S state) listener) =>
      _events.onChange(listener);

  /// Регистрирует слушателя каждого эмитированного side-эффекта. Возвращает
  /// функцию отписки.
  void Function() addOnEffect(void Function(E effect) listener) =>
      _events.onEffect(listener);

  /// Регистрирует слушателя каждого dispatch — при успехе, ошибке и отмене.
  /// Несколько независимых слушателей (логи + аналитика + Sentry) не
  /// конфликтуют друг с другом. Возвращает функцию отписки.
  ///
  /// Видит отмену/вытеснение и async-, и Stream-команд — оба пути эмитируют
  /// [DispatchEvent] с `cancelReason` через один и тот же механизм.
  void Function() addDispatchListener(
    void Function(DispatchEvent<S> event) listener,
  ) => _events.onDispatch(listener);

  /// Именованная альтернатива [addDispatchListener] — см. докстринг класса,
  /// раздел "Middleware", и [StoreMiddleware]. Возвращает функцию отписки.
  void Function() addMiddleware(StoreMiddleware<S> middleware) =>
      addDispatchListener(middleware.onDispatch);

  /// Регистрирует слушателя необработанных исключений внутри dispatch —
  /// вызывается дополнительно к возврату [DispatchFailure]. Возвращает
  /// функцию отписки.
  void Function() addErrorListener(
    void Function(Object error, StackTrace stackTrace) listener,
  ) => _events.onError(listener);

  /// Broadcast-`Stream` состояний — интероп-слой поверх [addOnChanged] для
  /// кода, ожидающего `Stream` (`StreamBuilder`, `await for`).
  ///
  /// В отличие от [effects], каждый новый подписчик сразу получает текущее
  /// [state] первым событием потока, а дальше — каждое изменение, как и
  /// [addOnChanged]. Без этого поздний подписчик (обычный сценарий:
  /// `StreamBuilder` создаётся уже после первых изменений Store) не увидел
  /// бы уже актуальное состояние вплоть до следующего коммита — типичный
  /// источник "пустого экрана до первого чужого действия" в UI поверх
  /// `Stream`. Реализовано через `Stream.multi`: колбэк выполняется заново
  /// для каждого отдельного подписчика, поэтому "seed" не смешивается
  /// между разными слушателями брошенного broadcast-потока.
  Stream<S> get states => _events.states(() => _accessor.current);

  /// Broadcast-`Stream` side-эффектов — интероп-слой поверх [addOnEffect].
  /// Чистый поток событий: в отличие от [states], не несёт "текущего
  /// значения" и ничего не отправляет новому подписчику при подписке.
  Stream<E> get effects => _events.effects;

  /// Текущее состояние — синхронное чтение без подписки.
  S get state => _accessor.current;

  /// Store закрыт и больше не принимает команды.
  bool get isClosed => _closed;

  /// Принудительно заменяет состояние, минуя обычный dispatch-цикл (без
  /// [DispatchEvent], без проверки [isClosed]) — **только для тестов**.
  /// Публикует изменение, если значение реально отличается.
  ///
  /// Префикс `debug` — как `debugPrint`/`debugDumpApp` в самом Flutter SDK:
  /// сигнализирует "не для продакшен-кода", делая случайное использование
  /// в обычной команде/сервисе заметным при code review и легко находимым
  /// поиском по имени.
  ///
  /// ```dart
  /// store.debugResetForTesting(Loadable.data(fakeTodos));
  /// expect(store.state.valueOrNull, fakeTodos);
  /// ```
  void debugResetForTesting(S state) {
    _commands.resetForTesting(state);
  }

  // ── Stream dispatch ─────────────────────────────────────────────────────

  /// Подписывается на Stream-команду без side-эффектов. Если команда с той
  /// же группой отмены (см. `DispatchKeyed`) уже активна — предыдущая
  /// подписка отменяется первой (см. [_cancelStreamSubscription]). После
  /// [close] — no-op.
  void dispatchStream(StreamCommand<S> command) => _stream.dispatch(command);

  /// Подписывается на Stream-команду с side-эффектами. Та же семантика
  /// отмены предыдущей подписки, что и у [dispatchStream].
  void dispatchStreamWithEffect(StreamSideEffect<S, E> command) =>
      _stream.dispatchWithEffect(command);

  // ── Async dispatch ──────────────────────────────────────────────────────

  /// Отправляет асинхронную команду. Если команда с той же группой отмены
  /// уже выполняется — предыдущая отменяется с [CancelReason.superseded].
  /// После [close] немедленно возвращает
  /// `DispatchCancelled(CancelReason.storeClosed)`, не запуская команду.
  Future<DispatchResult<S>> dispatchAsync(AsyncCommand<S> command) =>
      _dispatchAsync(command, (writer, token) async {
        await command.execute(_accessor, writer, token);
        return null;
      });

  /// Как [dispatchAsync], но с side-эффектом.
  Future<DispatchResult<S>> dispatchAsyncWithEffect(
    AsyncSideEffect<S, E> command,
  ) => _dispatchAsync(
    command,
    (writer, token) => command.execute(_accessor, writer, token),
  );

  /// Общее ядро [dispatchAsync]/[dispatchAsyncWithEffect]: строит защищённый от
  /// коммитов-после-отмены writer ([GuardedWriter] поверх [EmittingWriter])
  /// и прогоняет его через [_runAsync]. Разница между двумя публичными
  /// методами — только в том, возвращает ли `execute()` команды ещё и
  /// side-эффект.
  Future<DispatchResult<S>> _dispatchAsync(
    Object command,
    Future<E?> Function(StateWriter<S> writer, CancelToken token) execute,
  ) => _commands.dispatchAsync(command, execute);

  // ── Sync dispatch ───────────────────────────────────────────────────────

  /// Отправляет синхронную команду. Выполняется мгновенно, не может быть
  /// отменена. После [close] немедленно возвращает
  /// `DispatchCancelled(CancelReason.storeClosed)`.
  DispatchResult<S> dispatchSync(SyncCommand<S> command) =>
      _dispatchSyncInternal(
        command,
        () => (command.execute(_accessor.current), null),
      );

  /// Как [dispatchSync], но с side-эффектом.
  DispatchResult<S> dispatchSyncWithEffect(SyncSideEffect<S, E> command) =>
      _dispatchSyncInternal(command, () => command.execute(_accessor.current));

  /// Общее ядро [dispatchSync]/[dispatchSyncWithEffect].
  DispatchResult<S> _dispatchSyncInternal(
    Object command,
    SyncSideEffectResult<S, E> Function() run,
  ) => _commands.dispatchSync(command, run);

  // ── Управление жизненным циклом ─────────────────────────────────────────

  /// Отменяет активную async-команду по типу `U` — работает для команд без
  /// собственного `DispatchKeyed.dispatchKey` (обычный случай, когда группа
  /// отмены — это `runtimeType`). Для кастомного ключа используй [cancelKey].
  void cancel<U>() => cancelKey(U);

  /// Отменяет активную async-команду по явному ключу — см. `DispatchKeyed`.
  void cancelKey(Object key) =>
      _dispatch.cancelToken(key, CancelReason.userRequested);

  /// Отменяет все активные async-команды. Уже завершённые не затрагиваются.
  void cancelAll() => _dispatch.cancelAllTokens(CancelReason.userRequested);

  /// Отменяет активную stream-подписку по типу `U` — см. [cancel]. Как и
  /// отмена async-команды, эмитирует [DispatchEvent] с
  /// `cancelReason: CancelReason.userRequested` в [addDispatchListener].
  void cancelStream<U>() => cancelStreamKey(U);

  /// Отменяет активную stream-подписку по явному ключу — см. [cancelKey].
  void cancelStreamKey(Object key) =>
      _stream.cancel(key, CancelReason.userRequested);

  /// Освобождает все ресурсы: отменяет активные async-команды и
  /// stream-подписки, снимает всех слушателей, закрывает [states]/[effects].
  ///
  /// Повторный вызов — no-op. После вызова все `dispatch*`-методы
  /// возвращают `DispatchCancelled(CancelReason.storeClosed)` (или ничего не
  /// делают для Stream-варианта), не бросая исключений — это позволяет
  /// безопасно вызывать [close] из владельца жизненного цикла даже если
  /// где-то ещё "в полёте" остался вызов dispatch.
  void close() {
    if (_closed) return;
    _closed = true;

    _dispatch.cancelAllTokens(CancelReason.storeClosed);

    _stream.cancelAll(CancelReason.storeClosed);

    _dispatch.clear();
    _events.close();
  }
}
