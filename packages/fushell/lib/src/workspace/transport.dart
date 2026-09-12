import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'protocol.dart';

/// A Wayland transport/protocol failure exposed by the workspace API.
class WorkspaceException implements Exception {
  const WorkspaceException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'WorkspaceException($code): $message';
}

class WireObject {
  WireObject(this.id, this.interface, this.version);
  final int id;
  final WireInterface interface;
  final int version;
  bool isRetired = false;
}

class _WriteBarrier {
  _WriteBarrier(this.serial);
  final int serial;
  final Completer<void> done = Completer<void>();
}

/// Bounded, asynchronous Wayland transport. This subset never carries FDs.
class WorkspaceTransport {
  WorkspaceTransport(this.socket, this.onEvent, this.onClosed) {
    objects[1] = WireObject(1, wireInterfaces['wl_display']!, 1);
    _subscription = socket.listen(
      _receive,
      onError: (Object error) {
        fail(WorkspaceException('Disconnected', '$error'));
      },
      onDone: () {
        fail(
          WorkspaceException(
            _buffer.isEmpty ? 'Disconnected' : 'MalformedMessage',
            _buffer.isEmpty
                ? 'The compositor disconnected.'
                : 'Truncated Wayland message at EOF.',
          ),
        );
      },
    );
  }

  final Socket socket;
  final void Function(WireObject object, WireMessage event, List<Object?> args)
  onEvent;
  final void Function(WorkspaceException? error) onClosed;
  final Map<int, WireObject> objects = {};
  final Set<int> _retired = {};
  final List<Uint8List> _outgoing = [];
  final List<_WriteBarrier> _barriers = [];
  Completer<void>? _activeWrite;
  int _queuedBytes = 0;
  int _queuedFrames = 0;
  int _enqueuedSerial = 0;
  int _flushedSerial = 0;
  bool _pumping = false;
  late final StreamSubscription<Uint8List> _subscription;
  Uint8List _buffer = Uint8List(0);
  int _nextId = 2;
  bool isClosed = false;
  static const int maxBufferedBytes = 1024 * 1024;
  static const int maxQueuedBytes = 1024 * 1024;
  static const int maxQueuedFrames = 4096;
  static const int maxPendingFlushes = 4096;

  int allocate(String interfaceName, int version) {
    if (isClosed) {
      throw const WorkspaceException('Disconnected', 'Connection closed.');
    }
    if (_nextId >= 0xff000000) {
      throw const WorkspaceException(
        'ProtocolError',
        'Client object IDs exhausted.',
      );
    }
    final id = _nextId++;
    objects[id] = WireObject(id, wireInterfaces[interfaceName]!, version);
    return id;
  }

  void retire(int id) {
    if (id < 0xff000000) {
      // The compositor may already have queued events for a destroyed object.
      // Preserve its type until delete_id establishes the end of that lifetime.
      final object = objects[id];
      if (object != null) {
        object.isRetired = true;
      }
      _retired.add(id);
    } else {
      objects.remove(id);
    }
  }

  void _receive(Uint8List chunk) {
    if (isClosed) {
      return;
    }
    try {
      if (_buffer.length + chunk.length > maxBufferedBytes) {
        throw const WorkspaceException(
          'MalformedMessage',
          'Incoming buffer exceeds limit.',
        );
      }
      final data = Uint8List(_buffer.length + chunk.length)
        ..setAll(0, _buffer)
        ..setAll(_buffer.length, chunk);
      var offset = 0;
      while (data.length - offset >= 8 && !isClosed) {
        final header = ByteData.sublistView(data, offset, offset + 8);
        final id = header.getUint32(0, Endian.host);
        final word = header.getUint32(4, Endian.host);
        final size = word >> 16;
        final opcode = word & 0xffff;
        if (size < 8 || size % 4 != 0) {
          throw const WorkspaceException(
            'MalformedMessage',
            'Invalid Wayland message size/alignment.',
          );
        }
        if (data.length - offset < size) {
          break;
        }
        final object = objects[id];
        if (object == null || opcode >= object.interface.events.length) {
          throw const WorkspaceException(
            'MalformedMessage',
            'Unknown event object or opcode.',
          );
        }
        final event = object.interface.events[opcode];
        if (event.since > object.version) {
          throw const WorkspaceException(
            'MalformedMessage',
            'Event exceeds negotiated version.',
          );
        }
        final args = decodeArguments(
          event,
          Uint8List.sublistView(data, offset + 8, offset + size),
        );
        if (id == 1 && event.name == 'error') {
          final failure = WlDisplayErrorEvent.fromList(args);
          throw WorkspaceException(
            'ProtocolError',
            'Compositor error ${failure.code} on object ${failure.objectId}: ${failure.message}',
          );
        }
        for (var i = 0; i < event.args.length; i++) {
          final arg = event.args[i];
          if (arg.type == 'new_id') {
            final child = args[i] as int;
            if (child < 0xff000000 ||
                objects.containsKey(child) ||
                arg.interfaceName == null) {
              throw const WorkspaceException(
                'MalformedMessage',
                'Invalid or duplicate server object ID.',
              );
            }
            final schema = wireInterfaces[arg.interfaceName]!;
            objects[child] = WireObject(
              child,
              schema,
              object.version < schema.version ? object.version : schema.version,
            );
          } else if (arg.type == 'object' && args[i] != null) {
            final target = objects[args[i]];
            if (target == null ||
                (arg.interfaceName != null &&
                    target.interface.name != arg.interfaceName)) {
              throw const WorkspaceException(
                'MalformedMessage',
                'Invalid object reference.',
              );
            }
          }
        }
        if (id == 1 && event.name == 'delete_id') {
          final deleted = WlDisplayDeleteIdEvent.fromList(args).id;
          if (!_retired.remove(deleted)) {
            throw const WorkspaceException(
              'MalformedMessage',
              'Unexpected delete_id.',
            );
          }
          objects.remove(deleted);
        } else if (!object.isRetired) {
          onEvent(object, event, args);
        }
        if (event.destructor) {
          retire(id);
        }
        offset += size;
      }
      _buffer = Uint8List.fromList(data.sublist(offset));
    } catch (error) {
      fail(
        error is WorkspaceException
            ? error
            : WorkspaceException('MalformedMessage', '$error'),
      );
    }
  }

