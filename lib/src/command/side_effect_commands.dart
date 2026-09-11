import '../internal/cancel_token.dart';
import '../internal/state_access.dart';

/// (новое состояние, опциональный эффект) — атомарный результат sync-команды
/// с эффектом. `effect == null` — эффект не эмитируется.
typedef SyncSideEffectResult<S, E> = (S next, E? effect);

/// Синхронная команда с атомарным возвратом нового состояния и side-эффекта.
///
/// Должна быть чистой функцией.
///
/// ```dart
/// final class IncrementCommand implements SyncSideEffect<CounterState, CounterEffect> {
///   const IncrementCommand({required this.limit});
///   final int limit;
///
///   @override
///   SyncSideEffectResult<CounterState, CounterEffect> execute(CounterState current) {
///     final next = current.copyWith(count: current.count + 1);
///     return (next, next.count >= limit ? const LimitReached() : null);
///   }
/// }
/// ```
abstract interface class const SyncSideEffect<S, E>() {
  SyncSideEffectResult<S, E> execute(S current);
}

/// Единичное асинхронное действие с возвратом side-эффекта.
///
/// Проверяй `CancelToken.isCancelled` перед каждым `StateWriter.commit`.
///
/// ```dart
/// final class LoginCommand implements AsyncSideEffect<UserState, UserEffect> {
///   const LoginCommand(this._api, this.credentials);
///   final AuthApi _api;
///   final Credentials credentials;
///
///   @override
///   Future<UserEffect?> execute(reader, writer, cancel) async {
///     try {
///       final user = await _api.login(credentials);
///       if (cancel.isCancelled) return null;
///       writer.commit(reader.current.copyWith(user: user));
///       return const NavigateToHome();
///     } catch (e) {
///       if (cancel.isCancelled) return null;
///       return ShowError(e.toString());
///     }
///   }
/// }
/// ```
abstract interface class const AsyncSideEffect<S, E>() {
  Future<E?> execute(
    StateReader<S> reader,
    StateWriter<S> writer,
    CancelToken cancel,
  );
}

/// Stream-команда, каждая итерация которой может обновить состояние и/или
/// эмитировать side-эффект. `null` из итерации — эффекта нет.
///
/// ```dart
/// final class ChatStreamCommand implements StreamSideEffect<ChatState, ChatEffect> {
///   const ChatStreamCommand(this._socket);
///   final ChatSocket _socket;
///
///   @override
///   Stream<ChatEffect?> execute(reader, writer, cancel) => _socket.messages.map((msg) {
///         writer.commit(reader.current.copyWith(messages: [...reader.current.messages, msg]));
///         return msg.isSystem ? null : MessageReceived(msg);
///       });
/// }
/// ```
abstract interface class const StreamSideEffect<S, E>() {
  Stream<E?> execute(
    StateReader<S> reader,
    StateWriter<S> writer,
    CancelToken cancel,
  );
}
