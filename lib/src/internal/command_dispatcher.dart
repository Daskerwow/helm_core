import 'dart:async';

import '../dispatch.dart';
import 'cancel_token.dart';
import 'dispatch_metadata.dart';
import 'dispatch_registry.dart';
import 'state_access.dart';
import 'state_committer.dart';
import 'store_event_bus.dart';

typedef AsyncCommandBody<S, E> = Future<E?> Function(
  StateWriter<S> writer,
  CancelToken token,
);

typedef SyncCommandBody<S, E> = (S next, E? effect) Function();

/// Strategy выполнения одноразовых sync- и async-команд.
///
/// Не владеет Store и не принимает публичные команды: фасад преобразует их в
/// body, поэтому эта стратегия не зависит от конкретных command-интерфейсов.
final class CommandDispatcher<S, E> {
  CommandDispatcher({
    required this._accessor,
    required this._events,
    required this._registry,
    required this._committer,
    required this._isClosed,
  });

  final StateAccessor<S> _accessor;
  final StoreEventBus<S, E> _events;
  final DispatchRegistry _registry;
  final StateCommitter<S, E> _committer;
  final bool Function() _isClosed;

  Future<DispatchResult<S>> dispatchAsync(
    Object command,
    AsyncCommandBody<S, E> execute,
  ) {
    if (_isClosed()) {
      return Future.value(DispatchCancelled<S>(CancelReason.storeClosed));
    }

    final label = DispatchMetadata.labelOf(command);
    final key = DispatchMetadata.keyOf(command);
    return _runAsync(
      key,
      label,
      (token) => execute(_committer.guardedWriter(token, label), token),
    );
  }

  DispatchResult<S> dispatchSync(Object command, SyncCommandBody<S, E> run) {
    if (_isClosed()) return DispatchCancelled<S>(CancelReason.storeClosed);

    final label = DispatchMetadata.labelOf(command);
    final before = _accessor.current;
    try {
      final (next, effect) = run();
      _accessor.commit(next);
      _committer.publishIfChanged(before, isActive: !_isClosed());

      if (effect != null) _events.notifyEffect(effect);
      _events.notifyDispatch(_event(label, before, DispatchKind.sync));
      return DispatchSuccess(_accessor.current);
    } catch (error, stackTrace) {
      _events.notifyError(error, stackTrace);
      _events.notifyDispatch(
        _event(label, before, DispatchKind.sync, error: error),
      );
      return DispatchFailure(error, stackTrace);
    }
  }

  void resetForTesting(S state) {
    final before = _accessor.current;
    _accessor.commit(state);
    _committer.publishIfChanged(before, isActive: !_isClosed());
  }

  Future<DispatchResult<S>> _runAsync(
    Object key,
    String label,
    Future<E?> Function(CancelToken token) body,
  ) async {
    final token = _registry.acquireToken(key);
    final before = _accessor.current;
    final watch = _events.hasDispatchListeners ? (Stopwatch()..start()) : null;

    try {
      final effect = await body(token);
      watch?.stop();
      if (token.isCancelled) {
        _events.notifyDispatch(
          _event(
            label,
            before,
            DispatchKind.async,
            elapsed: watch?.elapsed,
            cancelReason: token.reason,
          ),
        );
        return DispatchCancelled(token.reason!);
      }

      if (effect != null) _events.notifyEffect(effect);
      _events.notifyDispatch(
        _event(label, before, DispatchKind.async, elapsed: watch?.elapsed),
      );
      return DispatchSuccess(_accessor.current);
    } catch (error, stackTrace) {
      watch?.stop();
      if (token.isCancelled) {
        _events.notifyDispatch(
          _event(
            label,
            before,
            DispatchKind.async,
            elapsed: watch?.elapsed,
            cancelReason: token.reason,
          ),
        );
        return DispatchCancelled(token.reason!);
      }

      _events.notifyError(error, stackTrace);
      _events.notifyDispatch(
        _event(
          label,
          before,
          DispatchKind.async,
          elapsed: watch?.elapsed,
          error: error,
        ),
      );
      return DispatchFailure(error, stackTrace);
    } finally {
      _registry.releaseToken(key, token);
    }
  }

  DispatchEvent<S> _event(
    String label,
    S before,
    DispatchKind kind, {
    Duration? elapsed,
    Object? error,
    CancelReason? cancelReason,
  }) => DispatchEvent<S>(
    commandLabel: label,
    before: before,
    after: _accessor.current,
    kind: kind,
    elapsed: elapsed,
    error: error,
    cancelReason: cancelReason,
  );
}
