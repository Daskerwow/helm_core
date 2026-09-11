import 'dispatch.dart';

/// Именованный, переиспользуемый наблюдатель диспатчей — альтернатива
/// анонимному колбэку в `StateStore.addDispatchListener` для
/// кросс-катаных забот (логирование, аналитика, персистентность,
/// DevTools-мост), которые естественно оформить отдельным классом, а не
/// замыканием на месте вызова.
///
/// Технически [StoreMiddleware] не расширяет возможности `StateStore` —
/// [DispatchEvent] уже несёт всё, что нужно для наблюдения "после факта"
/// (см. `StateStore.addDispatchListener`), и Helm намеренно не даёт
/// middleware перехватывать/подменять команду или её результат *до*
/// выполнения (это ломало бы гарантию "любой коммит публикуется синхронно
/// и без исключений на пути между командой и подписчиками состояния" —
/// см. докстринг `StateStore`, раздел "Согласованность"). Ценность
/// [StoreMiddleware] — в форме: у объекта есть имя типа, жизненный цикл
/// (можно хранить список активных middleware в DI-контейнере, включать и
/// выключать целиком по фиче-флагу), и его проще тестировать в изоляции,
/// чем безымянное замыкание.
///
/// ```dart
/// final class AnalyticsMiddleware implements StoreMiddleware<AppState> {
///   const AnalyticsMiddleware(this._analytics);
///   final Analytics _analytics;
///
///   @override
///   void onDispatch(DispatchEvent<AppState> event) {
///     if (event.isSuccess) _analytics.track(event.commandLabel);
///   }
/// }
///
/// final unsubscribe = store.addMiddleware(AnalyticsMiddleware(analytics));
/// // ...
/// unsubscribe();
/// ```
///
/// См. `StateStore.addMiddleware` — тонкая обёртка поверх
/// `StateStore.addDispatchListener`, дающая этому контракту точку входа.
abstract interface class const StoreMiddleware<S>() {
  /// Вызывается после каждого диспатча — при успехе, ошибке и отмене, для
  /// sync/async/stream-команд одинаково. Не должен бросать исключения:
  /// `StateStore` изолирует ошибки между независимыми
  /// `addDispatchListener`-слушателями (см. `CallbackList.notify`), но
  /// упавший middleware всё равно не выполнит свою работу для текущего
  /// события — оборачивай рискованные операции (например, сетевой вызов
  /// аналитики) в собственный try/catch внутри [onDispatch].
  void onDispatch(DispatchEvent<S> event);
}
