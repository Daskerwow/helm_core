import '../dispatch.dart';

/// Единые правила идентификации и именования команд для всех dispatch-paths.
final class DispatchMetadata {
  const DispatchMetadata._();

  static Object keyOf(Object command) =>
      command is DispatchKeyed ? command.dispatchKey : command.runtimeType;

  static String labelOf(Object command) => command is DispatchLabeled
      ? command.dispatchLabel
      : command.runtimeType.toString();
}
