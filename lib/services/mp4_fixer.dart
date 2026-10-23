import 'dart:io';
import 'package:flutter/foundation.dart';

class Mp4Fixer {
  /// MP4 dosyasının başlığındaki duration bilgisini kontrol eder ve eksikse (0 ise) onarır.
  static Future<bool> fixDurationIfNeeded(
    String filePath, {
    Duration? expectedDuration,
  }) async {
    try {
      final file = File(filePath);
      if (!await file.exists()) return false;

      final length = await file.length();
      if (length < 64) return false;

      // Dosyayı oku
      final bytes = await file.readAsBytes();
      int offset = 0;
      int moovOffset = -1;
      int moovSize = 0;

      while (offset + 8 <= bytes.length) {
        final bd = ByteData.sublistView(bytes, offset, offset + 4);
        final size = bd.getUint32(0);
        final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));

        if (type == 'moov') {
          moovOffset = offset;
          moovSize = size;
          break;
        }

        if (size <= 0) break;
        offset += size;
      }

      if (moovOffset == -1) return false;

      final moovEnd = moovOffset + moovSize;
      if (moovEnd > bytes.length) return false;

      // mvhd bloğunu bul
      int subOffset = moovOffset + 8;
      int mvhdOffset = -1;
      int mvhdSize = 0;

      while (subOffset + 8 <= moovEnd) {
        final sbd = ByteData.sublistView(bytes, subOffset, subOffset + 4);
        final size = sbd.getUint32(0);
        final type = String.fromCharCodes(bytes.sublist(subOffset + 4, subOffset + 8));

        if (type == 'mvhd') {
          mvhdOffset = subOffset;
          mvhdSize = size;
          break;
        }

        if (size <= 0) break;
        subOffset += size;
      }

      if (mvhdOffset == -1) return false;

      final version = bytes[mvhdOffset + 8];
      final mvhdBd = ByteData.sublistView(bytes, mvhdOffset + 8, mvhdOffset + mvhdSize);

      int timescale;
      int currentDuration;
      int durFieldOffsetInMvhd;
      bool is64Bit = false;

      if (version == 1) {
        timescale = mvhdBd.getUint32(20);
        currentDuration = mvhdBd.getUint64(24);
        durFieldOffsetInMvhd = 24;
        is64Bit = true;
      } else {
        timescale = mvhdBd.getUint32(12);
        currentDuration = mvhdBd.getUint32(16);
        durFieldOffsetInMvhd = 16;
        is64Bit = false;
      }

      // Eğer duration zaten geçerli ise (0 değilse) dosyaya dokunma
      if (currentDuration > 0) {
        return true;
      }

      int targetSeconds = expectedDuration != null && expectedDuration.inSeconds > 0
          ? expectedDuration.inSeconds
          : 0;

      // Beklenen süre verilmediyse mfra veya fragmanlardan tahmin et
      if (targetSeconds <= 0) {
        targetSeconds = _estimateDurationFromMfra(bytes, timescale);
      }

      if (targetSeconds <= 0) return false;

      final targetDurValue = targetSeconds * (timescale > 0 ? timescale : 1000);

      // mvhd süresini güncelle
      if (is64Bit) {
        mvhdBd.setUint64(durFieldOffsetInMvhd, targetDurValue);
      } else {
        mvhdBd.setUint32(durFieldOffsetInMvhd, targetDurValue);
      }

      // trak -> tkhd bloklarını da güncelle
      _patchAllTkhd(bytes, moovOffset + 8, moovEnd, targetDurValue, is64Bit);

      // Dosyaya geri yaz
      await file.writeAsBytes(bytes);
      debugPrint('MP4 duration başarıyla onarıldı: $targetSeconds saniye');
      return true;
    } catch (e) {
      debugPrint('MP4 duration onarım hatası: $e');
      return false;
    }
  }

  static void _patchAllTkhd(
    Uint8List bytes,
    int moovStart,
    int moovEnd,
    int durationValue,
    bool is64Bit,
  ) {
    int offset = moovStart;
    while (offset + 8 <= moovEnd) {
      final size = ByteData.sublistView(bytes, offset, offset + 4).getUint32(0);
      final type = String.fromCharCodes(bytes.sublist(offset + 4, offset + 8));

      if (type == 'trak') {
        int trakSub = offset + 8;
        final trakEnd = offset + size;
        while (trakSub + 8 <= trakEnd && trakSub + 8 <= bytes.length) {
          final tSize = ByteData.sublistView(bytes, trakSub, trakSub + 4).getUint32(0);
          final tType = String.fromCharCodes(bytes.sublist(trakSub + 4, trakSub + 8));

          if (tType == 'tkhd') {
            final version = bytes[trakSub + 8];
            final tkhdBd = ByteData.sublistView(bytes, trakSub + 8, trakSub + tSize);
            if (version == 1) {
              tkhdBd.setUint64(24, durationValue);
            } else {
              tkhdBd.setUint32(16, durationValue);
            }
            break;
          }

          if (tSize <= 0) break;
          trakSub += tSize;
        }
      }

      if (size <= 0) break;
      offset += size;
    }
  }

  static int _estimateDurationFromMfra(Uint8List bytes, int timescale) {
    try {
      final fileLength = bytes.length;
      final start = fileLength > 2048 ? fileLength - 2048 : 0;
      for (int i = start; i < fileLength - 16; i++) {
        if (bytes[i] == 0x74 &&
            bytes[i + 1] == 0x66 &&
            bytes[i + 2] == 0x72 &&
            bytes[i + 3] == 0x61) {
          // tfra
          final bd = ByteData.sublistView(bytes, i - 4);
          final version = bytes[i + 4];
          if (version == 1 && i + 24 < fileLength) {
            final lastTime = bd.getUint64(20);
            if (lastTime > 0 && timescale > 0) {
              return (lastTime / timescale).ceil();
            }
          } else if (version == 0 && i + 20 < fileLength) {
            final lastTime = bd.getUint32(16);
            if (lastTime > 0 && timescale > 0) {
              return (lastTime / timescale).ceil();
            }
          }
        }
      }
    } catch (_) {}
    return 0;
  }
}
