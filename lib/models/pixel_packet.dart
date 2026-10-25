import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';

class PixelProtocol {
  static const List<int> magicV1 = [0x50, 0x58, 0x4C, 0x31]; // 'PXL1' (Monochrome Data)
  static const List<int> magicV2 = [0x50, 0x44, 0x30, 0x32]; // 'PD02' (RGB 8-Color Data)
  static const List<int> magicFecV1 = [0x50, 0x58, 0x46, 0x31]; // 'PXF1' (Monochrome FEC)
  static const List<int> magicFecV2 = [0x50, 0x44, 0x46, 0x32]; // 'PDF2' (RGB 8-Color FEC)
  static const List<int> magic = magicV2; // Default current magic
  static const int headerLen = 16;

  /// Standard 8 RGB high-contrast corner colors (3 bits per color: R, G, B)
  static const List<List<int>> colorPalette = [
    [0, 0, 0], // 0: 000 Black
    [0, 0, 255], // 1: 001 Blue
    [0, 255, 0], // 2: 010 Green
    [0, 255, 255], // 3: 011 Cyan
    [255, 0, 0], // 4: 100 Red
    [255, 0, 255], // 5: 101 Magenta
    [255, 255, 0], // 6: 110 Yellow
    [255, 255, 255], // 7: 111 White
  ];

  /// Packs bits (0 or 1) into bytes (v1 monochrome).
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

  /// Unpacks bytes into bits (0 or 1) (v1 monochrome).
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

  /// Unpacks bytes into 3-bit RGB color dot values (0..7) where:
  /// bit 2 = R (>128), bit 1 = G (>128), bit 0 = B (>128).
  static Uint8List unpackBytesToColorDots(Uint8List bytes, int dotCount) {
    final dots = Uint8List(dotCount);
    int acc = 0;
    int bitsInAcc = 0;
    int byteIdx = 0;
    final totalBytes = bytes.length;

    for (int i = 0; i < dotCount; i++) {
      while (bitsInAcc < 3 && byteIdx < totalBytes) {
        acc = (acc << 8) | bytes[byteIdx++];
        bitsInAcc += 8;
      }
      if (bitsInAcc >= 3) {
        bitsInAcc -= 3;
        dots[i] = (acc >> bitsInAcc) & 0x07;
        acc &= (1 << bitsInAcc) - 1;
      } else if (bitsInAcc > 0) {
        dots[i] = (acc << (3 - bitsInAcc)) & 0x07;
        bitsInAcc = 0;
        acc = 0;
      } else {
        dots[i] = 0;
      }
    }
    return dots;
  }

  /// Packs 3-bit RGB color dot values (0..7) into bytes.
  static Uint8List packColorDotsToBytes(List<int> dots, int byteLength) {
    final out = Uint8List(byteLength);
    int acc = 0;
    int bitsInAcc = 0;
    int outIdx = 0;

    for (int i = 0; i < dots.length; i++) {
      acc = (acc << 3) | (dots[i] & 0x07);
      bitsInAcc += 3;
      while (bitsInAcc >= 8) {
        bitsInAcc -= 8;
        if (outIdx < byteLength) {
          out[outIdx++] = (acc >> bitsInAcc) & 0xFF;
        }
      }
      acc &= (1 << bitsInAcc) - 1;
    }
    if (bitsInAcc > 0 && outIdx < byteLength) {
      out[outIdx++] = (acc << (8 - bitsInAcc)) & 0xFF;
    }
    return out;
  }

