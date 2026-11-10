import 'dart:io';

abstract class ClipboardPromptHandle {
  Future<int> get exitCode;
  void close();
}

class ProcessClipboardPrompt implements ClipboardPromptHandle {
  ProcessClipboardPrompt(this.process);
  final Process process;
  @override
  Future<int> get exitCode => process.exitCode;
  @override
  void close() => process.kill();
}

/// Only the most recently requested prompt may report a user action.
class ClipboardPromptController {
  ClipboardPromptController({required this.start, required this.onResponse, this.onError});
  final Future<ClipboardPromptHandle> Function(String url) start;
  final void Function(String url, int exitCode) onResponse;
  final void Function(Object error)? onError;
  ClipboardPromptHandle? _current;
  int _generation = 0;
  bool _disposed = false;

  Future<void> show(String url) async {
    if (_disposed) return;
    final generation = ++_generation;
    _current?.close();
    _current = null;
    ClipboardPromptHandle? prompt;
    try {
      prompt = await start(url);
      if (_disposed || generation != _generation) {
        prompt.close();
        return;
      }
      _current = prompt;
      final code = await prompt.exitCode;
      if (!_disposed && generation == _generation) {
        onResponse(url, code);
      }
    } catch (error) {
      if (!_disposed && generation == _generation) onError?.call(error);
    } finally {
      if (identical(_current, prompt)) _current = null;
    }
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _current?.close();
    _current = null;
  }
}
