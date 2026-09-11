import 'state_access.dart';

/// Decorator над [StateWriter], немедленно публикующий каждое реальное
/// изменение состояния — синхронно, в момент вызова [commit], а не отложенно.
///
/// `StateStore` обязан эмитировать в свой поток состояний *любой* успешный
/// коммит, а не только "было до / стало после" всей команды целиком —
/// иначе многошаговые команды вроде `LoadCommand` (коммитит промежуточный
/// `Loadable.loading(...)` перед результатом) не показали бы спиннер
/// подписчикам.
///
/// ### Одно чтение хранилища вместо двух на каждый commit
///
/// Значение "предыдущее" кэшируется в поле [_lastState] при создании и
/// обновляется на каждый [commit] из уже известного `nextState`, а не через
/// повторное чтение `StateAccessor.current` — для хранилищ с дорогим
/// чтением (например, Hive с шифрованием) это вдвое меньше IO на каждый
/// коммит: было "прочитать + записать", стало только "записать".
final class EmittingWriter<S>(
  final StateAccessor<S> _accessor,

  /// Вызывается синхронно сразу после записи, только если значение реально
  /// отличается от предыдущего (см. [_equals]).
  final void Function(S nextState) _onChanged,
  final bool Function(S a, S b) _equals,
) implements StateWriter<S> {
  this : _lastState = _accessor.current;

  S _lastState;

  @override
  void commit(S nextState) {
    _accessor.commit(nextState);

    final changed = !_equals(nextState, _lastState);
    _lastState = nextState;

    if (changed) _onChanged(nextState);
  }
}
