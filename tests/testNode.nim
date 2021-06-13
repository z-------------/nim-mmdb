import std/unittest
import std/streams
import mmdb

template write(s: Stream; bytes: varargs[uint8]) =
  for b in bytes:
    s.write(b)

test "28 bit records are read correctly":
  var s = newStringStream()
  s.write(0b00000000'u8, 0b11111111'u8, 0b11110000'u8, 0b0101_1010'u8, 0b11111111'u8, 0b00001111'u8, 0b00000000'u8)
  
  s.setPosition(0)
  check s.readNode(0, 28) == 0b0101_00000000_11111111_11110000

  s.setPosition(0)
  check s.readNode(1, 28) == 0b1010_11111111_00001111_00000000
