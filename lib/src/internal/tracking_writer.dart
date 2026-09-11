import 'state_access.dart';

/// Decorator над [StateWriter], фиксирующий факт и "before"-состояние
/// [commit] — нужен там, где нельзя заранее знать состояние "до": в
/// Stream-командах коммит происходит на каждой итерации потока, до того как
/// значение дойдёт до подписчика `StateStore`.
///
/// `StateStore` использует это, чтобы сгруппировать все коммиты одной
/// итерации потока в единый цикл "before → after" для `DispatchEvent` —
/// одна запись в логе на итерацию, а не на каждый отдельный коммит внутри
/// неё. Публикация самого состояния — не забота этого класса: он оборачивает
/// [EmittingWriter] как `_inner` и просто делегирует каждый [commit], так
/// что в поток состояний уходит любое изменение сразу, независимо от
/// группировки по итерациям.
final class TrackingWriter<S>(
  final StateWriter<S> _inner,
  final StateReader<S> _reader,
) implements StateWriter<S> {
  bool _changed = false;
  bool _captured = false;
  late S _before;

  /// Было ли зафиксировано новое состояние с момента последнего [reset].
  bool get hasChanged => _changed;

  /// Состояние на момент первого [commit] после последнего [reset].
  S get before {
    assert(
      _captured,
      'TrackingWriter.before прочитан до первого commit() в этом цикле',
    );

    return _before;
  }

  /// Сбрасывает флаг изменения — вызывается после обработки каждой итерации
  /// Stream-команды.
  void reset() {
    _changed = false;
    _captured = false;
  }

  @override
  void commit(S nextState) {
    if (!_captured) {
      _before = _reader.current;
      _captured = true;
    }

    _changed = true;
    _inner.commit(nextState);
  }
}