  void send(int objectId, String requestName, [List<Object?> args = const []]) {
    if (isClosed) {
      throw const WorkspaceException('Disconnected', 'Connection closed.');
    }
    final object = objects[objectId];
    if (object == null || object.isRetired) {
      throw const WorkspaceException(
        'StaleWorkspace',
        'Object no longer exists.',
      );
    }
    final request = object.interface.requests.firstWhere(
      (r) => r.name == requestName,
    );
    if (request.since > object.version) {
      throw const WorkspaceException(
        'UnsupportedOperation',
        'Request exceeds negotiated version.',
      );
    }
    final frame = encodeMessage(objectId, request, args);
    if (_queuedBytes + frame.length > maxQueuedBytes ||
        _queuedFrames >= maxQueuedFrames) {
      const error = WorkspaceException(
        'Disconnected',
        'Outgoing Wayland queue limit exceeded.',
      );
      fail(error);
      throw error;
    }
    _outgoing.add(frame);
    _queuedBytes += frame.length;
    _queuedFrames++;
    _enqueuedSerial++;
    _scheduleWrite();
    if (request.destructor) {
      retire(objectId);
    }
  }

  /// Complete after every frame queued before this call has been flushed.
  Future<void> flush() async {
    if (isClosed) {
      throw const WorkspaceException('Disconnected', 'Connection closed.');
    }
    if (_flushedSerial >= _enqueuedSerial) {
      return;
    }
    if (_barriers.length >= maxPendingFlushes) {
      const error = WorkspaceException(
        'Disconnected',
        'Outgoing flush barrier limit exceeded.',
      );
      fail(error);
      throw error;
    }
    final barrier = _WriteBarrier(_enqueuedSerial);
    _barriers.add(barrier);
    _scheduleWrite();
    await barrier.done.future;
  }

  void _scheduleWrite() {
    if (_pumping || isClosed) {
      return;
    }
    _pumping = true;
    // Batch synchronous request/commit pairs before starting socket.flush().
    scheduleMicrotask(() => unawaited(_pumpWrites()));
  }

  Future<void> _pumpWrites() async {
    try {
      while (!isClosed && _outgoing.isNotEmpty) {
        final batch = List<Uint8List>.of(_outgoing);
        _outgoing.clear();
        final serial = _enqueuedSerial;
        var bytes = 0;
        // This is the only socket writer. No add occurs while flush is bound.
        for (final frame in batch) {
          socket.add(frame);
          bytes += frame.length;
        }
        final activeWrite = Completer<void>();
        _activeWrite = activeWrite;
        unawaited(
          socket.flush().then<void>(
            (_) {
              if (!activeWrite.isCompleted) {
                activeWrite.complete();
              }
            },
            onError: (Object error, StackTrace stack) {
              if (!activeWrite.isCompleted) {
                activeWrite.completeError(error, stack);
              }
            },
          ),
        );
        await activeWrite.future;
        _activeWrite = null;
        if (isClosed) {
          return;
        }
        _queuedBytes -= bytes;
        _queuedFrames -= batch.length;
        _flushedSerial = serial;
        _barriers.removeWhere((barrier) {
          if (barrier.serial > serial) {
            return false;
          }
          barrier.done.complete();
          return true;
        });
      }
    } catch (error) {
      fail(WorkspaceException('Disconnected', '$error'));
    } finally {
      _activeWrite = null;
      _pumping = false;
      if (!isClosed && _outgoing.isNotEmpty) {
        _scheduleWrite();
      }
    }
  }

