import std/unittest
import std/streams
import mmdb

type
  Testcase = (seq[uint8], uint64, uint64)

template writeBytes(s: Stream; bytes: openArray[uint8]) =
  for b in bytes:
    s.write(b)

template checkNodes(testcases: openArray[Testcase]; recordSizeBits: int) =
  var s: StringStream
  for (bytes, expectedLeft, expectedRight) in testcases:
    s = newStringStream()
    s.writeBytes(bytes)

    s.setPosition(0)
    check s.readNode(0, recordSizeBits) == expectedLeft

    s.setPosition(0)
    check s.readNode(1, recordSizeBits) == expectedRight

test "24 bit records":
  checkNodes([
    (
      @[0b00010000'u8, 0b10111111'u8, 0b11110000'u8, 0b11111101'u8, 0b00001111'u8, 0b00001000'u8],
      0b00010000_10111111_11110000'u64,
      0b11111101_00001111_00001000'u64,
    ),
    (
      @[0b00100011'u8, 0b11111011'u8, 0b00001011'u8, 0b00110100'u8, 0b00010011'u8, 0b00101111'u8],
      0b00100011_11111011_00001011'u64,
      0b00110100_00010011_00101111'u64,
    ),
  ], 24)

test "28 bit records":
  checkNodes([
    (
      @[0b00000000'u8, 0b11111111'u8, 0b11110000'u8, 0b0101_1010'u8, 0b11111111'u8, 0b00001111'u8, 0b00000000'u8],
      0b0101_00000000_11111111_11110000'u64,
      0b1010_11111111_00001111_00000000'u64,
    ),
    (
      @[0b11101000'u8, 0b11001100'u8, 0b10010001'u8, 0b1101_0000'u8, 0b10011101'u8, 0b01111011'u8, 0b11100010'u8],
      0b1101_11101000_11001100_10010001'u64,
      0b0000_10011101_01111011_11100010'u64,
    ),
  ], 28)

test "32 bit records":
  checkNodes([
    (
      @[0b00000000'u8, 0b00001111'u8, 0b11110000'u8, 0b11111111'u8, 0b01111111'u8, 0b01111110'u8, 0b00111110'u8, 0b00111100'u8],
      0b00000000_00001111_11110000_11111111'u64,
      0b01111111_01111110_00111110_00111100'u64,
    ),
    (
      @[0b11010011'u8, 0b11000111'u8, 0b11100001'u8, 0b01111010'u8, 0b11000110'u8, 0b10011000'u8, 0b11100000'u8, 0b01110101'u8],
      0b11010011_11000111_11100001_01111010'u64,
      0b11000110_10011000_11100000_01110101'u64,
    ),
  ], 32)
