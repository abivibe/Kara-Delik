class TikTokSlideshow {
  final List<String> images;
  final String? audioUrl;
  TikTokSlideshow(this.images, this.audioUrl);

  static TikTokSlideshow? fromApi(Map data) {
    final raw = data['images'];
    if (raw is! List || raw.isEmpty) return null;
    final images = raw.whereType<String>().where((s) => Uri.tryParse(s)?.hasAbsolutePath == true && s.startsWith('http')).toList();
    if (images.length != raw.length) throw Exception('TikTok fotoğrafları alınamadı.');
    final audio = data['music'];
    return TikTokSlideshow(images, audio is String && audio.isNotEmpty ? audio : null);
  }
}
