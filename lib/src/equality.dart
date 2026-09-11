import 'package:collection/collection.dart';

/// Компаратор "не изменилось" по умолчанию — обычное `==`.
///
/// Обычная top-level generic-функция, а не фабрика `T Function() → closure`:
/// тир-офф `defaultEquals<T>` переиспользуется без аллокации нового
/// замыкания на каждый вызов конструктора `StateStore`/`EmittingWriter`/
/// `HelmComputed`.
bool defaultEquals<T>(T a, T b) => a == b;

/// Адаптер обычной функции-компаратора к `Equality<T>` из
/// `package:collection` — так `listEquals`/`mapEquals` могут принять
/// пользовательский `elementEquals`/`valueEquals`, оставаясь тонкой
/// обёрткой над `ListEquality`/`MapEquality`, а не собственной реализацией
/// обхода.
///
/// [hash] делегирует в `Object.hashCode` элемента, а не в переданный
/// компаратор — он не участвует в [equals]/[listEquals]/[mapEquals] (они
/// зовут `Equality.equals` напрямую, а не хешируют коллекцию целиком), и
/// корректный хэш для двух объектов, равных по кастомному [_equals], но не
/// по `==`, в общем случае построить нельзя без отдельной хэш-функции от
/// пользователя.
final class const _FunctionEquality<T>(final bool Function(T a, T b) _equals)
    implements Equality<T> {
  @override
  bool equals(T e1, T e2) => _equals(e1, e2);

  @override
  int hash(T e) => e.hashCode;

  @override
  bool isValidKey(Object? o) => true;
}

/// Поэлементное сравнение двух `List<T>` — без промежуточных `Set`/`Map`.
///
/// Нужен, когда `S` (или срез, выбранный `HelmSelector.selector`/
/// `HelmFeature.select`) — обычный `List`, который сам по себе сравнивается
/// по идентичности (`List` не переопределяет `==` содержательно). Без
/// такого компаратора `StateStore`/`HelmComputed`/`HelmSelector` считали бы
/// новый список с теми же элементами "другим состоянием" на каждый коммит
/// — лишние публикации и ребилды.
///
/// Реализация — тонкая обёртка над `ListEquality` из `package:collection`
/// (уже используется большинством Flutter-проектов транзитивно, поэтому не
/// добавляет новый след в дереве зависимостей): [listEquals] отвечает
/// только за null-safety и `identical`-быстрый путь, само поэлементное
/// сравнение — забота `package:collection`.
///
/// ```dart
/// StateStore<List<Todo>, Never>(
///   initialState: const [],
///   equals: listEquals,
/// );
/// ```
///
/// [elementEquals] — компаратор элементов, по умолчанию `==` (через
/// [defaultEquals]). Порядок элементов важен: `[1, 2] != [2, 1]`.
bool listEquals<T>(
  List<T>? a,
  List<T>? b, {
  bool Function(T a, T b)? elementEquals,
}) {
  final eq = elementEquals ?? defaultEquals;
  return ListEquality<T>(_FunctionEquality(eq)).equals(a, b);
}

/// Сравнение двух `Set<T>` по содержимому, без учёта порядка вставки —
/// тонкая обёртка над `SetEquality` из `package:collection`.
bool setEquals<T>(
  Set<T>? a,
  Set<T>? b, {
  bool Function(T a, T b)? elementEquals,
}) {
  final eq = elementEquals ?? defaultEquals;
  return SetEquality(_FunctionEquality(eq)).equals(a, b);
}

/// Сравнение двух `Map<K, V>` по содержимому — ключи и значения, без учёта
/// порядка вставки. Тонкая обёртка над `MapEquality` из `package:collection`.
///
/// [valueEquals] — компаратор значений, по умолчанию `==`. Ключи всегда
/// сравниваются через `==`/`hashCode` (`MapEquality` по умолчанию использует
/// `DefaultEquality` для `keys`).
bool mapEquals<K, V>(
  Map<K, V>? a,
  Map<K, V>? b, {
  bool Function(V a, V b)? valueEquals,
}) {
  final eq = valueEquals ?? defaultEquals;
  return MapEquality<K, V>(values: _FunctionEquality(eq)).equals(a, b);
}

/// Рекурсивное сравнение "как есть" для значений, которые могут оказаться
/// вложенными `List`/`Set`/`Map` (например, состояние, собранное из JSON).
///
/// Делегирует в `DeepCollectionEquality` из `package:collection` — она уже
/// умеет рекурсивно спускаться в `List`/`Set`/`Map`/`Iterable` и сравнивать
/// листья через `==`, включая смешанную вложенность (`List` внутри `Map`
/// внутри `List`), которую самодельный обход пришлось бы поддерживать
/// вручную.
///
/// Не заменяет предметно-специфичный `equals` в общем случае — если у `S`
/// есть содержательный `==` (data-класс, `@immutable` с полями-значениями),
/// он почти всегда быстрее и точнее, чем этот обобщённый обход. [deepEquals]
/// пригождается там, где содержательного `==` нет и заводить его ради
/// одного сравнения в `StateStore(equals: ...)` избыточно.
bool deepEquals<T>(T? a, T? b, {bool Function(T a, T b)? elementEquals}) {
  final eq = elementEquals ?? defaultEquals;
  return DeepCollectionEquality(_FunctionEquality<T>(eq)).equals(a, b);
}
