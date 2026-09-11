import '../internal/cancel_token.dart';
import '../loadable.dart';
import '../internal/state_access.dart';
import 'side_effect_commands.dart';
import 'commands.dart';

/// Общее ядро "loading → data / error" для [LoadableUse] и
/// [LoadableWithEffectUse] — обе команды делают ровно один и тот же цикл
/// запросов к [load], отличаясь только тем, что происходит с результатом
/// (проброс исключения дальше vs. превращение в side-эффект). Раньше это
/// был один и тот же try/catch, дословно продублированный в двух классах.
///
/// [onData]/[onError] вызываются уже ПОСЛЕ соответствующего коммита — им
/// остаётся только решить, что делать с результатом на уровне конкретной
/// команды (ничего, rethrow, side-эффект).
Future<void> _runLoadable<S>({
  required StateReader<Loadable<S>> reader,
  required StateWriter<Loadable<S>> writer,
  required CancelToken cancel,
  required Future<S> Function() load,
  required void Function(S value) onData,
  required void Function(Object error, StackTrace stackTrace) onError,
}) async {
  final previous = reader.current.valueOrNull;
  writer.commit(Loadable.loading(previous));

  try {
    final value = await load();
    if (cancel.isCancelled) return;

    writer.commit(Loadable.data(value));
    onData(value);
  } catch (e, st) {
    if (cancel.isCancelled) return;

    writer.commit(Loadable.error(e, stackTrace: st, previous: previous));
    onError(e, st);
  }
}

/// Запускает загрузку и проводит [Loadable] через `loading → data / error`.
/// Предыдущее успешное значение переносится в [Loadable.loading] и, при
/// неудаче, в [Loadable.error] — старые данные остаются видимыми на время
/// повторной загрузки.
///
/// Исключение из [load] перебрасывается дальше *после* обновления состояния
/// на [Loadable.error] — `onError`/`DispatchFailure` продолжают работать как
/// для любой другой async-команды.
///
/// ```dart
/// store.dispatch(LoadableUse(() => api.fetchTodos()));
/// ```
final class LoadableUse<S> implements AsyncCommand<Loadable<S>> {
  const LoadableUse(this.load);

  /// Асинхронная загрузка значения. Вызывается заново при каждом
  /// [execute] — то есть при каждом `dispatch` этой команды.
  final Future<S> Function() load;

  @override
  Future<void> execute(
    StateReader<Loadable<S>> reader,
    StateWriter<Loadable<S>> writer,
    CancelToken cancel,
  ) => _runLoadable<S>(
    reader: reader,
    writer: writer,
    cancel: cancel,
    load: load,
    onData: (_) {},
    // Сохраняем оригинальный stack trace, хотя rethrow здесь синтаксически
    // невозможен (мы уже не в блоке catch самой команды, а в колбэке).
    onError: (e, st) => Error.throwWithStackTrace(e, st),
  );
}

/// Как [LoadableUse], но ошибка не пробрасывается наружу, а превращается в
/// side-эффект — команда всегда завершается штатно, реагировать на исход
/// (показать SnackBar, залогировать) решает вызывающий код через
/// [onSuccess]/[onError], а не глобальный `onError` стора.
///
/// Ровно один из колбэков будет вызван за один [execute]: [onSuccess] — при
/// успешной загрузке, [onError] — при исключении из [load]. State к этому
/// моменту уже закоммичен в [Loadable.data]/[Loadable.error] — колбэки
/// работают только с результатом, не с состоянием напрямую.
///
/// ```dart
/// store.dispatchAsyncWithEffect(LoadableWithEffectUse(
///   () => api.fetchProfile(),
///   onError: (e, st) => ShowSnackBar('Не удалось загрузить профиль: $e'),
/// ));
/// ```
final class LoadableWithEffectUse<S, E>
    implements AsyncSideEffect<Loadable<S>, E> {
  const LoadableWithEffectUse(this.load, {this.onSuccess, this.onError});

  /// Асинхронная загрузка значения. Вызывается заново при каждом [execute].
  final Future<S> Function() load;

  /// Вызывается при успешной загрузке уже после коммита [Loadable.data].
  /// Возвращённое значение (если не `null`) отправляется как side-эффект.
  final E? Function(S value)? onSuccess;

  /// Вызывается при исключении из [load] уже после коммита
  /// [Loadable.error]. Возвращённое значение (если не `null`) отправляется
  /// как side-эффект. В отличие от [LoadableUse], исключение здесь
  /// поглощается — если [onError] не задан, ошибка просто уходит в state
  /// без side-эффекта и без rethrow.
  final E? Function(Object error, StackTrace stackTrace)? onError;

  @override
  Future<E?> execute(
    StateReader<Loadable<S>> reader,
    StateWriter<Loadable<S>> writer,
    CancelToken cancel,
  ) async {
    E? effect;

    await _runLoadable<S>(
      reader: reader,
      writer: writer,
      cancel: cancel,
      load: load,
      onData: (value) => effect = onSuccess?.call(value),
      onError: (e, st) => effect = onError?.call(e, st),
    );

    return effect;
  }
}

