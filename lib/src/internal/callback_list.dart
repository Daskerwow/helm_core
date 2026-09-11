/// Список колбэков с безопасной итерацией **без копирования на каждый
/// вызов** — алгоритм соответствует `ChangeNotifier` из
/// `package:flutter/src/foundation/change_notifier.dart`, адаптированному
/// под generic `T` вместо `VoidCallback`.
///
/// ### Почему не growable `List<T>`
///
/// Список слушателей хранится не как обычный растущий `List<T>`
/// (`<T>[]`), а вручную — fixed-length `List<T?>` + отдельный счётчик
/// [_count]. Это тот же приём, что и в самом `ChangeNotifier` Flutter SDK:
/// это горячий путь (вызывается на каждый `commit`/`notifyListeners`), и
/// накладные расходы growable-обёртки поверх fixed-length массива на нём
/// заметны.
///
/// ### Компактизация с гистерезисом
///
/// - если живых элементов ≤ половины текущей ёмкости массива — выделяется
///   новый массив точного размера (иначе список рос бы бесконечно после
///   разового всплеска подписчиков и никогда не сжимался обратно);
/// - иначе — компактизация НА МЕСТЕ через попарные свопы, без единой
///   аллокации.
///
/// ### Реентрантность
///
/// [addListener]/[removeListener]/[clearListener] безопасны для вызова изнутри [notifyListeners] — типичный
/// сценарий, когда слушатель сам меняет состав подписчиков (например,
/// реагирует на событие закрытием всего источника публикаций). Во время
/// активной итерации удаления не сдвигают массив физически (это сломало бы
/// индексы цикла), а помечают слот `null` (tombstone); реальная уборка
/// происходит в конце самого внешнего [notifyListeners].
///
/// ### Изоляция ошибок слушателей — параметр [notifyListeners]`.onError`
///
/// По умолчанию исключение из слушателя внутри [notifyListeners] **не
/// перехватывается** — прерывает текущий проход и летит вызывающему коду
/// (тот же контракт, что и раньше). Это осознанное поведение по умолчанию:
/// молчаливое поглощение чужого исключения без адресата — это подмена
/// семантики, а не перформанс-оптимизация.
///
/// Если вызывающий код передаёт `onError`, [notifyListeners] переключается в
/// изолированный режим: исключение из одного слушателя перехватывается,
/// передаётся в `onError`, а проход продолжается для остальных слушателей.
/// Так `StateStore` защищает свои каналы (`addOnChanged`/`addOnEffect`/
/// `addDispatchListener`) — один "плохой" слушатель (например, упавший
/// аналитический хук) не должен блокировать доставку события остальным
/// (см. `StateStore._ListenerHub` в `state_store.dart`).
///
/// ### Гарантия восстановления [_notificationCallStackDepth]
///
/// Тело цикла в [notifyListeners] обёрнуто в `try/finally`: если слушатель
/// бросает исключение (в режиме без `onError`) или сам переданный `onError`
/// бросает исключение при обработке чужой ошибки — счётчик вложенности
/// [_notificationCallStackDepth] всё равно корректно декрементируется, а
/// накопленные tombstone-слоты (если реентрантно что-то удалили до
/// исключения) всё равно компактизируются. Без этой гарантии однажды
/// брошенное исключение навсегда переводило бы список в "реентрантный"
/// режим: [removeListener]/[clearListener] дальше работали бы только через
/// пометку `null` без физической компактизации — внутренний массив рос бы
/// бесконечно при каждом последующем add/remove.
final class CallbackList<T> {
  List<T?> _listeners = List<T?>.filled(0, null);

  /// Число слотов в [_listeners], реально занятых (включая ещё не
  /// скомпактированные tombstone-слоты) — не то же самое, что число
  /// активных слушателей во время реентрантного notify; см. [length].
  int _count = 0;

  /// Глубина вложенности активных [notifyListeners] — не ноль, если слушатель
  /// синхронно триггерит новую публикацию изнутри своего же вызова.
  int _notificationCallStackDepth = 0;

  /// Сколько слотов сейчас помечены `null` (tombstone) реентрантным
  /// [removeListener]/[clearListener] — ждут компактизации в конце самого внешнего [notifyListeners].
  int _reentrantlyRemovedListeners = 0;

  /// Текущее число живых слушателей.
  int get length => _count - _reentrantlyRemovedListeners;

  bool get isEmpty => length == 0;

  /// Как `ChangeNotifier.addListener`: если тот же [listener] уже
  /// зарегистрирован, добавляется ещё один инстанс — вызывается столько
  /// раз, сколько был добавлен, снимается по одному вхождению за [removeListener].
  void addListener(T listener) {
    if (_count == _listeners.length) {
      if (_count == 0) {
        _listeners = List<T?>.filled(1, null);
      } else {
        final newListeners = List<T?>.filled(_listeners.length * 2, null);
        for (var i = 0; i < _count; i++) {
          newListeners[i] = _listeners[i];
        }
        _listeners = newListeners;
      }
    }
    _listeners[_count++] = listener;
  }

