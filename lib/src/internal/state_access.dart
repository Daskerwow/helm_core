import '../store/state_storage.dart';

/// Право только на чтение состояния — передаётся запросам и наблюдателям.
abstract interface class StateReader<S> {
  S get current;
}

/// Право только на запись состояния — передаётся командам.
///
/// Принцип минимальных привилегий (ISP): команда не может прочитать
/// устаревший снапшот мимо [StateReader], а наблюдатель не может изменить
/// состояние.
abstract interface class StateWriter<S> {
  /// Фиксирует новое состояние. `StateStore` эмитирует обновление
  /// синхронно, в момент вызова.
  void commit(S nextState);
}

/// Полный доступ: чтение и запись.
abstract interface class StateAccessor<S>
    implements StateReader<S>, StateWriter<S> {}

/// Адаптер [StateAccessor] → [StateStorage] — без бизнес-логики.
final class const StateAccessorImpl<S>(final StateStorage<S> _storage)
    implements StateAccessor<S> {
  @override
  S get current => _storage.read();

  @override
  void commit(S nextState) => _storage.write(nextState);
}
