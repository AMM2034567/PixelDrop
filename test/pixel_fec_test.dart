import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pixel_drop/services/pixel_fec.dart';

void main() {
  group('GaloisField256 Math Tests', () {
    test('GF(2^8) initialization and basic operations', () {
      GaloisField256.init();
      expect(GaloisField256.add(5, 5), 0);
      expect(GaloisField256.add(10, 6), 12); // 10 ^ 6 = 12
      expect(GaloisField256.mul(1, 42), 42);
      expect(GaloisField256.mul(0, 42), 0);
      expect(GaloisField256.div(42, 1), 42);

      // Inversion property: a * inv(a) == 1
      for (int i = 1; i < 256; i++) {
        final inverse = GaloisField256.inv(i);
        expect(GaloisField256.mul(i, inverse), 1);
        expect(GaloisField256.div(i, i), 1);
      }
    });

    test('GF(2^8) Matrix Inversion', () {
      GaloisField256.init();
      // Test 2x2 identity inversion
      final identity2 = [
        Uint8List.fromList([1, 0]),
        Uint8List.fromList([0, 1]),
      ];
      final invI2 = GaloisField256.invertMatrix(identity2);
      expect(invI2[0], [1, 0]);
      expect(invI2[1], [0, 1]);

      // Test 3x3 invertible matrix
      final m = [
        Uint8List.fromList([1, 2, 3]),
        Uint8List.fromList([0, 4, 5]),
        Uint8List.fromList([1, 0, 6]),
      ];
      final invM = GaloisField256.invertMatrix(m);
      // Verify m * invM == I
      for (int r = 0; r < 3; r++) {
        for (int c = 0; c < 3; c++) {
          int dot = 0;
          for (int k = 0; k < 3; k++) {
            dot ^= GaloisField256.mul(m[r][k], invM[k][c]);
          }
          expect(dot, (r == c) ? 1 : 0);
        }
      }
    });

    test('Cauchy matrix has non-singular submatrices', () {
      GaloisField256.init();
      final cauchy = GaloisField256.createCauchyMatrix(4, 5);
      expect(cauchy.length, 4);
      expect(cauchy[0].length, 5);

      // Any 2x2 submatrix must be invertible
      final sub2x2 = [
        Uint8List.fromList([cauchy[0][1], cauchy[0][3]]),
        Uint8List.fromList([cauchy[2][1], cauchy[2][3]]),
      ];
      final invSub = GaloisField256.invertMatrix(sub2x2);
      expect(invSub.length, 2);
    });
  });

  group('PixelFec End-to-End Erasure Coding Tests', () {
    test('Single chunk with 1 parity packet (100% redundancy): recovers chunk 0 when lost', () {
      final chunk0 = Uint8List.fromList([1, 2, 3, 4, 5, 42, 99, 128, 255]);
      final packets = PixelFec.generateParityPackets(
        dataChunks: [chunk0],
        redundancyPercent: 100,
        chunkPayloadCapacity: chunk0.length,
      );

      expect(packets.length, 1);
      expect(packets.first.lastChunkLen, chunk0.length);

      // Simulate chunk 0 lost
      final recovered = PixelFec.recoverMissingData(
        totalDataChunks: 1,
        collectedDataChunks: {},
        collectedFecPackets: packets,
        chunkPayloadCapacity: chunk0.length,
      );

      expect(recovered.length, 1);
      expect(recovered[0], chunk0);
    });

    test('Multi-chunk data (5 chunks, 2 parity chunks): recovers head and tail drops', () {
      const cap = 64;
      final rng = Random(42);
      final originalChunks = List.generate(5, (i) {
        final len = (i == 4) ? 37 : cap; // Last chunk is non-aligned
        return Uint8List.fromList(List.generate(len, (_) => rng.nextInt(256)));
      });

      final packets = PixelFec.generateParityPackets(
        dataChunks: originalChunks,
        redundancyPercent: 40, // 5 * 0.4 = 2 parity chunks
        chunkPayloadCapacity: cap,
      );

      expect(packets.length, 2);

      // Scenario A: Head frame (index 0) and tail frame (index 4) are both dropped
      final collectedWithDrops = <int, Uint8List>{
        1: originalChunks[1],
        2: originalChunks[2],
        3: originalChunks[3],
      };

      final recovered = PixelFec.recoverMissingData(
        totalDataChunks: 5,
        collectedDataChunks: collectedWithDrops,
        collectedFecPackets: packets,
        chunkPayloadCapacity: cap,
      );

      expect(recovered.length, 5);
      for (int i = 0; i < 5; i++) {
        expect(recovered[i], originalChunks[i], reason: 'Chunk $i must match exactly');
      }
    });

    test('Random middle drops (10 chunks, 3 parity chunks): recovers any 3 missing chunks', () {
      const cap = 128;
      final rng = Random(12345);
      final originalChunks = List.generate(10, (i) {
        final len = (i == 9) ? 80 : cap;
        return Uint8List.fromList(List.generate(len, (_) => rng.nextInt(256)));
      });

      final packets = PixelFec.generateParityPackets(
        dataChunks: originalChunks,
        redundancyPercent: 30, // 10 * 0.3 = 3 parity chunks
        chunkPayloadCapacity: cap,
      );

      expect(packets.length, 3);

      // Drop chunks 2, 5, 8
      final droppedIndices = {2, 5, 8};
      final collected = <int, Uint8List>{};
      for (int i = 0; i < 10; i++) {
        if (!droppedIndices.contains(i)) {
          collected[i] = originalChunks[i];
        }
      }

      final recovered = PixelFec.recoverMissingData(
        totalDataChunks: 10,
        collectedDataChunks: collected,
        collectedFecPackets: packets,
        chunkPayloadCapacity: cap,
      );

      expect(recovered.length, 10);
      for (int i = 0; i < 10; i++) {
        expect(recovered[i], originalChunks[i]);
      }
    });

    test('e < m: drop fewer chunks than total parity packets (1 dropped out of 10 with 3 parity packets)', () {
      const cap = 128;
      final rng = Random(12345);
      final originalChunks = List.generate(10, (i) {
        return Uint8List.fromList(List.generate(cap, (_) => rng.nextInt(256)));
      });

      final packets = PixelFec.generateParityPackets(
        dataChunks: originalChunks,
        redundancyPercent: 30, // 3 parity packets (p=0, 1, 2)
        chunkPayloadCapacity: cap,
      );

      expect(packets.length, 3);

      // Drop ONLY chunk 4 (e = 1 < m = 3)
      final collected = <int, Uint8List>{};
      for (int i = 0; i < 10; i++) {
        if (i != 4) collected[i] = originalChunks[i];
      }

      final recovered = PixelFec.recoverMissingData(
        totalDataChunks: 10,
        collectedDataChunks: collected,
        collectedFecPackets: packets,
        chunkPayloadCapacity: cap,
      );

      expect(recovered[4], originalChunks[4], reason: 'Chunk 4 must be restored bit-exact');
    });

    test('Parity packet 0 is missing: recovery uses non-zero indexed parity packets (packet 1 and 2)', () {
      const cap = 64;
      final rng = Random(54321);
      final originalChunks = List.generate(6, (i) {
        return Uint8List.fromList(List.generate(cap, (_) => rng.nextInt(256)));
      });

      final packets = PixelFec.generateParityPackets(
        dataChunks: originalChunks,
        redundancyPercent: 50, // 3 parity packets (p=0, 1, 2)
        chunkPayloadCapacity: cap,
      );

      expect(packets.length, 3);

      // Drop data chunks 1 and 3 (e = 2)
      final collected = <int, Uint8List>{};
      for (int i = 0; i < 6; i++) {
        if (i != 1 && i != 3) collected[i] = originalChunks[i];
      }

      // Parity packet 0 was lost in transit, only packets 1 and 2 survived!
      final survivingPackets = [packets[1], packets[2]];

      final recovered = PixelFec.recoverMissingData(
        totalDataChunks: 6,
        collectedDataChunks: collected,
        collectedFecPackets: survivingPackets,
        chunkPayloadCapacity: cap,
      );

      expect(recovered[1], originalChunks[1]);
      expect(recovered[3], originalChunks[3]);
    });

    test('Duplicate FEC packets in input: deduplication prevents singular matrix crash', () {
      const cap = 64;
      final rng = Random(888);
      final originalChunks = List.generate(4, (i) => Uint8List.fromList(List.generate(cap, (_) => rng.nextInt(256))));

      final packets = PixelFec.generateParityPackets(
        dataChunks: originalChunks,
        redundancyPercent: 50, // 2 parity packets
        chunkPayloadCapacity: cap,
      );

      // Duplicate packet 0 three times, simulate multiple duplicate hold frames
      final duplicatePackets = [packets[0], packets[0], packets[0], packets[1], packets[1]];

      final collected = <int, Uint8List>{
        1: originalChunks[1],
        2: originalChunks[2],
      }; // chunks 0 and 3 missing

      final recovered = PixelFec.recoverMissingData(
        totalDataChunks: 4,
        collectedDataChunks: collected,
        collectedFecPackets: duplicatePackets,
        chunkPayloadCapacity: cap,
      );

      expect(recovered[0], originalChunks[0]);
      expect(recovered[3], originalChunks[3]);
    });

    test('Multi-group recovery (> 128 chunks): recovers dropped frames across different groups', () {
      const cap = 32;
      const totalChunks = 150; // Group 0 has 128 chunks, Group 1 has 22 chunks
      final rng = Random(777);
      final originalChunks = List.generate(totalChunks, (i) {
        final len = (i == totalChunks - 1) ? 17 : cap;
        return Uint8List.fromList(List.generate(len, (_) => rng.nextInt(256)));
      });

      final packets = PixelFec.generateParityPackets(
        dataChunks: originalChunks,
        redundancyPercent: 10,
        chunkPayloadCapacity: cap,
      );

      // Verify packets exist for both groups
      expect(packets.any((p) => p.groupIndex == 0), isTrue);
      expect(packets.any((p) => p.groupIndex == 1), isTrue);

      // Drop frames in group 0 (chunks 10, 50) and group 1 (chunk 130, 149)
      final droppedIndices = {10, 50, 130, 149};
      final collected = <int, Uint8List>{};
      for (int i = 0; i < totalChunks; i++) {
        if (!droppedIndices.contains(i)) {
          collected[i] = originalChunks[i];
        }
      }

      final recovered = PixelFec.recoverMissingData(
        totalDataChunks: totalChunks,
        collectedDataChunks: collected,
        collectedFecPackets: packets,
        chunkPayloadCapacity: cap,
      );

      expect(recovered.length, totalChunks);
      for (final dropped in droppedIndices) {
        expect(recovered[dropped], originalChunks[dropped], reason: 'Dropped chunk $dropped must match');
      }
    });

    test('Zero loss: recoverMissingData returns identical map without matrix inversion', () {
      final original = {
        0: Uint8List.fromList([1, 2, 3]),
        1: Uint8List.fromList([4, 5, 6]),
      };
      final recovered = PixelFec.recoverMissingData(
        totalDataChunks: 2,
        collectedDataChunks: original,
        collectedFecPackets: [],
        chunkPayloadCapacity: 3,
      );
      expect(recovered, original);
    });

    test('Insufficient parity packets throws descriptive exception', () {
      final packets = [
        FecPacket(
          groupIndex: 0,
          fecIndexInGroup: 0,
          fecTotalInGroup: 1,
          dataTotalInGroup: 3,
          startChunkIndex: 0,
          lastChunkLen: 10,
          payload: Uint8List(10),
        ),
      ];

      expect(
        () => PixelFec.recoverMissingData(
          totalDataChunks: 3,
          collectedDataChunks: {0: Uint8List(10)}, // missing chunks 1 and 2 (needs 2, has 1)
          collectedFecPackets: packets,
          chunkPayloadCapacity: 10,
        ),
        throwsA(isA<Exception>().having((e) => e.toString(), 'msg', contains('FEC 恢复失败'))),
      );
    });
  });
}
