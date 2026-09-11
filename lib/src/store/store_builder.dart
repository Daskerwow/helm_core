import 'state_store.dart';
import 'state_storage.dart';
import '../dispatch.dart';
import '../middleware.dart';
import 'store_config.dart';

/// Fluent-строитель [StateStore] (Builder pattern).
///
/// Каждый хук регистрируется через `StateStore.addOnChanged`/`addOnEffect`/
/// `addErrorListener`/`addDispatchListener` — прямые слушатели, а не
/// `Stream`-подписки: билдер не держит ссылок, которые нужно было бы
/// отдельно отменять, и одновременно можно зарегистрировать сколько угодно
/// независимых хуков одного вида (`.onChanged(...)` можно вызвать несколько
/// раз — например, для логирования **и** синхронизации с внешним state
/// manager'ом одновременно).
///
/// ```dart
/// final store = StoreBuilder<UserState, UserEffect>(UserState.initial())
///     .withStorage(HiveStateStorage<UserState>(...))
///     .onChanged((s) => ref.read(userProvider.notifier).state = s)
///     .onEffect((e) => router.handle(e))
///     .onError((e, st) => Sentry.captureException(e, stackTrace: st))
///     .onDispatch((event) => logger.debug(event.toLogString()))
///     .build();
/// ```
final class StoreBuilder<S, E> {
  StoreBuilder(this._initialState);

  final S _initialState;
  StateStorage<S>? _storage;
  bool _storageSet = false;
  bool Function(S a, S b)? _equals;
  bool _logStreamEvents = true;
  void Function(String commandLabel, S nextState)? _onDroppedCommit;

  final _onChanged = <void Function(S state)>[];
  final _onEffect = <void Function(E effect)>[];
  final _onError = <void Function(Object error, StackTrace stackTrace)>[];
  final _onDispatch = <void Function(DispatchEvent<S> event)>[];
  final _middleware = <StoreMiddleware<S>>[];

  /// Подключает готовый [StoreConfig] — эквивалент последовательного вызова
  /// [withStorage]/[onChanged]/[onEffect]/[onError]/[onDispatch] для каждого
  /// заданного в конфиге поля.
  StoreBuilder<S, E> withConfig(StoreConfig<S, E> config) {
    if (config.storage != null) withStorage(config.storage!);
    if (config.onChanged != null) onChanged(config.onChanged!);
    if (config.onEffect != null) onEffect(config.onEffect!);
    if (config.onError != null) onError(config.onError!);
    if (config.onDispatch != null) onDispatch(config.onDispatch!);
    if (config.equals != null) withEquals(config.equals!);
    if (config.onDroppedCommit != null) {
      withDroppedCommitHandler(config.onDroppedCommit!);
    }
    _logStreamEvents = config.logStreamEvents;

    return this;
  }

  /// Компаратор "состояние не изменилось" — см. `StateStore.new`. Можно
  /// вызвать только один раз.
  StoreBuilder<S, E> withEquals(bool Function(S a, S b) equals) {
    if (_equals != null) throw StateError('withEquals уже вызван');
    _equals = equals;

    return this;
  }

  /// Персистентное хранилище — без вызова используется [StateMemoryStorage].
  /// Можно вызвать только один раз.
  StoreBuilder<S, E> withStorage(StateStorage<S> storage) {
    if (_storageSet) throw StateError('withStorage уже вызван');
    _storage = storage;
    _storageSet = true;

    return this;
  }

  /// Хук диагностики коммита, отброшенного после отмены async-команды —
  /// см. `StateStore.new`, параметр `onDroppedCommit`. Можно вызвать только
  /// один раз; для нескольких независимых обработчиков объедини их в одну
  /// функцию перед передачей.
  StoreBuilder<S, E> withDroppedCommitHandler(
    void Function(String commandLabel, S nextState) handler,
  ) {
    if (_onDroppedCommit != null) {
      throw StateError('withDroppedCommitHandler уже вызван');
    }
    _onDroppedCommit = handler;

    return this;
  }

  /// Регистрирует слушателя каждого обновления состояния. Можно вызывать
  /// многократно — каждый вызов добавляет независимого слушателя.
  StoreBuilder<S, E> onChanged(void Function(S state) callback) {
    _onChanged.add(callback);

    return this;
  }

  /// Регистрирует слушателя каждого side-эффекта.
  StoreBuilder<S, E> onEffect(void Function(E effect) callback) {
    _onEffect.add(callback);

    return this;
  }

  /// Регистрирует обработчик необработанных исключений внутри dispatch.
  StoreBuilder<S, E> onError(
    void Function(Object error, StackTrace st) handler,
  ) {
    _onError.add(handler);

    return this;
  }

  /// Регистрирует хук трассировки — вызывается после каждого dispatch, при
  /// любом исходе.
  StoreBuilder<S, E> onDispatch(void Function(DispatchEvent<S> event) handler) {
    _onDispatch.add(handler);
    return this;
  }

  /// Регистрирует именованный [StoreMiddleware] — форма поверх
  /// [onDispatch], удобная, когда кросс-катаную заботу естественнее
  /// оформить классом, а не замыканием (см. докстринг [StoreMiddleware]).
  StoreBuilder<S, E> withMiddleware(StoreMiddleware<S> middleware) {
    _middleware.add(middleware);

    return this;
  }

  /// Отключает [DispatchEvent] на каждую итерацию Stream-команды — см.
  /// [StoreConfig.logStreamEvents]. Публикацию состояния не затрагивает.
  StoreBuilder<S, E> disableStreamDispatchLogging() {
    _logStreamEvents = false;

    return this;
  }

  /// Создаёт сконфигурированный [StateStore]. После вызова экземпляр
  /// [StoreBuilder] повторно использовать не следует.
  StateStore<S, E> build() {
    final store = _storageSet
        ? StateStore<S, E>.fromStorage(
            _storage!,
            logStreamEvents: _logStreamEvents,
            equals: _equals,
            onDroppedCommit: _onDroppedCommit,
          )
        : StateStore<S, E>(
            initialState: _initialState,
            logStreamEvents: _logStreamEvents,
            equals: _equals,
            onDroppedCommit: _onDroppedCommit,
          );

    for (final callback in _onChanged) {
      store.addOnChanged(callback);
    }

    for (final callback in _onEffect) {
      store.addOnEffect(callback);
    }

    for (final handler in _onError) {
      store.addErrorListener(handler);
    }

    for (final handler in _onDispatch) {
      store.addDispatchListener(handler);
    }

    for (final middleware in _middleware) {
      store.addMiddleware(middleware);
    }

    return store;
  }
}
