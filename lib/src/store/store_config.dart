import '../dispatch.dart';
import 'state_storage.dart';

/// Готовый набор хуков и хранилища для `StoreBuilder.withConfig` — удобно
/// для тестов, DI-контейнеров и переиспользования настроек между сборками.
///
/// ```dart
/// final config = StoreConfig<UserState, UserEffect>(
///   onChanged: (s) => ref.read(userProvider.notifier).state = s,
///   onError: (e, st) => Sentry.captureException(e, stackTrace: st),
///   onDispatch: (event) => logger.debug(event.toLogString()),
/// );
///
/// final store = StoreBuilder<UserState, UserEffect>(UserState.initial())
///     .withConfig(config)
///     .build();
/// ```
final class const StoreConfig<S, E>({
  /// Вызывается после каждого успешного обновления состояния.
  final void Function(S state)? onChanged,

  /// Вызывается после каждого эмитированного side-эффекта.
  final void Function(E effect)? onEffect,

  /// Вызывается при необработанном исключении внутри dispatch.
  final void Function(Object error, StackTrace stackTrace)? onError,

  /// Вызывается после каждого dispatch — при успехе, ошибке и отмене.
  final void Function(DispatchEvent<S> event)? onDispatch,

  /// Персистентное хранилище. Если `null` — [StateMemoryStorage].
  final StateStorage<S>? storage,

  /// См. `StateStore.new` — по умолчанию `true`. Выключи, если поток шлёт
  /// значения очень часто и отдельный `DispatchEvent` на каждую итерацию не
  /// нужен ни в логах, ни в DevTools.
  final bool logStreamEvents = true,

  /// Компаратор "состояние не изменилось" — по умолчанию `==`.
  final bool Function(S a, S b)? equals,

  /// Хук диагностики коммита, отброшенного `GuardedWriter` после отмены —
  /// см. `StateStore.new`, параметр `onDroppedCommit`.
  final void Function(String commandLabel, S nextState)? onDroppedCommit,
});
