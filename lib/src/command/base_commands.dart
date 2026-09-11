import 'dart:async';

import '../internal/internal.dart';
import 'commands.dart';
import 'side_effect_commands.dart';

/// Заменяет состояние на заранее известное значение — без отдельного класса
/// команды на каждую тривиальную мутацию.
///
/// ```dart
/// store.dispatchSync(SetUse(FilterZone.all));
/// ```
final class const SetUse<S>(final S next) implements SyncCommand<S> {
  @override
  S execute(S current) => next;
}

/// Выполняет несколько синхронных команд подряд как одну — удобно, когда
/// мутация складывается из нескольких независимых шагов.
///
/// ```dart
/// store.dispatch(SequenceUse([
///   UpdateUse((s) => s.copyWith(isLoading: false)),
///   UpdateUse((s) => s.copyWith(items: [...s.items, newItem])),
/// ]));
/// ```
final class const SequenceUse<S>(final List<SyncCommand> commands)
    implements SyncCommand<S> {
  @override
  S execute(S current) =>
      commands.fold(current, (state, command) => command.execute(state));
}

/// Вычисляет новое состояние из текущего чистой функцией — `copyWith`-подобные
/// обновления без отдельного класса команды.
///
/// ```dart
/// store.dispatchSync(UpdateUse((s) => s.copyWith(isOpen: !s.isOpen)));
/// ```
final class const UpdateUse<S>(final S Function(S current) update)
    implements SyncCommand<S> {
  @override
  S execute(S current) => update(current);
}

/// Применяет [then], только если [test] возвращает `true` для текущего
/// состояния — иначе состояние не меняется.
///
/// ```dart
/// store.dispatch(WhenUse((s) => !s.isLoading, SetUse(loadingState)));
/// ```
final class const WhenUse<S>(
  final bool Function(S current) test,
  final SyncCommand<S> then,
) implements SyncCommand<S> {
  @override
  S execute(S current) => test(current) ? then.execute(current) : current;
}

final class const NullUse<S>() implements SyncCommand<S?> {
  @override
  S? execute(S? current) => null;
}

final class const IndexUse(final int next) implements SyncCommand<int> {
  @override
  int execute(int current) => next;
}

final class const ResetIndexUse(final int? start) implements SyncCommand<int> {
  @override
  int execute(int current) => start != null ? start! : 0;
}

final class const IncrementUse() implements SyncCommand<int> {
  @override
  int execute(int current) => ++current;
}

final class const DecrementUse() implements SyncCommand<int> {
  @override
  int execute(int current) => --current;
}

final class const OffUse() implements SyncCommand<bool> {
  @override
  bool execute(bool current) => false;
}

final class const OnUse() implements SyncCommand<bool> {
  @override
  bool execute(bool current) => true;
}

final class const ToggleUse() implements SyncCommand<bool> {
  @override
  bool execute(bool current) => !current;
}

// ---------------------------------------------------------------------------
// Sync — с эффектом
// ---------------------------------------------------------------------------

/// Как [SetUse], но дополнительно эмитирует side-эффект.
///
/// ```dart
/// store.dispatchWithEffect(
///   SetWithEffectUse(loggedOutState, effect: const NavigateToLogin()),
/// );
/// ```
final class const SetWithEffectUse<S, E>(final S next, {final E? effect})
    implements SyncSideEffect<S, E> {
  @override
  SyncSideEffectResult<S, E> execute(S current) => (next, effect);
}

/// Как [UpdateUse], но функция сразу возвращает и состояние, и
/// опциональный эффект — для случаев, когда эффект зависит от результата.
final class const UpdateWithEffectUse<S, E>(
  final SyncSideEffectResult<S, E> Function(S current) update,
) implements SyncSideEffect<S, E> {
  @override
  SyncSideEffectResult<S, E> execute(S current) => update(current);
}

/// Эмитирует side-эффект, не трогая состояние — навигация, диалог,
/// аналитическое событие.
///
/// ```dart
/// store.dispatchWithEffect(EmitEffectUse(ShowSnackBar('Сохранено')));
/// ```
final class const EmitEffectUse<S, E>(final E effect)
    implements SyncSideEffect<S, E> {
  @override
  SyncSideEffectResult<S, E> execute(S current) => (current, effect);
}

// ---------------------------------------------------------------------------
// Async — без эффекта
// ---------------------------------------------------------------------------

/// Загружает состояние через переданную функцию и коммитит результат целиком.
/// Проверяет отмену после `await`, перед коммитом.
///
/// ```dart
/// store.dispatch(LoadUse(() => repository.fetchFilterZones()));
/// ```
final class const LoadUse<S>(final Future<S> Function() load)
    implements AsyncCommand<S> {
  @override
  Future<void> execute(
    StateReader<S> reader,
    StateWriter<S> writer,
    CancelToken cancel,
  ) async {
    final next = await load();
    if (cancel.isCancelled) return;
    writer.commit(next);
  }
}

