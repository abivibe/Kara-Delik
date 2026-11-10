import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:karadelik/services/clipboard_prompt_controller.dart';

class FakePrompt implements ClipboardPromptHandle {
  final Completer<int> result = Completer<int>();
  bool closed = false;
  @override
  Future<int> get exitCode => result.future;
  @override
  void close() { closed = true; if (!result.isCompleted) result.complete(0); }
}

void main() {
  test('replaces the active prompt and ignores its stale response', () async {
    final prompts = <String, FakePrompt>{};
    final responses = <String>[];
    final controller = ClipboardPromptController(
      start: (url) async => prompts[url] = FakePrompt(),
      onResponse: (url, code) => responses.add('$url:$code'),
    );
    controller.show('old');
    await Future<void>.delayed(Duration.zero);
    controller.show('new');
    await Future<void>.delayed(Duration.zero);
    expect(prompts['old']!.closed, isTrue);
    prompts['new']!.result.complete(101);
    await Future<void>.delayed(Duration.zero);
    expect(responses, ['new:101']);
    controller.dispose();
  });

  test('a late-starting old prompt is closed without taking over', () async {
    final old = Completer<ClipboardPromptHandle>();
    final oldPrompt = FakePrompt();
    final newPrompt = FakePrompt();
    final responses = <String>[];
    final controller = ClipboardPromptController(
      start: (url) => url == 'old' ? old.future : Future.value(newPrompt),
      onResponse: (url, code) => responses.add('$url:$code'),
    );
    controller.show('old');
    controller.show('new');
    await Future<void>.delayed(Duration.zero);
    old.complete(oldPrompt);
    await Future<void>.delayed(Duration.zero);
    expect(oldPrompt.closed, isTrue);
    expect(newPrompt.closed, isFalse);
    newPrompt.result.complete(102);
    await Future<void>.delayed(Duration.zero);
    expect(responses, ['new:102']);
    controller.dispose();
  });
}
