import 'state_access.dart';
import 'cancel_token.dart';

/// Decorator над [StateWriter], блокирующий коммиты после отмены токена —
/// второй рубеж защиты поверх контракта "команда сама проверяет
/// `CancelToken.isCancelled` перед каждым commit". Если команда нарушает
/// контракт, [GuardedWriter] просто отбрасывает лишний коммит, не пуская
/// устаревшие данные в хранилище.
///
/// ### Диагностика отброшенного коммита
///
/// Два независимых канала, оба опциональны и не заменяют друг друга:
///
/// - [onDroppedCommit] — обычный колбэк, работающий в **любой** сборке
///   (debug и release). Нужен, когда отброшенный коммит — это не просто
///   баг для консоли, а событие, которое стоит отправить в Sentry/аналитику
///   прямо из продакшена (например, чтобы отследить частоту гонок вокруг
///   конкретной команды). Передаётся явно через `StateStore` — по умолчанию
///   `null`, ничего не делает.
/// - Отдельный `assert` с always-true телом — печатает подсказку только в
///   debug-режиме (тот же паттерн, что и в самом Flutter SDK) и никогда не
///   бросает исключение. Это подсказка разработчику во время отладки, а не
///   канал для продакшен-мониторинга — для него используй [onDroppedCommit].
///
/// В любом случае коммит после отмены остаётся тихим и безопасным исходом:
/// [commit] никогда не бросает исключение из-за самой диагностики.
///
/// Печатает подсказку обычным `print` (а не `debugPrint` из
/// `package:flutter/foundation.dart`) — этот файл часть чистого Dart-ядра
/// (`package:helm/helm.dart`) без единого импорта из `package:flutter`, см.
/// докстринг `StateStore`.
final class const GuardedWriter<S>(
  final StateWriter<S> _inner,
  final CancelToken _token,

  /// Имя команды для debug-сообщения — см. `DispatchLabeled`. Передаётся
  /// явно из `StateStore`, а не через `$runtimeType`, который для этого
  /// класса всегда показал бы `GuardedWriter<S>`, а не саму команду.
  final String _commandLabel, {

  /// См. докстринг класса, раздел "Диагностика отброшенного коммита".
  final void Function(String commandLabel, S nextState)? _onDroppedCommit,
}) implements StateWriter<S> {
  @override
  void commit(S nextState) {
    if (_token.isCancelled) {
      assert(() {
        print(
          'Helm: commit после отмены — команда $_commandLabel не проверяет '
          'cancel.isCancelled самостоятельно (коммит проигнорирован).',
        );

        return true;
      }());

      _onDroppedCommit?.call(_commandLabel, nextState);

      return;
    }

    _inner.commit(nextState);
  }
}