/// Асинхронно вычисляет новое состояние из текущего — обобщённая версия
/// паттерна "прочитать current → сделать IO → закоммитить" (ровно то, что вы
/// писали руками в `setThemeMode`), без отдельного класса команды.
///
/// ```dart
/// store.dispatchAsync(UpdateAsyncUse((current) async {
///   final updated = current.rebuild((t) => t.themeMode = mode.index);
///   await themeStore.setData(data: updated);
///   return updated;
/// }));
/// ```
final class const UpdateAsyncUse<S>(final Future<S> Function(S current) update)
    implements AsyncCommand<S> {
  @override
  Future<void> execute(
    StateReader<S> reader,
    StateWriter<S> writer,
    CancelToken cancel,
  ) async {
    final result = await update(reader.current);

    if (cancel.isCancelled) return;

    writer.commit(result);
  }
}

/// Выполняет асинхронное действие, не трогая состояние — отправить аналитику,
/// дёрнуть API без сохранения результата и т.п. (fire-and-forget).
///
/// ```dart
/// store.dispatchAsync(RunUse(() => analytics.logEvent('screen_opened')));
/// ```
final class const RunUse<S>(final Future<void> Function() action)
    implements AsyncCommand<S> {
  @override
  Future<void> execute(
    StateReader<S> reader,
    StateWriter<S> writer,
    CancelToken cancel,
  ) => action();
}

// ---------------------------------------------------------------------------
// Async — с эффектом
// ---------------------------------------------------------------------------

/// Как [LoadUse], но дополнительно эмитирует side-эффект.
///
/// ```dart
/// store.dispatchAsyncWithEffect(
///   LoadWithEffectUse(() => repository.fetchZones(), effect: const ZonesLoaded()),
/// );
/// ```

final class const LoadWithEffectUse<S, E>(
  final Future<S> Function() load,
  final E? effect,
) implements AsyncSideEffect<S, E> {
  @override
  Future<E?> execute(
    StateReader<S> reader,
    StateWriter<S> writer,
    CancelToken cancel,
  ) async {
    final result = await load();
    if (cancel.isCancelled) return null;

    writer.commit(result);

    return effect;
  }
}

/// Как [UpdateAsyncUse], но функция сразу возвращает и состояние, и
/// опциональный эффект.
///
/// ```dart
/// store.dispatchAsyncWithEffect(UpdateAsyncWithEffectUse((current) async {
///   final user = await api.login(credentials);
///   return (current.copyWith(user: user), const NavigateToHome());
/// }));
/// ```

final class const UpdateAsyncWithEffectUse<S, E>(
  final Future<(S next, E? effect)> Function(S current) update,
) implements AsyncSideEffect<S, E> {
  @override
  Future<E?> execute(
    StateReader<S> reader,
    StateWriter<S> writer,
    CancelToken cancel,
  ) async {
    final (next, effect) = await update(reader.current);
    if (cancel.isCancelled) return null;

    writer.commit(next);

    return effect;
  }
}

/// Выполняет асинхронное действие и возвращает эффект по результату, не
/// трогая состояние — например, попытка повторной отправки кода, которая
/// либо показывает тост об успехе, либо ошибку, но ничего не пишет в стор.
///
/// ```dart
/// store.dispatchAsyncWithEffect(RunWithEffectUse(() async {
///   try {
///     await api.resendCode();
///     return const ShowSnackBar('Код отправлен повторно');
///   } catch (e) {
///     return ShowSnackBar('Не удалось отправить: $e');
///   }
/// }));
/// ```
final class const RunWithEffectUse<S, E>(final Future<E?> Function() action)
    implements AsyncSideEffect<S, E> {
  @override
  Future<E?> execute(
    StateReader<S> reader,
    StateWriter<S> writer,
    CancelToken cancel,
  ) async {
    final effect = await action();
    if (cancel.isCancelled) return null;

    return effect;
  }
}

// ---------------------------------------------------------------------------
// Stream — без эффекта
// ---------------------------------------------------------------------------
/// Подписывается на внешний `Stream<S>` и коммитит каждое значение через
/// [writer]. Ошибку и отмену подписки при dispose провайдера контролирует
/// [HelmAsyncstore.dispatchWatch] — сама команда ничего не знает про
/// жизненный цикл.
///
/// ```dart
/// store.dispatchWatch(WatchUse(() => socket.messages));
/// ```
final class const WatchUse<S>(final Stream<S> Function() sources)
    implements StreamCommand<S> {
  @override
  Stream<void> execute(
    StateReader<S> reader,
    StateWriter<S> writer,
    CancelToken cancel,
  ) => sources().map((value) => writer.commit(value));
}

// ---------------------------------------------------------------------------
// Stream — с эффекта
// ---------------------------------------------------------------------------

/// Как [WatchUse], но дополнительно эмитирует side-эффект на каждое значение
/// потока — например, показать снекбар на определённый тип сообщения,
/// оставив остальные события без эффекта.
///
/// ```dart
/// store.dispatchWatchWithEffect(
///   WatchWithEffectUse(
///     () => socket.messages,
///     effect: (msg) => msg.isImportant ? NewMessageAlert(msg) : null,
///   ),
/// );
/// ```

final class const WatchWithEffectUse<S, E>(
  final Stream<S> Function() source, {
  final E? Function(S value)? effect,
}) implements StreamSideEffect<S, E> {
  @override
  Stream<E?> execute(
    StateReader<S> reader,
    StateWriter<S> writer,
    CancelToken cancel,
  ) => source().map((value) {
    writer.commit(value);

    return effect?.call(value);
  });
}
