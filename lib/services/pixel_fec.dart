import 'dart:math' as math;
import 'dart:typed_data';

/// Galois Field GF(2^8) arithmetic using generator polynomial 0x11d (x^8 + x^4 + x^3 + x^2 + 1).
class GaloisField256 {
  static final Uint8List expTable = Uint8List(512);
  static final Uint8List logTable = Uint8List(256);
  static bool _initialized = false;

  static void init() {
    if (_initialized) return;
    int x = 1;
    for (int i = 0; i < 255; i++) {
      expTable[i] = x;
      expTable[i + 255] = x;
      logTable[x] = i;
      x <<= 1;
      if ((x & 0x100) != 0) {
        x ^= 0x11d;
      }
    }
    logTable[0] = 0; // undefined mathematically, safe sentinel
    _initialized = true;
  }

  static int mul(int a, int b) {
    if (a == 0 || b == 0) return 0;
    return expTable[logTable[a] + logTable[b]];
  }

  static int div(int a, int b) {
    if (a == 0) return 0;
    if (b == 0) throw ArgumentError('Division by zero in GF(2^8)');
    return expTable[(logTable[a] - logTable[b] + 255) % 255];
  }

  static int inv(int a) {
    if (a == 0) throw ArgumentError('Inverse of zero in GF(2^8)');
    return expTable[255 - logTable[a]];
  }

  static int add(int a, int b) => a ^ b;
  static int sub(int a, int b) => a ^ b;

  /// Inverts an N x N matrix over GF(2^8) using Gauss-Jordan elimination.
  static List<Uint8List> invertMatrix(List<Uint8List> mat) {
    init();
    final n = mat.length;
    // Create augmented matrix [mat | I]
    final aug = List.generate(n, (i) {
      final row = Uint8List(2 * n);
      for (int j = 0; j < n; j++) {
        row[j] = mat[i][j];
      }
      row[n + i] = 1;
      return row;
    });

    for (int col = 0; col < n; col++) {
      // Find pivot
      int pivotRow = -1;
      for (int r = col; r < n; r++) {
        if (aug[r][col] != 0) {
          pivotRow = r;
          break;
        }
      }
      if (pivotRow == -1) {
        throw ArgumentError('Singular matrix in GF(2^8)');
      }

      // Swap
      if (pivotRow != col) {
        final tmp = aug[col];
        aug[col] = aug[pivotRow];
        aug[pivotRow] = tmp;
      }

      // Scale pivot row
      final pivotVal = aug[col][col];
      final pivotInv = inv(pivotVal);
      for (int c = col; c < 2 * n; c++) {
        aug[col][c] = mul(aug[col][c], pivotInv);
      }

      // Eliminate
      for (int r = 0; r < n; r++) {
        if (r != col) {
          final factor = aug[r][col];
          if (factor != 0) {
            for (int c = col; c < 2 * n; c++) {
              aug[r][c] ^= mul(factor, aug[col][c]);
            }
          }
        }
      }
    }

    return List.generate(n, (i) {
      final invRow = Uint8List(n);
      for (int j = 0; j < n; j++) {
        invRow[j] = aug[i][n + j];
      }
      return invRow;
    });
  }

  /// Creates an M x K Cauchy generator matrix:
  /// X = [128 .. 128+M-1], Y = [0 .. K-1].
  /// C[i][j] = 1 / ((128 + i) ^ j).
  static List<Uint8List> createCauchyMatrix(int m, int k) {
    init();
    if (m > 128 || k > 128) {
      throw ArgumentError('m ($m) and k ($k) must be <= 128 in GF(2^8)');
    }
    return List.generate(m, (i) {
      final row = Uint8List(k);
      final xi = 128 + i;
      for (int j = 0; j < k; j++) {
        final yj = j;
        final diff = xi ^ yj;
        row[j] = inv(diff);
      }
      return row;
    });
  }
}

/// Represents a single Forward Error Correction (FEC) recovery packet.
class FecPacket {
  final int groupIndex;
  final int fecIndexInGroup;
  final int fecTotalInGroup;
  final int dataTotalInGroup;
  final int startChunkIndex;
  final int lastChunkLen;
  final Uint8List payload;

