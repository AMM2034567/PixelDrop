import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';

class PixelProtocol {
  static const List<int> magic = [0x50, 0x58, 0x4C, 0x31]; // 'PXL1'
  static const int headerLen = 16;

  /// Packs bits (0 or 1) into bytes.
  static Uint8List packBits(List<int> bits) {
    final byteLen = (bits.length + 7) ~/ 8;
    final out = Uint8List(byteLen);
    for (int i = 0; i < bits.length; i++) {
      if (bits[i] == 1) {
        final byteIdx = i ~/ 8;
        final bitIdx = 7 - (i % 8);
        out[byteIdx] |= (1 << bitIdx);
      }
    }
    return out;
  }

  /// Unpacks bytes into bits (0 or 1).
  static List<int> unpackBits(Uint8List bytes) {
    final bits = List<int>.filled(bytes.length * 8, 0);
    for (int i = 0; i < bytes.length; i++) {
      final b = bytes[i];
      final offset = i * 8;
      for (int bit = 0; bit < 8; bit++) {
        bits[offset + (7 - bit)] = (b >> bit) & 1;
      }
    }
    return bits;
  }

  /// Builds a frame packet with 16-byte header:
  /// [Magic 4B][Total 2B][Idx 2B][PayloadLen 4B][CRC32 4B] + Payload + Padding
  static Uint8List buildFrame(int total, int idx, Uint8List chunk, int targetCapacity) {
    final crc = getCrc32(chunk);
    final buffer = ByteData(targetCapacity);
    
    // Magic (4 bytes)
    buffer.setUint8(0, magic[0]);
    buffer.setUint8(1, magic[1]);
    buffer.setUint8(2, magic[2]);
    buffer.setUint8(3, magic[3]);

    // Total chunks & idx
    buffer.setUint16(4, total, Endian.big);
    buffer.setUint16(6, idx, Endian.big);

    // Payload len & CRC32
    buffer.setUint32(8, chunk.length, Endian.big);
    buffer.setUint32(12, crc, Endian.big);

    final outBytes = buffer.buffer.asUint8List();
    outBytes.setRange(headerLen, headerLen + chunk.length, chunk);
    // Remaining bytes are zero-padded
    return outBytes;
  }

  /// Parses a frame packet and verifies CRC32.
  static FrameParseResult? parseFrame(Uint8List frameRaw) {
    if (frameRaw.length < headerLen) return null;
    final bd = ByteData.sublistView(frameRaw);

    // Check magic
    if (frameRaw[0] != magic[0] ||
        frameRaw[1] != magic[1] ||
        frameRaw[2] != magic[2] ||
        frameRaw[3] != magic[3]) {
      return null;
    }

    final total = bd.getUint16(4, Endian.big);
    final idx = bd.getUint16(6, Endian.big);
    final payloadLen = bd.getUint32(8, Endian.big);
    final expectedCrc = bd.getUint32(12, Endian.big);

    if (headerLen + payloadLen > frameRaw.length) return null;

    final payload = Uint8List.sublistView(frameRaw, headerLen, headerLen + payloadLen);
    final actualCrc = getCrc32(payload);

    if (actualCrc != expectedCrc) {
      return null; // CRC mismatch
    }

    return FrameParseResult(
      totalChunks: total,
      chunkIndex: idx,
      payload: Uint8List.fromList(payload),
    );
  }

  /// Builds file metadata header prepended to full stream.
  static Uint8List buildMetaHeader({
    required String filename,
    required int origSize,
    required String sha256Hex,
    required bool useGzip,
  }) {
    final fnameBytes = utf8.encode(filename);
    final shaBytes = ascii.encode(sha256Hex); // 64 bytes
    final totalLen = 2 + fnameBytes.length + 8 + 64 + 1;

    final buffer = ByteData(totalLen);
    buffer.setUint16(0, fnameBytes.length, Endian.big);
    
    final out = buffer.buffer.asUint8List();
    out.setRange(2, 2 + fnameBytes.length, fnameBytes);
    
    final offset = 2 + fnameBytes.length;
    buffer.setUint64(offset, origSize, Endian.big);
    out.setRange(offset + 8, offset + 8 + 64, shaBytes);
    out[offset + 72] = useGzip ? 1 : 0;

    return out;
  }

  /// Parses metadata header from reconstructed stream.
  static MetaHeaderResult parseMetaHeader(Uint8List stream) {
    if (stream.length < 75) {
      throw Exception('Invalid stream length for metadata header');
    }
    final bd = ByteData.sublistView(stream);
    final fnameLen = bd.getUint16(0, Endian.big);
    final offset = 2 + fnameLen;
    final filename = utf8.decode(stream.sublist(2, offset));

    final origSize = bd.getUint64(offset, Endian.big);
    final sha256Hex = ascii.decode(stream.sublist(offset + 8, offset + 72));
    final useGzip = stream[offset + 72] == 1;

    final payloadBody = Uint8List.sublistView(stream, offset + 73);

    return MetaHeaderResult(
      filename: filename,
      originalSize: origSize,
      sha256: sha256Hex,
      useGzip: useGzip,
      body: payloadBody,
    );
  }
}

class FrameParseResult {
  final int totalChunks;
  final int chunkIndex;
  final Uint8List payload;

  FrameParseResult({
    required this.totalChunks,
    required this.chunkIndex,
    required this.payload,
  });
}

class MetaHeaderResult {
  final String filename;
  final int originalSize;
  final String sha256;
  final bool useGzip;
  final Uint8List body;

  MetaHeaderResult({
    required this.filename,
    required this.originalSize,
    required this.sha256,
    required this.useGzip,
    required this.body,
  });
}
