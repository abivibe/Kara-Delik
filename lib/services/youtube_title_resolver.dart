/// Tries each independent metadata source until one supplies a title.
Future<String?> resolveYouTubeTitle(
    Iterable<Future<String?> Function()> sources) async {
  for (final source in sources) {
    try {
      final title = (await source())?.trim();
      if (title != null && title.isNotEmpty) return title;
    } catch (_) {
      // Try the next metadata source.
    }
  }
  return null;
}
