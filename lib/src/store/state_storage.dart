/// Контракт синхронного хранилища состояния.
///
/// Намеренно примитивный (Dependency Inversion: `StateStore` зависит от
/// этого интерфейса, а не от конкретной реализации). По умолчанию
/// используется [StateMemoryStorage].
///
/// Персистентные асинхронные хранилища (SharedPreferences, sqflite,
/// Hive) не реализуют этот интерфейс напрямую — оберни их: прочитай
/// начальное значение асинхронно *до* создания `StateStore`, а запись
/// на диск делай как побочный эффект в `onChanged`/команде, а не в
/// [write]. Это сознательное ограничение: Store — это runtime-состояние
/// в памяти с быстрым синхронным доступом, а не ORM.
abstract interface class StateStorage<S> {
  S read();
  void write(S state);
}

/// Хранилище состояния в памяти — реализация по умолчанию.
final class StateMemoryStorage<S>(var S _state) implements StateStorage<S> {
  @override
  S read() => _state;

  @override
  void write(S state) => _state = state;
}
