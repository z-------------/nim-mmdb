import sugar
import tables
import math
import strutils

const
  MetadataMarker = collect(newSeq):
    for c in "\xab\xcd\xefMaxMind.com":
      c.uint8

type
  MMDBDataKind* = enum
    mdkPointer
    mdkString
    mdkDouble
    mdkBytes
    mdkU64
    mdkU128
    mdkI32
    mdkMap
    mdkArray
    mdkBoolean
    mdkFloat
  MMDBData* = ref object
    case kind*: MMDBDataKind
    of mdkPointer:
      discard
    of mdkString:
      stringVal*: string
    of mdkDouble:
      doubleVal*: float64
    of mdkBytes:
      bytesVal*: seq[char]
    of mdkU64:
      u64Val*: uint64
    of mdkU128:
      u128Val*: seq[char]  # any better ideas?
    of mdkI32:
      i32Val*: int32
    of mdkMap:
      mapVal*: Table[MMDBData, MMDBData]
    of mdkArray:
      arrayVal*: seq[MMDBData]
    of mdkBoolean:
      booleanVal*: bool
    of mdkFloat:
      floatVal*: float32
  MMDB* = ref object
    metadata*: MMDBData
    f: File
    size: int

# type helpers #

proc toMMDBDataKind(n: uint): MMDBDataKind =
  case n
  of 1:
    mdkPointer
  of 2:
    mdkString
  of 3:
    mdkDouble
  of 4:
    mdkBytes
  of 5:
    mdkU64
  of 6:
    mdkU64
  of 8:
    mdkI32
  of 9:
    mdkU64
  of 10:
    mdkU64
  of 7:
    mdkMap
  of 11:
    mdkArray
  of 14:
    mdkBoolean
  of 15:
    mdkFloat
  else:
    raise newException(ValueError, "Can't deal with format number " & $n)

# file helpers #

proc rFind(f: File; needle: seq[uint8]): int =
  let
    needleLen = needle.len
    fileLen = f.getFileSize().int
  var
    i = needleLen
    buf = newSeq[uint8](needleLen)

  f.setFilePos(-i, fspEnd)

  while true:
    discard f.readBytes(buf, 0, needleLen)
    if buf == needle:
      return fileLen - i
    if i == fileLen:
      break
    i.inc()
    f.setFilePos(-i, fspEnd)
  
  return -1

proc advance(f: File) =
  f.setFilePos(1, fspCur)

proc readBytes(f: File; size: int): seq[uint8] =
  result = newSeq[uint8](size)
  discard f.readBytes(result, 0, size)

proc readByte(f: File): uint8 =
  f.readBytes(1)[0]

proc readNumber(f: File; size: int): uint64 =
  for i in countdown(size - 1, 0):
    let n = f.readByte()
    result += n * (256 ^ i).uint8

proc readControlByte(f: File): (MMDBDataKind, int) =
  let
    controlByte = f.readByte()
  var
    dataFormat = controlByte shr 5
    dataSize = (controlByte and 31).int  # 0d31 = 0b00011111

  if dataFormat == 0:  # extended
    dataFormat = 7 + f.readByte()

  if dataSize == 29:
    dataSize = 29 + f.readByte().int
  elif dataSize == 30:
    dataSize = 285 + (2 ^ 8)*f.readByte().int + f.readByte().int
  elif dataSize == 31:
    dataSize = 65821 + (2 ^ 16)*f.readByte().int + (2 ^ 8)*f.readByte().int + f.readByte().int

  (dataFormat.toMMDBDataKind(), dataSize)

# data decode #

proc decodeData(mmdb: MMDB): MMDBData =
  echo mmdb.f.getFilePos().toHex

  let (dataFormat, dataSize) = mmdb.f.readControlByte()

  case dataFormat
  else:
    raise newException(ValueError, "Can't deal with format " & $dataFormat)

# metadata #

proc getMetadataPos(mmdb: MMDB): int =
  mmdb.f.rFind(MetadataMarker) + MetadataMarker.len

proc readMetadata(mmdb: MMDB) =
  mmdb.f.setFilePos(mmdb.getMetadataPos())
  mmdb.metadata = mmdb.decodeData()

# public methods #

proc openFile*(mmdb: MMDB; filename: string) =
  mmdb.f = open(filename, fmRead)
  mmdb.readMetadata()


when isMainModule:
  var mmdb = MMDB.new
  mmdb.openFile("dbip-lite.mmdb")