  void _removeAt(int index) {
    // Сжимаем backing-массив только если живых элементов после удаления
    // ≤ половины его длины — иначе просто сдвигаем хвост на месте, без
    // реаллокации. Без этого порога список рос бы, но никогда не
    // уменьшался, а с ним — не дёргался бы grow/shrink на каждый цикл
    // add/remove одного элемента у границы.
    _count -= 1;
    if (_count * 2 <= _listeners.length) {
      final newListeners = List<T?>.filled(_count, null);
      for (var i = 0; i < index; i++) {
        newListeners[i] = _listeners[i];
      }
      for (var i = index; i < _count; i++) {
        newListeners[i] = _listeners[i + 1];
      }
      _listeners = newListeners;
    } else {
      for (var i = index; i < _count; i++) {
        _listeners[i] = _listeners[i + 1];
      }
      _listeners[_count] = null;
    }
  }

  /// Убирает первое вхождение [listener] (сравнение по `==`). Не найден —
  /// no-op, безопасно для повторного вызова.
  void removeListener(T listener) {
    for (var i = 0; i < _count; i++) {
      final at = _listeners[i];
      if (at != listener) continue;

      if (_notificationCallStackDepth > 0) {
        _listeners[i] = null;
        _reentrantlyRemovedListeners++;
      } else {
        _removeAt(i);
      }
      return;
    }
  }

  /// Убирает всех слушателей. Безопасен для вызова изнутри [notifyListeners] — см.
  /// докстринг класса про реентрантность.
  void clearListener() {
    if (_notificationCallStackDepth > 0) {
      for (var i = 0; i < _count; i++) {
        _listeners[i] = null;
      }
      _reentrantlyRemovedListeners = _count;
    } else {
      _listeners = List<T?>.filled(0, null);
      _count = 0;
      _reentrantlyRemovedListeners = 0;
    }
  }

  /// Вызывает [callback] для каждого текущего слушателя. Слушатели,
  /// добавленные во время вызова, в этот проход не попадают; удалённые во
  /// время вызова — попадают, но пропускаются.
  ///
  /// [onError], если передан, включает изоляцию ошибок между слушателями —
  /// см. докстринг класса, раздел "Изоляция ошибок слушателей". Без
  /// [onError] поведение как раньше: первое исключение прерывает проход.
  ///
  /// Счётчик вложенности [_notificationCallStackDepth] и последующая
  /// компактизация гарантированно восстанавливаются даже при исключении —
  /// см. докстринг класса, раздел "Гарантия восстановления".
  void notifyListeners(
    void Function(T listener) callback, {
    void Function(Object error, StackTrace stackTrace)? onError,
  }) {
    if (_count == 0) return;

    _notificationCallStackDepth++;
    try {
      final end = _count;
      for (var i = 0; i < end; i++) {
        final listener = _listeners[i];
        if (listener == null) continue;

        if (onError == null) {
          callback(listener);
        } else {
          try {
            callback(listener);
          } catch (e, st) {
            onError(e, st);
          }
        }
      }
    } finally {
      _notificationCallStackDepth--;

      if (_notificationCallStackDepth == 0 &&
          _reentrantlyRemovedListeners > 0) {
        _compactAfterReentrantRemoval();
      }
    }
  }

  /// Физическая уборка tombstone-слотов, накопленных реентрантными
  /// [removeListener]/[clearListener] во время только что завершившегося самого внешнего
  /// [notifyListeners].
  void _compactAfterReentrantRemoval() {
    final newLength = _count - _reentrantlyRemovedListeners;

    if (newLength * 2 <= _listeners.length) {
      // Сильно разрежено (больше половины — tombstone) — перевыделяем
      // точный по размеру массив одним проходом.
      final compacted = List<T?>.filled(newLength, null);
      var w = 0;
      for (var i = 0; i < _count; i++) {
        final listener = _listeners[i];
        if (listener != null) compacted[w++] = listener;
      }
      _listeners = compacted;
    } else {
      // Иначе — компактизация НА МЕСТЕ попарными свопами, без аллокации:
      // каждый null-слот в живой части меняется местами с ближайшим
      // следующим не-null.
      for (var i = 0; i < newLength; i++) {
        if (_listeners[i] == null) {
          var swap = i + 1;
          while (_listeners[swap] == null) {
            swap++;
          }
          _listeners[i] = _listeners[swap];
          _listeners[swap] = null;
        }
      }
    }

    _reentrantlyRemovedListeners = 0;
    _count = newLength;
  }
}