/// Подписывается на внешний `Stream<S>` и отражает его в [Loadable]: каждое
/// значение — [Loadable.data], ошибка потока — [Loadable.error] (подписка
/// не завершается, поток продолжает слушаться — самовосстанавливающееся
/// соединение).
///
/// В отличие от [LoadableUse], `loading` коммитится только при первой
/// подписке без данных (см. [execute]) — поток шлёт значения часто, и
/// мигать в `loading` перед каждым было бы UI-шумом.
///
/// Если фабрика [source] бросает исключение синхронно (например, невалидные
/// параметры URL при построении WebSocket) — оно перехватывается: состояние
/// переходит в [Loadable.error], а наружу возвращается `Stream.error(...)`,
/// который `StateStore` обработает обычным путём вместо необработанного
/// исключения из `StateStore.dispatchStream`.
///
/// ```dart
/// store.dispatchStream(WatchLoadableUse(() => socket.messages));
/// ```
/// Строит `Stream` при каждой подписке, а не готовый `Stream`, чтобы
/// повторный `StateStore.dispatchStream` пересоздавал подписку с нуля.
final class WatchLoadableUse<S> implements StreamCommand<Loadable<S>> {
  const WatchLoadableUse(this.source);

  /// Фабрика внешнего стрима. Вызывается заново при каждой подписке на
  /// результат [execute], а не один раз при создании команды.
  final Stream<S> Function() source;

  @override
  Stream<void> execute(
    StateReader<Loadable<S>> reader,
    StateWriter<Loadable<S>> writer,
    CancelToken cancel,
  ) {
    if (reader.current is! LoadableData<S>) {
      writer.commit(Loadable.loading(reader.current.valueOrNull));
    }

    final Stream<S> stream;

    try {
      stream = source();
    } catch (e, st) {
      writer.commit(
        Loadable.error(e, stackTrace: st, previous: reader.current.valueOrNull),
      );
      return Stream<void>.error(e, st);
    }

    return stream
        .map((value) => writer.commit(Loadable.data(value)))
        .handleError(
          (Object e, StackTrace st) => writer.commit(
            Loadable.error(
              e,
              stackTrace: st,
              previous: reader.current.valueOrNull,
            ),
          ),
        );
  }
}

/// Как [WatchLoadableUse], но каждое полученное значение дополнительно
/// проходит через [effect] и может породить side-эффект (например,
/// показать уведомление о новом сообщении в чате), не прерывая при этом
/// обновление [Loadable] в state.
///
/// [effect] вызывается только для успешных значений потока — как и в
/// [LoadableWithEffectUse.onError] относительно [LoadableWithEffectUse.load],
/// здесь нет симметричного колбэка для ошибок потока: ошибка коммитится в
/// [Loadable.error], но side-эффект на неё не порождается, потому что
/// [effect] типизирован на `S`, а не на `Loadable<S>` или `Object`.
///
/// Если фабрика [source] бросает исключение синхронно — состояние уходит в
/// [Loadable.error], а наружу возвращается пустой стрим (`Stream.empty()`)
/// вместо `Stream.error`, поскольку `Stream<E?>` не может нести объект
/// исключения типа `Object` — это сделало бы систему типов недостоверной.
/// Если реакция на такую ошибку тоже нужна как side-эффект, добавьте
/// отдельный колбэк вида `E? Function(Object, StackTrace)?`.
///
/// ```dart
/// store.dispatchStreamWithEffect(WatchLoadableWithEffectUse(
///   () => chat.messages,
///   effect: (msg) => msg.isMention ? ShowNotification(msg) : null,
/// ));
/// ```
final class WatchLoadableWithEffectUse<S, E>
    implements StreamSideEffect<Loadable<S>, E> {
  const WatchLoadableWithEffectUse(this.source, {this.effect});

  /// Фабрика внешнего стрима. Вызывается заново при каждой подписке на
  /// результат [execute].
  final Stream<S> Function() source;

  /// Вызывается для каждого успешного значения потока уже после коммита
  /// [Loadable.data]. Возвращённое значение (если не `null`) отправляется
  /// как side-эффект. Не вызывается при ошибках потока и при синхронном
  /// исключении из [source].
  final E? Function(S value)? effect;

  @override
  Stream<E?> execute(
    StateReader<Loadable<S>> reader,
    StateWriter<Loadable<S>> writer,
    CancelToken cancel,
  ) {
    if (reader.current is! LoadableData<S>) {
      writer.commit(Loadable.loading(reader.current.valueOrNull));
    }

    final Stream<S> stream;

    try {
      stream = source();
    } catch (e, st) {
      writer.commit(
        Loadable.error(e, stackTrace: st, previous: reader.current.valueOrNull),
      );

      return Stream<Never>.empty();
    }

    return stream
        .map((value) {
          writer.commit(Loadable.data(value));

          return effect?.call(value);
        })
        .handleError(
          (Object e, StackTrace st) => writer.commit(
            Loadable.error(
              e,
              stackTrace: st,
              previous: reader.current.valueOrNull,
            ),
          ),
        );
  }
}