  FecPacket({
    required this.groupIndex,
    required this.fecIndexInGroup,
    required this.fecTotalInGroup,
    required this.dataTotalInGroup,
    required this.startChunkIndex,
    required this.lastChunkLen,
    required this.payload,
  });

  /// Encodes groupIndex and fecIndexInGroup into a 16-bit identifier.
  int get packedFecId => (groupIndex << 8) | (fecIndexInGroup & 0xFF);

  /// Encodes totalGroups and fecTotalInGroup into a 16-bit identifier.
  static int packTotalInfo(int totalGroups, int fecTotalInGroup) =>
      (totalGroups << 8) | (fecTotalInGroup & 0xFF);
}

/// Frame-level Forward Error Correction (FEC) / Erasure Coding Service.
class PixelFec {
  static const int maxGroupDataChunks = 128;

  /// Calculates the number of parity chunks for a given data chunk count and redundancy percent.
  static int calculateParityCount(int dataCount, int redundancyPercent) {
    if (redundancyPercent <= 0 || dataCount <= 0) return 0;
    final count = (dataCount * redundancyPercent / 100.0).ceil();
    // At least 1 parity frame if redundancy is requested, capped at dataCount
    return count.clamp(1, dataCount);
  }

  /// Generates FEC recovery packets for the provided data chunks.
  static List<FecPacket> generateParityPackets({
    required List<Uint8List> dataChunks,
    required int redundancyPercent,
    required int chunkPayloadCapacity,
  }) {
    if (redundancyPercent <= 0 || dataChunks.isEmpty) {
      return [];
    }

    GaloisField256.init();
    final totalChunks = dataChunks.length;
    final totalGroups = (totalChunks + maxGroupDataChunks - 1) ~/ maxGroupDataChunks;
    final List<FecPacket> packets = [];

    for (int g = 0; g < totalGroups; g++) {
      final startIdx = g * maxGroupDataChunks;
      final endIdx = math.min(startIdx + maxGroupDataChunks, totalChunks);
      final groupChunks = dataChunks.sublist(startIdx, endIdx);
      final k = groupChunks.length;
      final m = calculateParityCount(k, redundancyPercent);
      if (m <= 0) continue;

      final lastChunkInGroup = groupChunks.last;
      final lastChunkLen = lastChunkInGroup.length;

      // Uniform buffers of size chunkPayloadCapacity
      final uniformData = List.generate(k, (i) {
        final src = groupChunks[i];
        if (src.length == chunkPayloadCapacity) {
          return src;
        }
        final padded = Uint8List(chunkPayloadCapacity);
        padded.setRange(0, src.length, src);
        return padded;
      });

      final cauchy = GaloisField256.createCauchyMatrix(m, k);
      final parityBuffers = List.generate(m, (_) => Uint8List(chunkPayloadCapacity));

      for (int p = 0; p < m; p++) {
        final pRow = cauchy[p];
        final pBuf = parityBuffers[p];
        for (int j = 0; j < k; j++) {
          final coeff = pRow[j];
          if (coeff == 0) continue;
          final dBuf = uniformData[j];
          for (int b = 0; b < chunkPayloadCapacity; b++) {
            pBuf[b] ^= GaloisField256.mul(coeff, dBuf[b]);
          }
        }

        packets.add(
          FecPacket(
            groupIndex: g,
            fecIndexInGroup: p,
            fecTotalInGroup: m,
            dataTotalInGroup: k,
            startChunkIndex: startIdx,
            lastChunkLen: (endIdx == totalChunks) ? lastChunkLen : chunkPayloadCapacity,
            payload: pBuf,
          ),
        );
      }
    }

    return packets;
  }

