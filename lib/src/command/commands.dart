import '../internal/cancel_token.dart';
import '../internal/state_access.dart';

/// Мгновенная синхронная мутация состояния — без IO и side-эффектов.
///
/// Должен быть чистой функцией. Гарантированно выполняется атомарно, без
/// `await`, без токена отмены.
///
/// ```dart
/// final class ToggleThemeCommand implements SyncCommand<AppState> {
///   const ToggleThemeCommand();
///   @override
///   AppState execute(AppState current) => current.copyWith(isDark: !current.isDark);
/// }
/// ```
abstract interface class const SyncCommand<S>() {
  S execute(S current);
}

/// Единичное асинхронное действие без side-эффекта.
///
/// Проверяй `CancelToken.isCancelled` перед каждым `StateWriter.commit` —
/// см. докстринг `CancelToken`.
///
/// ```dart
/// final class FetchUserCommand implements AsyncCommand<UserState> {
///   const FetchUserCommand(this._api);
///   final UserApi _api;
///
///   @override
///   Future<void> execute(reader, writer, cancel) async {
///     final user = await _api.fetchUser();
///     if (cancel.isCancelled) return;
///     writer.commit(reader.current.copyWith(user: user));
///   }
/// }
/// ```
abstract interface class const AsyncCommand<S>() {
  Future<void> execute(
    StateReader<S> reader,
    StateWriter<S> writer,
    CancelToken cancel,
  );
}

/// Подписка на внешний `Stream`, коммитящая каждое входящее значение.
///
/// Store управляет жизненным циклом подписки: отписывается при
/// `StateStore.close` или при повторном `StateStore.dispatchStream` с той
/// же группой отмены (см. `DispatchKeyed`).
///
/// ```dart
/// final class LocationStreamCommand implements StreamCommand<MapState> {
///   const LocationStreamCommand(this._gps);
///   final GpsService _gps;
///
///   @override
///   Stream<void> execute(reader, writer, cancel) =>
///       _gps.positions.map((pos) => writer.commit(reader.current.copyWith(position: pos)));
/// }
///
/// store.dispatchStream(LocationStreamCommand(_gps));
/// store.cancelStream<LocationStreamCommand>();
/// ```
abstract interface class const StreamCommand<S>() {
  Stream<void> execute(
    StateReader<S> reader,
    StateWriter<S> writer,
    CancelToken cancel,
  );
}
