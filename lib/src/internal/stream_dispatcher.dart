import 'dart:async';

import '../command/command.dart';
import '../dispatch.dart';
import 'cancel_token.dart';
import 'dispatch_metadata.dart';
import 'dispatch_registry.dart';
import 'state_access.dart';
import 'state_committer.dart';
import 'store_event_bus.dart';
import 'tracking_writer.dart';

/// Strategy для lifecycle Stream-команд; освобождает Store от деталей
/// подписки, отмены, логирования итераций и защиты writer.
final class const StreamDispatcher<S, E>({
  required final StateAccessor<S> _accessor,
  required final StoreEventBus<S, E> _events,
  required final DispatchRegistry _registry,
  required final StateCommitter<S, E> _committer,
  required final bool _logEvents,
  required final bool Function() _isClosed,
}) {
  void dispatch(StreamCommand<S> command) => _start(
    command,
    (writer, token) => command.execute(_accessor, writer, token),
  );

  void dispatchWithEffect(StreamSideEffect<S, E> command) => _start(
    command,
    (writer, token) => command.execute(_accessor, writer, token).map((effect) {
      if (effect != null) _events.notifyEffect(effect);
    }),
  );

  void cancel(Object key, CancelReason reason) {
    final label = _registry.cancelStream(key, reason);
    if (label == null) return;
    _events.notifyDispatch(
      _event(label, _accessor.current, cancelReason: reason),
    );
  }

  void cancelAll(CancelReason reason) {
    for (final key in _registry.activeStreamKeys) {
      cancel(key, reason);
    }
  }

  void _start(
    Object command,
    Stream<void> Function(TrackingWriter<S>, CancelToken) execute,
  ) {
    if (_isClosed()) return;
    final key = DispatchMetadata.keyOf(command);
    cancel(key, CancelReason.superseded);
    final label = DispatchMetadata.labelOf(command);
    final token = CancelToken();
    final writer = TrackingWriter<S>(
      _committer.guardedWriter(token, label),
      _accessor,
    );
    try {
      _subscribe(key, label, execute(writer, token), writer, token);
    } catch (error, stackTrace) {
      token.cancel(CancelReason.commandFailed);
      _reportError(label, error, stackTrace);
    }
  }

  void _subscribe(
    Object key,
    String label,
    Stream<void> stream,
    TrackingWriter<S> writer,
    CancelToken token,
  ) {
    if (writer.hasChanged) _logCycle(label, writer);
    late final StreamSubscription<void> subscription;
    subscription = stream.listen(
      (_) {
        if (writer.hasChanged) _logCycle(label, writer);
      },
      onError: (Object error, StackTrace stackTrace) =>
          _reportError(label, error, stackTrace),
      onDone: () => _registry.releaseStream(key, subscription),
      cancelOnError: false,
    );
    _registry.registerStream(key, subscription, label, token);
  }

  void _logCycle(String label, TrackingWriter<S> writer) {
    final before = writer.before;
    writer.reset();
    if (!_logEvents || _committer.isUnchanged(_accessor.current, before)) {
      return;
    }
    _events.notifyDispatch(_event(label, before));
  }

  void _reportError(String label, Object error, StackTrace stackTrace) {
    _events.notifyError(error, stackTrace);
    _events.notifyDispatch(_event(label, _accessor.current, error: error));
  }

  DispatchEvent<S> _event(
    String label,
    S before, {
    Object? error,
    CancelReason? cancelReason,
  }) => DispatchEvent(
    commandLabel: label,
    before: before,
    after: _accessor.current,
    kind: DispatchKind.stream,
    error: error,
    cancelReason: cancelReason,
  );
}