  /// Reconstructs missing data chunks using collected data and FEC packets.
  /// Throws an [Exception] if there are insufficient FEC packets to recover all missing frames.
  static Map<int, Uint8List> recoverMissingData({
    required int totalDataChunks,
    required Map<int, Uint8List> collectedDataChunks,
    required List<FecPacket> collectedFecPackets,
    required int chunkPayloadCapacity,
  }) {
    GaloisField256.init();
    final Map<int, Uint8List> result = Map.of(collectedDataChunks);

    // Group the chunks
    final totalGroups = (totalDataChunks + maxGroupDataChunks - 1) ~/ maxGroupDataChunks;

    for (int g = 0; g < totalGroups; g++) {
      final startIdx = g * maxGroupDataChunks;
      final endIdx = math.min(startIdx + maxGroupDataChunks, totalDataChunks);
      final k = endIdx - startIdx;

      final missingInGroup = <int>[];
      for (int i = 0; i < k; i++) {
        final globalIdx = startIdx + i;
        if (!result.containsKey(globalIdx)) {
          missingInGroup.add(i); // Local index in group
        }
      }

      if (missingInGroup.isEmpty) {
        continue; // Group is already 100% complete
      }

      // Find FEC packets for this group and deduplicate by fecIndexInGroup
      final uniqueFec = <int, FecPacket>{};
      for (final p in collectedFecPackets) {
        if (p.groupIndex == g && !uniqueFec.containsKey(p.fecIndexInGroup)) {
          uniqueFec[p.fecIndexInGroup] = p;
        }
      }
      final groupFec = uniqueFec.values.toList();

      if (groupFec.length < missingInGroup.length) {
        throw Exception(
          'FEC 恢复失败：第 $g 组缺失 ${missingInGroup.length} 帧，但仅收到 ${groupFec.length} 个有效 FEC 校验块',
        );
      }

      final e = missingInGroup.length;
      final selectedFec = groupFec.take(e).toList();

      // Retrieve last chunk length for this group from FEC packet
      final lastChunkLen = (endIdx == totalDataChunks)
          ? selectedFec.first.lastChunkLen
          : chunkPayloadCapacity;

      // Construct e x e submatrix matrixA using fixed Cauchy coordinates:
      // X = 128 + pIdx, Y = missingCol.
      final matrixA = List.generate(e, (row) {
        final pIdx = selectedFec[row].fecIndexInGroup;
        final rowBytes = Uint8List(e);
        for (int col = 0; col < e; col++) {
          final missingCol = missingInGroup[col];
          rowBytes[col] = GaloisField256.inv((128 + pIdx) ^ missingCol);
        }
        return rowBytes;
      });

      final aInv = GaloisField256.invertMatrix(matrixA);

      // Compute pPrime = P ^ sum_{known} C[p][j] * D[j]
      final pPrime = List.generate(e, (row) {
        final pIdx = selectedFec[row].fecIndexInGroup;
        final pData = Uint8List.fromList(selectedFec[row].payload);

        for (int j = 0; j < k; j++) {
          if (!missingInGroup.contains(j)) {
            final globalIdx = startIdx + j;
            final dRaw = result[globalIdx]!;
            final coeff = GaloisField256.inv((128 + pIdx) ^ j);
            if (coeff != 0) {
              for (int b = 0; b < dRaw.length; b++) {
                pData[b] ^= GaloisField256.mul(coeff, dRaw[b]);
              }
            }
          }
        }
        return pData;
      });

      // Solve D_{missing} = aInv * pPrime
      for (int col = 0; col < e; col++) {
        final missingLocalIdx = missingInGroup[col];
        final globalIdx = startIdx + missingLocalIdx;
        final isLastChunkOfStream = (globalIdx == totalDataChunks - 1);
        final targetLen = isLastChunkOfStream ? lastChunkLen : chunkPayloadCapacity;

        final recoveredBuf = Uint8List(chunkPayloadCapacity);
        for (int row = 0; row < e; row++) {
          final coeff = aInv[col][row];
          if (coeff != 0) {
            final pRow = pPrime[row];
            for (int b = 0; b < chunkPayloadCapacity; b++) {
              recoveredBuf[b] ^= GaloisField256.mul(coeff, pRow[b]);
            }
          }
        }

        result[globalIdx] = Uint8List.sublistView(recoveredBuf, 0, targetLen);
      }
    }

    return result;
  }
}
