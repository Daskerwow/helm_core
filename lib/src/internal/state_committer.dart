import 'cancel_token.dart';
import 'emitting_writer.dart';
import 'guarded_writer.dart';
import 'state_access.dart';
import 'store_event_bus.dart';

/// Собирает writer-ы и публикует изменения состояния в одном месте.
///
/// Это единственная точка, знающая как совместить хранилище, компаратор и
/// Observer-канал Store. Dispatch-стратегии отвечают только за свой lifecycle.
final class const StateCommitter<S, E>({
  required final StateAccessor<S> _accessor,
  required final StoreEventBus<S, E> _events,
  required final bool Function(S, S) _equals,
  final void Function(String commandLabel, S nextState)? onDroppedCommit,
}) {
  EmittingWriter<S> emittingWriter() =>
      EmittingWriter<S>(_accessor, _events.notifyChange, _equals);

  GuardedWriter<S> guardedWriter(CancelToken token, String label) =>
      GuardedWriter<S>(
        emittingWriter(),
        token,
        label,
        onDroppedCommit: onDroppedCommit,
      );

  bool isUnchanged(S current, S before) => _equals(current, before);

  void publishIfChanged(S before, {required bool isActive}) {
    if (!isActive || isUnchanged(_accessor.current, before)) return;
    _events.notifyChange(_accessor.current);
  }
}