  void fail(WorkspaceException? error) {
    if (isClosed) {
      return;
    }
    isClosed = true;
    socket.destroy();
    unawaited(_subscription.cancel());
    _outgoing.clear();
    _queuedBytes = 0;
    _queuedFrames = 0;
    final activeWrite = _activeWrite;
    if (activeWrite != null && !activeWrite.isCompleted) {
      activeWrite.complete();
    }
    for (final barrier in _barriers) {
      if (!barrier.done.isCompleted) {
        barrier.done.completeError(
          error ??
              const WorkspaceException(
                'Disconnected',
                'Connection closed while sending.',
              ),
        );
      }
    }
    _barriers.clear();
    onClosed(error);
  }

  Future<void> close() async {
    fail(null);
  }
}

Uint8List encodeMessage(int id, WireMessage message, List<Object?> values) {
  if (values.length != message.args.length) {
    throw ArgumentError('Wrong argument count for ${message.name}');
  }
  final builder = BytesBuilder(copy: false);
  void uint(int value) {
    if (value < 0 || value > 0xffffffff) {
      throw ArgumentError.value(value, 'uint32');
    }
    builder.add(
      (ByteData(4)..setUint32(0, value, Endian.host)).buffer.asUint8List(),
    );
  }

  for (var i = 0; i < values.length; i++) {
    final arg = message.args[i];
    final value = values[i];
    switch (arg.type) {
      case 'uint':
      case 'object':
      case 'new_id':
        if (value == null && !arg.nullable) {
          throw ArgumentError('Non-nullable ${arg.name}');
        }
        uint((value as int?) ?? 0);
      case 'int':
      case 'fixed':
        builder.add(
          (ByteData(
            4,
          )..setInt32(0, value as int, Endian.host)).buffer.asUint8List(),
        );
      case 'string':
        if (value == null) {
          if (!arg.nullable) {
            throw ArgumentError('Non-nullable string');
          }
          uint(0);
        } else {
          final string = value as String;
          if (string.contains('\u0000')) {
            throw ArgumentError('Wayland strings cannot contain NUL.');
          }
          final bytes = utf8.encode(string);
          uint(bytes.length + 1);
          builder.add(bytes);
          builder.add(Uint8List(4 - bytes.length % 4));
        }
      case 'array':
        final bytes = value as List<int>;
        uint(bytes.length);
        builder.add(bytes);
        builder.add(Uint8List((4 - bytes.length % 4) % 4));
      default:
        throw UnsupportedError('Unsupported wire argument: ${arg.type}');
    }
  }
  final body = builder.takeBytes();
  if (body.length + 8 > 0xffff) {
    throw ArgumentError('Wayland message exceeds 65535 bytes.');
  }
  final result = Uint8List(body.length + 8);
  ByteData.sublistView(result)
    ..setUint32(0, id, Endian.host)
    ..setUint32(4, ((body.length + 8) << 16) | message.opcode, Endian.host);
  result.setAll(8, body);
  return result;
}

List<Object?> decodeArguments(WireMessage message, Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var cursor = 0;
  void need(int length) {
    if (length < 0 || cursor + length > bytes.length) {
      throw const FormatException('Truncated argument');
    }
  }

  int uint() {
    need(4);
    final result = data.getUint32(cursor, Endian.host);
    cursor += 4;
    return result;
  }

  final result = <Object?>[];
  for (final arg in message.args) {
    switch (arg.type) {
      case 'uint':
      case 'new_id':
        result.add(uint());
      case 'object':
        final id = uint();
        if (id == 0 && !arg.nullable) {
          throw const FormatException('Null object');
        }
        result.add(id == 0 ? null : id);
      case 'int':
      case 'fixed':
        need(4);
        result.add(data.getInt32(cursor, Endian.host));
        cursor += 4;
      case 'string':
      case 'array':
        final length = uint();
        final padded = (length + 3) & ~3;
        need(padded);
        if (arg.type == 'string') {
          if (length == 0) {
            if (!arg.nullable) {
              throw const FormatException('Null string');
            }
            result.add(null);
          } else {
            if (bytes[cursor + length - 1] != 0) {
              throw const FormatException('Unterminated string');
            }
            final text = utf8.decode(
              bytes.sublist(cursor, cursor + length - 1),
            );
            if (text.contains('\u0000')) {
              throw const FormatException('Embedded NUL');
            }
            result.add(text);
          }
        } else {
          result.add(
            Uint8List.fromList(bytes.sublist(cursor, cursor + length)),
          );
        }
        cursor += padded;
      default:
        throw UnsupportedError(
          'FD/unknown argument excluded from workspace runtime.',
        );
    }
  }
  if (cursor != bytes.length) {
    throw const FormatException('Trailing event payload');
  }
  return result;
}