  /// Builds a frame packet with 16-byte header:
  /// [Magic 4B][Total 2B][Idx 2B][PayloadLen 4B][CRC32 4B] + Payload + Padding
  static Uint8List buildFrame(
    int total,
    int idx,
    Uint8List chunk,
    int targetCapacity, {
    int version = 2,
  }) {
    final crc = getCrc32(chunk);
    final buffer = ByteData(targetCapacity);
    final selectedMagic = (version == 1) ? magicV1 : magicV2;

    // Magic (4 bytes)
    buffer.setUint8(0, selectedMagic[0]);
    buffer.setUint8(1, selectedMagic[1]);
    buffer.setUint8(2, selectedMagic[2]);
    buffer.setUint8(3, selectedMagic[3]);

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

  /// Builds an FEC recovery frame packet with 16-byte header:
  /// [Magic 4B][DataTotal 2B][FecIndex 2B][FecTotal 2B][LastChunkLen 2B][CRC32 4B] + ParityPayload
  static Uint8List buildFecFrame({
    required int dataTotal,
    required int fecIndex,
    required int fecTotal,
    required int lastChunkLen,
    required Uint8List parityChunk,
    required int targetCapacity,
    int version = 2,
  }) {
    final buffer = ByteData(targetCapacity);
    final selectedMagic = (version == 1) ? magicFecV1 : magicFecV2;

    // Magic (4 bytes)
    buffer.setUint8(0, selectedMagic[0]);
    buffer.setUint8(1, selectedMagic[1]);
    buffer.setUint8(2, selectedMagic[2]);
    buffer.setUint8(3, selectedMagic[3]);

    // dataTotal (2 bytes) & fecIndex (2 bytes)
    buffer.setUint16(4, dataTotal, Endian.big);
    buffer.setUint16(6, fecIndex, Endian.big);

    // fecTotal (2 bytes) & lastChunkLen (2 bytes)
    buffer.setUint16(8, fecTotal, Endian.big);
    buffer.setUint16(10, lastChunkLen, Endian.big);

    final outBytes = buffer.buffer.asUint8List();
    outBytes.setRange(headerLen, headerLen + parityChunk.length, parityChunk);

    final payloadSlice = Uint8List.sublistView(outBytes, headerLen, targetCapacity);
    final crc = getCrc32(payloadSlice);
    buffer.setUint32(12, crc, Endian.big);

    return outBytes;
  }

  /// Parses a frame packet and verifies CRC32.
  /// Supports both PD02/PDF2 (version 2 RGB 8-color) and PXL1/PXF1 (version 1 monochrome).
  static FrameParseResult? parseFrame(Uint8List frameRaw) {
    if (frameRaw.length < headerLen) return null;
    final bd = ByteData.sublistView(frameRaw);

    int version = 0;
    bool isFec = false;
    if (frameRaw[0] == magicV2[0] &&
        frameRaw[1] == magicV2[1] &&
        frameRaw[2] == magicV2[2] &&
        frameRaw[3] == magicV2[3]) {
      version = 2;
    } else if (frameRaw[0] == magicV1[0] &&
        frameRaw[1] == magicV1[1] &&
        frameRaw[2] == magicV1[2] &&
        frameRaw[3] == magicV1[3]) {
      version = 1;
    } else if (frameRaw[0] == magicFecV2[0] &&
        frameRaw[1] == magicFecV2[1] &&
        frameRaw[2] == magicFecV2[2] &&
        frameRaw[3] == magicFecV2[3]) {
      version = 2;
      isFec = true;
    } else if (frameRaw[0] == magicFecV1[0] &&
        frameRaw[1] == magicFecV1[1] &&
        frameRaw[2] == magicFecV1[2] &&
        frameRaw[3] == magicFecV1[3]) {
      version = 1;
      isFec = true;
    } else {
      return null;
    }

    if (!isFec) {
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
        version: version,
        isFec: false,
      );
    } else {
      final dataTotal = bd.getUint16(4, Endian.big);
      final fecIndex = bd.getUint16(6, Endian.big);
      final fecTotal = bd.getUint16(8, Endian.big);
      final lastChunkLen = bd.getUint16(10, Endian.big);
      final expectedCrc = bd.getUint32(12, Endian.big);

      final payloadLen = frameRaw.length - headerLen;
      final payload = Uint8List.sublistView(frameRaw, headerLen, headerLen + payloadLen);
      final actualCrc = getCrc32(payload);

      if (actualCrc != expectedCrc) {
        return null; // CRC mismatch
      }

      return FrameParseResult(
        totalChunks: dataTotal,
        chunkIndex: fecIndex,
        payload: Uint8List.fromList(payload),
        version: version,
        isFec: true,
        fecIndex: fecIndex,
        fecTotal: fecTotal,
        lastChunkLen: lastChunkLen,
      );
    }
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
    if (stream.length < 2) {
      throw const FormatException('Stream length too short for metadata header');
    }
    final bd = ByteData.sublistView(stream);
    final fnameLen = bd.getUint16(0, Endian.big);
    final offset = 2 + fnameLen;
    // 2 (fnameLen) + fnameLen + 8 (origSize) + 64 (sha256Hex) + 1 (useGzip) = offset + 73
    final minHeaderLen = offset + 73;
    if (stream.length < minHeaderLen) {
      throw const FormatException('Truncated or invalid metadata header in stream');
    }

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
  final int version;
  final bool isFec;
  final int fecIndex;
  final int fecTotal;
  final int lastChunkLen;

  FrameParseResult({
    required this.totalChunks,
    required this.chunkIndex,
    required this.payload,
    this.version = 2,
    this.isFec = false,
    this.fecIndex = 0,
    this.fecTotal = 0,
    this.lastChunkLen = 0,
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
