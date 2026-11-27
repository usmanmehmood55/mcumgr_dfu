import 'dart:typed_data';

/// The state and identity of the underlying connection.
class SmpConnection {
  const SmpConnection({required this.isConnected, required this.generation});

  final bool isConnected;

  /// Changes whenever a new physical connection replaces the previous one.
  final int generation;
}

/// An ordered byte transport for SMP over an already connected device.
///
/// A client listens to [notifications] and [connectionUpdates] before [open].
/// The client owns framing and fragmentation. Implementations must preserve
/// write order and must deliver notification bytes without additional framing.
abstract interface class SmpTransport {
  SmpConnection get connection;
  Stream<SmpConnection> get connectionUpdates;
  Stream<Uint8List> get notifications;
  int get maximumWriteSize;

  /// Prepares the current connection for SMP and enables notifications.
  Future<void> open();

  /// Writes one fragment, using transport backpressure as appropriate.
  Future<void> write(Uint8List fragment);

  /// Releases SMP resources on the current connection.
  Future<void> close();

  /// Retires the physical connection after a potentially incomplete request.
  Future<void> disconnect();
}
