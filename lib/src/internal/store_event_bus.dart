import 'dart:async';

import '../dispatch.dart';
import 'callback_list.dart';

/// Observer/Event Bus для одного [StateStore].
///
/// Хранит и публикует все каналы наблюдения Store, включая Stream-интероп и
/// закрытие подписчиков. Оркестрация команд, состояние и отмена намеренно
/// остаются в `StateStore`: этот класс знает только о доставке событий.
final class StoreEventBus<S, E> {
  final _changes = CallbackList<void Function(S state)>();
  final _effects = CallbackList<void Function(E effect)>();
  final _dispatches = CallbackList<void Function(DispatchEvent<S> event)>();
  final _errors =
      CallbackList<void Function(Object error, StackTrace stackTrace)>();

  Stream<S>? _states;
  Stream<E>? _effectsStream;
  final _stateControllers = <MultiStreamController<S>>{};
  final _effectControllers = <MultiStreamController<E>>{};
  bool _closed = false;
  bool _reportingError = false;

  bool get hasDispatchListeners => !_dispatches.isEmpty;

  void Function() onChange(void Function(S state) listener) {
    _changes.addListener(listener);
    return () => _changes.removeListener(listener);
  }

  void Function() onEffect(void Function(E effect) listener) {
    _effects.addListener(listener);
    return () => _effects.removeListener(listener);
  }

  void Function() onDispatch(void Function(DispatchEvent<S> event) listener) {
    _dispatches.addListener(listener);
    return () => _dispatches.removeListener(listener);
  }

  void Function() onError(
    void Function(Object error, StackTrace stackTrace) listener,
  ) {
    _errors.addListener(listener);
    return () => _errors.removeListener(listener);
  }

  Stream<S> states(S Function() currentState) =>
      _states ??= Stream<S>.multi((controller) {
        if (_closed) {
          controller.close();
          return;
        }

        controller.addSync(currentState());
        _stateControllers.add(controller);
        final unsubscribe = onChange(controller.addSync);
        controller.onCancel = () {
          unsubscribe();
          _stateControllers.remove(controller);
        };
      }, isBroadcast: true);

  Stream<E> get effects => _effectsStream ??= Stream<E>.multi((controller) {
    if (_closed) {
      controller.close();
      return;
    }

    _effectControllers.add(controller);
    final unsubscribe = onEffect(controller.addSync);
    controller.onCancel = () {
      unsubscribe();
      _effectControllers.remove(controller);
    };
  }, isBroadcast: true);

  void notifyChange(S state) => _changes.notifyListeners(
    (listener) => listener(state),
    onError: _reportListenerError,
  );

  void notifyEffect(E effect) => _effects.notifyListeners(
    (listener) => listener(effect),
    onError: _reportListenerError,
  );

  void notifyDispatch(DispatchEvent<S> event) => _dispatches.notifyListeners(
    (listener) => listener(event),
    onError: _reportListenerError,
  );

  void notifyError(Object error, StackTrace stackTrace) =>
      _errors.notifyListeners(
        (listener) => listener(error, stackTrace),
        onError: _reportListenerError,
      );

  void close() {
    if (_closed) return;
    _closed = true;
    _changes.clearListener();
    _effects.clearListener();
    _dispatches.clearListener();
    _errors.clearListener();

    for (final controller in _stateControllers.toList(growable: false)) {
      controller.close();
    }
    _stateControllers.clear();

    for (final controller in _effectControllers.toList(growable: false)) {
      controller.close();
    }
    _effectControllers.clear();
  }

  void _reportListenerError(Object error, StackTrace stackTrace) {
    if (_reportingError) {
      assert(() {
        print('Helm: error-listener threw an exception: $error');
        return true;
      }());
      return;
    }

    _reportingError = true;
    try {
      _errors.notifyListeners((listener) => listener(error, stackTrace));
    } catch (_) {
      // Некуда эскалировать ошибку обработчика ошибок.
    } finally {
      _reportingError = false;
    }
  }
}
