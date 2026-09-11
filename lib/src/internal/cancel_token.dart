import 'callback_list.dart';

/// Причина отмены — см. [CancelToken.reason] и `DispatchCancelled`.
enum CancelReason {
  /// Команда того же `DispatchKeyed.dispatchKey` запущена повторно —
  /// предыдущий вызов вытеснен.
  superseded,

  /// Явный `StateStore.cancel` / `StateStore.cancelAll`.
  userRequested,

  /// Store закрыт через `StateStore.close`.
  storeClosed,

  /// Stream-команда не смогла быть создана или подписана. Используется
  /// внутренне, чтобы ранее выданный ей writer больше не принял commit.
  commandFailed,
}

/// Одноразовый токен отмены асинхронной/потоковой команды.
///
/// Проверяй [isCancelled] после каждого `await`, перед `StateWriter.commit` —
/// это исключает запись устаревшего результата при race condition. Store
/// дополнительно подстраховывает через `GuardedWriter`: коммит после отмены
/// молча игнорируется, даже если команда не проверила токен сама.
///
/// ```dart
/// Future<void> execute(reader, writer, CancelToken cancel) async {
///   final user = await _api.fetchUser();
///   if (cancel.isCancelled) return; // не коммитим устаревшие данные
///   writer.commit(reader.current.copyWith(user: user));
/// }
/// ```
final class CancelToken {
  CancelReason? _reason;

  /// Колбэки, зарегистрированные через [whenCancelled] до отмены токена.
  /// Лениво создаётся — подавляющее большинство токенов вообще не имеет
  /// подписчиков на отмену, заводить под них список заранее незачем.
  CallbackList<void Function()>? _onCancelListeners;

  /// Был ли токен отменён.
  bool get isCancelled => _reason != null;

  /// Причина отмены. `null`, если токен ещё активен.
  CancelReason? get reason => _reason;

  /// Отменяет токен. Повторный вызов — no-op: причина не перезаписывается.
  void cancel([CancelReason reason = CancelReason.userRequested]) {
    if (_reason != null) return;
    _reason = reason;

    final listeners = _onCancelListeners;
    _onCancelListeners = null;

    // Изоляция ошибок между независимыми подписчиками одного токена: у
    // `CancelToken` нет отдельного канала ошибок (в отличие от
    // `StateStore.addErrorListener`), поэтому исключение из одного
    // колбэка репортится тем же debug-only способом, что и диагностика
    // `GuardedWriter` — печатается в debug-режиме, но не прерывает вызов
    // остальных `whenCancelled`-колбэков и никогда не бросает наружу.
    //
    // Используем обычный `print` (а не `debugPrint` из
    // `package:flutter/foundation.dart`): этот файл — часть чистого
    // Dart-ядра (`package:helm/helm.dart`) без единого импорта из
    // `package:flutter`, чтобы Store можно было использовать в CLI,
    // на сервере (`dart:io`), в изоляте — где угодно, где есть Dart.
    listeners?.notifyListeners(
      (callback) => callback(),
      onError: (error, stackTrace) {
        assert(() {
          print(
            'Helm: колбэк CancelToken.whenCancelled бросил исключение при '
            'отмене — остальные колбэки всё равно вызваны: $error',
          );
          return true;
        }());
      },
    );
  }

  /// Регистрирует колбэк, вызываемый ровно один раз в момент отмены —
  /// удобно, чтобы освободить внешний ресурс (сокет, таймер, подписку) без
  /// поллинга [isCancelled]. Если токен уже отменён — вызывается немедленно,
  /// синхронно.
  ///
  /// Можно регистрировать сколько угодно независимых колбэков на один
  /// токен — каждый вызывается ровно один раз при отмене (в порядке
  /// регистрации); ни один не затирает предыдущий и падение одного не
  /// мешает остальным (см. изоляцию ошибок в [cancel]).
  void whenCancelled(void Function() callback) {
    if (isCancelled) {
      callback();
      return;
    }
    (_onCancelListeners ??= CallbackList<void Function()>()).addListener(
      callback,
    );
  }
}
