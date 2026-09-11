/// Состояние одного асинхронного ресурса: не запрашивался / грузится /
/// загружен / последняя загрузка упала с ошибкой.
///
/// Аналог `AsyncValue<T>` (Riverpod) / `AsyncSnapshot<T>` (Flutter), без
/// зависимости на них. Используй как весь `S` стора (`StateStore<Loadable<T>, E>`)
/// либо как поле внутри более сложного состояния.
///
/// ```dart
/// final store = StateStore<Loadable<List<Todo>>, Never>(initialState: const Loadable.idle());
/// store.dispatch(LoadCommand(() => api.fetchTodos()));
/// ```
///
/// Ветвление — через [when]/[maybeWhen]/[map]:
///
/// ```dart
/// loadable.when(
///   idle: () => const SizedBox.shrink(),
///   loading: (previous) => previous == null
///       ? const CircularProgressIndicator()
///       : Stack(children: [TodoList(previous), const LinearProgressIndicator()]),
///   data: (todos) => TodoList(todos),
///   error: (e, st, previous) => ErrorView(e),
/// );
/// ```
///
/// ### Если `T` — мутируемая коллекция
///
/// `==` у [LoadableData]/[LoadableLoading]/[LoadableError] делегирует
/// сравнение полю `value`/`previous` типа `T`. Если `T` — `List`/`Set`/`Map`
/// без содержательного `==`, `StateStore`/`HelmSelector` будут видеть новый
/// список с теми же элементами как "другое" состояние на каждый коммит.
/// Передай `equals` в `StateStore`/`HelmComputed`, построенный поверх
/// `listEquals`/`setEquals`/`mapEquals`/`deepEquals` из `equality.dart` —
/// см. их докстринги.
sealed class const Loadable<T>() {
  const factory idle() = LoadableIdle<T>;

  /// [previous] — последнее успешно загруженное значение, если было:
  /// позволяет показать старые данные поверх спиннера (pull-to-refresh).
  const factory loading([T? previous]) = LoadableLoading<T>;

  const factory data(T value) = LoadableData<T>;

  /// [previous] — то же, что и в [Loadable.loading]. Именованные (а не
  /// позиционные) [stackTrace]/[previous] позволяют передать только
  /// [previous] без обязательного явного `null` для [stackTrace]:
  /// `Loadable.error(e, previous: old)` вместо `Loadable.error(e, null, old)`.
  const factory error(Object error, {StackTrace? stackTrace, T? previous}) =
      LoadableError<T>;

  bool get isLoading => this is LoadableLoading<T>;
  bool get isError => this is LoadableError<T>;

  /// Последнее известное значение — из [LoadableData] либо "протянутое"
  /// [previous]. `null`, если значения не было ни разу.
  T? get valueOrNull => switch (this) {
    LoadableIdle<T>() => null,
    LoadableLoading<T>(:final previous) => previous,
    LoadableData<T>(:final value) => value,
    LoadableError<T>(:final previous) => previous,
  };

  Object? get errorOrNull => switch (this) {
    LoadableError<T>(:final error) => error,
    _ => null,
  };

  R when<R>({
    required R Function() idle,
    required R Function(T? previous) loading,
    required R Function(T value) data,
    required R Function(Object error, StackTrace? stackTrace, T? previous)
    error,
  }) => switch (this) {
    LoadableIdle<T>() => idle(),
    LoadableLoading<T>(:final previous) => loading(previous),
    LoadableData<T>(:final value) => data(value),
    LoadableError<T>(error: final e, stackTrace: final st, previous: final p) =>
      error(e, st, p),
  };

  /// Как [when], но с обработкой только нужных веток — остальное в [orElse].
  R maybeWhen<R>({
    R Function()? idle,
    R Function(T? previous)? loading,
    R Function(T value)? data,
    R Function(Object error, StackTrace? stackTrace, T? previous)? error,
    required R Function() orElse,
  }) => when(
    idle: idle ?? orElse,
    loading: loading ?? (_) => orElse(),
    data: data ?? (_) => orElse(),
    error: error ?? (_, _, _) => orElse(),
  );

  /// Паттерн-матчинг по подклассам — удобен, когда нужны сразу несколько
  /// полей конкретного варианта без деструктуризации через [when].
  R map<R>({
    required R Function(LoadableIdle<T> idle) idle,
    required R Function(LoadableLoading<T> loading) loading,
    required R Function(LoadableData<T> data) data,
    required R Function(LoadableError<T> error) error,
  }) => switch (this) {
    final LoadableIdle<T> s => idle(s),
    final LoadableLoading<T> s => loading(s),
    final LoadableData<T> s => data(s),
    final LoadableError<T> s => error(s),
  };
}

final class const LoadableIdle<T>() extends Loadable<T> {
  @override
  bool operator ==(Object other) => other is LoadableIdle<T>;

  @override
  int get hashCode => (LoadableIdle<T>).hashCode;

  @override
  String toString() => 'Loadable.idle()';
}

final class const LoadableLoading<T>([final T? previous]) extends Loadable<T> {
  @override
  bool operator ==(Object other) =>
      other is LoadableLoading<T> && other.previous == previous;

  @override
  int get hashCode => Object.hash(LoadableLoading<T>, previous);

  @override
  String toString() => 'Loadable.loading(previous: $previous)';
}

final class const LoadableData<T>(final T value) extends Loadable<T> {
  @override
  bool operator ==(Object other) =>
      other is LoadableData<T> && other.value == value;

  @override
  int get hashCode => Object.hash(LoadableData<T>, value);

  @override
  String toString() => 'Loadable.data($value)';
}

final class const LoadableError<T>(
  final Object error, {
  final StackTrace? stackTrace,
  final T? previous,
}) extends Loadable<T> {
  /// Сравнивает [error], [stackTrace] и [previous]. `StackTrace` не
  /// переопределяет `==` содержательно (сравнение по идентичности) — это
  /// заодно отличает повторный тот же коммит (тот же `StackTrace` инстанс)
  /// от двух разных бросков одной и той же ошибки.
  @override
  bool operator ==(Object other) =>
      other is LoadableError<T> &&
      other.error == error &&
      other.stackTrace == stackTrace &&
      other.previous == previous;

  @override
  int get hashCode =>
      Object.hash(LoadableError<T>, error, stackTrace, previous);

  @override
  String toString() => 'Loadable.error($error, previous: $previous)';
}
