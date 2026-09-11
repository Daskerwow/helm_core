import 'dart:async';

import 'cancel_token.dart';

/// Активная stream-подписка вместе с лейблом команды, её породившей.
///
/// Лейбл нужен отдельно от самой подписки: в момент отмены (вытеснение
/// новым `StateStore.dispatchStream`/`StateStore.dispatchStreamWithEffect`
/// той же группы, явный `StateStore.cancelStream` или `StateStore.close`)
/// самой команды уже нет под рукой — её видел только `execute()` в момент
/// подписки — а `DispatchEvent` требует `commandLabel`.
final class const ActiveStreamSubscription(
  final StreamSubscription<void> subscription,
  final String label,
  final CancelToken cancelToken,
);

/// Реестр "что сейчас летит и как это отменить" — активные async-токены
/// отмены и активные stream-подписки диспатча.
///
/// Вынесен из `StateStore` отдельным классом (Single Responsibility): Store
/// отвечает за оркестрацию самого диспатча (создание writer'ов, запуск
/// команд, публикацию `DispatchEvent`/side-эффектов), а не за учёт и
/// компактизацию реестров токенов/подписок — это самодостаточная забота,
/// которую теперь можно тестировать в изоляции, без полноценного
/// dispatch-цикла Store.
///
/// Намеренно не публикует `DispatchEvent` сам — у реестра нет доступа к
/// `_ListenerHub` `StateStore`. [cancelStream] лишь возвращает лейбл
/// отменённой команды (или `null`, если по ключу ничего не было), из
/// которого вызывающий код (`StateStore._cancelStreamSubscription`) строит
/// само событие.
final class DispatchRegistry {
  final _cancelTokens = <Object, CancelToken>{};
  final _streamSubs = <Object, ActiveStreamSubscription>{};

  /// Отменяет предыдущий токен той же группы (если был, с
  /// [CancelReason.superseded]) и заводит новый — вызывается перед каждым
  /// async-диспатчем.
  CancelToken acquireToken(Object key) {
    _cancelTokens[key]?.cancel(CancelReason.superseded);
    return _cancelTokens[key] = CancelToken();
  }

  /// Удаляет токен из реестра, если он не был заменён новым (т.е. это
  /// всё ещё тот же самый инстанс) — вызывается по завершении
  /// async-диспатча независимо от исхода (успех/ошибка/отмена).
  void releaseToken(Object key, CancelToken token) {
    if (_cancelTokens[key] == token) _cancelTokens.remove(key);
  }

  /// Отменяет активный async-токен по ключу. No-op, если по [key] сейчас
  /// ничего не выполняется.
  void cancelToken(Object key, CancelReason reason) =>
      _cancelTokens[key]?.cancel(reason);

  /// Отменяет все активные async-токены. Уже завершённые не затрагиваются.
  void cancelAllTokens(CancelReason reason) {
    for (final token in _cancelTokens.values) {
      token.cancel(reason);
    }
  }

  /// Регистрирует новую активную stream-подписку под [key]. Предыдущая
  /// подписка той же группы должна быть отменена вызывающим кодом заранее
  /// (см. [cancelStream]) — реестр этого сам не делает.
  void registerStream(
    Object key,
    StreamSubscription<void> subscription,
    String label,
    CancelToken cancelToken,
  ) {
    _streamSubs[key] = ActiveStreamSubscription(
      subscription,
      label,
      cancelToken,
    );
  }

  /// Убирает завершившуюся подписку, но только если она всё ещё актуальна
  /// для ключа: старая `onDone` не должна удалить уже запущенную замену.
  void releaseStream(Object key, StreamSubscription<void> subscription) {
    if (identical(_streamSubs[key]?.subscription, subscription)) {
      _streamSubs.remove(key);
    }
  }

  /// Отменяет активную stream-подписку по [key] и возвращает её лейбл —
  /// `null`, если по [key] нет активной подписки (например, повторная
  /// отмена или отмена уже завершившегося потока).
  String? cancelStream(Object key, CancelReason reason) {
    final entry = _streamSubs.remove(key);
    if (entry == null) return null;

    entry.cancelToken.cancel(reason);
    entry.subscription.cancel();
    return entry.label;
  }

  /// Снимок ключей активных stream-подписок — для безопасной итерации при
  /// массовой отмене (например, в `StateStore.close`), пока сама итерация
  /// мутирует реестр через [cancelStream].
  List<Object> get activeStreamKeys => _streamSubs.keys.toList(growable: false);

  /// Забывает все токены без их отмены — вызывающий код должен отменить их
  /// заранее (см. `StateStore.close`, который сначала отменяет всё через
  /// [cancelAllTokens]/[cancelStream], и только потом зовёт [clear]).
  void clear() => _cancelTokens.clear();
}
