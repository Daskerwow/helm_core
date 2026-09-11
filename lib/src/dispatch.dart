import 'internal/cancel_token.dart';

/// Тип диспатча — для фильтрации/группировки в middleware и логах.
enum DispatchKind { sync, async, stream }

/// Опциональный контракт команды: свой ключ группировки dispatch/cancel
/// вместо значения по умолчанию — `command.runtimeType`.
///
/// В Dart дженерики реифицированы: `runtimeType` учитывает типовые
/// параметры (`FetchCommand<User>` и `FetchCommand<Todo>` — разные `Type`),
/// поэтому коллизий между разными инстанциациями одного generic-класса нет.
/// [DispatchKeyed] нужен для другого случая — когда **одна и та же**
/// инстанциация команды должна поддерживать несколько параллельных, не
/// вытесняющих друг друга запусков (например, загрузка разных `userId`):
///
/// ```dart
/// final class FetchUserCommand implements AsyncCommand<UserState>, DispatchKeyed {
///   const FetchUserCommand(this.userId);
///   final String userId;
///
///   @override
///   Object get dispatchKey => (FetchUserCommand, userId);
/// }
/// ```
///
/// Без этого второй `dispatch(FetchUserCommand('42'))` отменил бы первый
/// `dispatch(FetchUserCommand('7'))`, хотя это независимые запросы.
///
/// ### Как выбрать `dispatchKey`, чтобы не столкнуться случайно
///
/// Ключ участвует в `Map`-поиске через `==`/`hashCode` — используй
/// значения с содержательным равенством: `Record` (как в примере выше),
/// `String`, `int`, enum-константу. Не используй свежесозданные объекты без
/// переопределённого `==` (например, `Object()`) — такой ключ равен только
/// самому себе и превращает `DispatchKeyed` в бесполезную группировку "сам
/// с собой".
abstract interface class DispatchKeyed {
  Object get dispatchKey;
}

/// Опциональный контракт команды: явное имя для логов/DevTools вместо
/// `runtimeType.toString()`, которое obfuscator в release-сборке минифицирует
/// до бессмысленных `a`/`b`/`c`.
abstract interface class DispatchLabeled {
  String get dispatchLabel;
}

/// Снапшот исхода диспатча — эмитируется в `StateStore.addDispatchListener`
/// при любом исходе: успех, ошибка, отмена.
///
/// ```dart
/// store.addDispatchListener((event) {
///   if (event.isSuccess) analytics.track(event.commandLabel);
///   if (event.isError) Sentry.captureException(event.error!);
/// });
/// ```
final class const DispatchEvent<S>({
  /// Имя команды — см. [DispatchLabeled].
  required final String commandLabel,

  /// Состояние до выполнения команды.
  required final S before,

  /// Состояние после выполнения. При ошибке/отмене без коммита равно [before].
  required final S after,

  /// { sync, async, stream }
  required final DispatchKind kind,

  /// Исключение, если команда завершилась с ошибкой.
  final Object? error,

  /// Время выполнения. `null` для sync-команд (выполняются мгновенно) и
  /// когда никто не подписан на `StateStore.addDispatchListener` — замер не
  /// делается впустую.
  final Duration? elapsed,

  /// Причина отмены. `null`, если команда не была отменена.
  final CancelReason? cancelReason,
}) {
  bool get isSuccess => error == null && cancelReason == null;
  bool get isCancelled => cancelReason != null;
  bool get isError => error != null;

  /// `[OK] [async] FetchUserCommand (120ms)` — компактная строка для логов.
  String toLogString() {
    if (isCancelled) {
      return '(cancelled) [${kind.name}] $commandLabel (${cancelReason!.name})';
    }
    final status = (isSuccess ? '[OK]' : '[FAIL]');
    final time = elapsed != null ? ' (${elapsed!.inMilliseconds}ms)' : '';
    return '$status [${kind.name}] $commandLabel$time';
  }
}

/// Результат `StateStore.dispatch`/`StateStore.dispatchWithEffect`.
///
/// Sealed-иерархия — исчерпывающий `switch` без риска пропустить исход:
///
/// ```dart
/// switch (await store.dispatch(FetchUserCommand())) {
///   case DispatchSuccess(:final state): print(state);
///   case DispatchFailure(:final error, :final stackTrace): logger.error(error, stackTrace);
///   case DispatchCancelled(:final reason): print('отменено: ${reason.name}');
/// }
/// ```
sealed class const DispatchResult<S>();

/// Команда выполнена успешно.
final class const DispatchSuccess<S>(
  /// Состояние Store после выполнения команды.
  final S state,
) extends DispatchResult<S>;

/// Команда завершилась необработанным исключением.
///
/// Состояние могло измениться: любой `StateWriter.commit`, сделанный до
/// исключения, уже применён и опубликован.
final class const DispatchFailure<S>(
  final Object error,
  final StackTrace stackTrace,
) extends DispatchResult<S>;

/// Команда отменена до завершения.
final class const DispatchCancelled<S>(
  /// Причина отмены:
  /// - [CancelReason.superseded] — команда того же
  ///   `DispatchKeyed.dispatchKey` запущена повторно, предыдущий вызов
  ///   вытеснен;
  /// - [CancelReason.userRequested] — явный `StateStore.cancel` /
  ///   `StateStore.cancelAll`;
  /// - [CancelReason.storeClosed] — Store закрыт через `StateStore.close`.
  /// - [CancelReason.commandFailed] — Stream-команда не смогла стартовать;
  ///   это внутреннее состояние защиты writer, а не результат public dispatch.
  ///
  /// Состояние могло измениться: коммиты до отмены уже применены — Store
  /// лишь гарантирует, что коммиты *после* отмены игнорируются.
  final CancelReason reason,
) extends DispatchResult<S>;
