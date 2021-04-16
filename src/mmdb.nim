import sugar
import tables
import hashes
import math
import options
import bitops
import net

const
  MetadataMarker = collect(newSeq):
    for c in "\xab\xcd\xefMaxMind.com":
      c.uint8

type
  MMDBDataKind* = enum
    mdkNone = 0  # we need this because enums must start from 0
    mdkPointer = 1
    mdkString = 2
    mdkDouble = 3
    mdkBytes = 4
    mdkU16 = 5
    mdkU32 = 6
    mdkMap = 7
    mdkI32 = 8
    mdkU64 = 9
    mdkU128 = 10
    mdkArray = 11
    mdkBoolean = 14
    mdkFloat = 15
  MMDBData* = object
    case kind*: MMDBDataKind
    of mdkNone, mdkPointer:
      discard
    of mdkString:
      stringVal*: string
    of mdkDouble:
      doubleVal*: float64
    of mdkBytes:
      bytesVal*: seq[uint8]
    of mdkU16, mdkU32, mdkU64:
      u64Val*: uint64
    of mdkU128:
      u128Val*: seq[uint8]  # any better ideas?
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
  MMDB* = object
    metadata*: Option[MMDBData]
    f: File
    size: int

# MMDBData methods #

proc toMMDB(stringVal: string): MMDBData =
  MMDBData(kind: mdkString, stringVal: stringVal)

proc hash(x: MMDBData): Hash =
  var h: Hash = 0
  h = h !& x.kind.ord
  let atomHash = case x.kind
    of mdkNone, mdkPointer:
      0.hash
    of mdkString:
      x.stringVal.hash
    of mdkDouble:
      x.doubleVal.hash
    of mdkBytes:
      x.bytesVal.hash
    of mdkU16, mdkU32, mdkU64:
      x.u64Val.hash
    of mdkU128:
      x.u128Val.hash
    of mdkI32:
      x.i32Val.hash
    # of mdkMap:
    #   x.mapVal.hash
    of mdkArray:
      x.arrayVal.hash
    of mdkBoolean:
      x.booleanVal.hash
    of mdkFloat:
      x.floatVal.hash
    else:
      raise newException(ValueError, "Can't use " & $x.kind & " data as map key")
  h = h !& atomHash
  result = !$h

proc `==`(a, b: MMDBData): bool =
  a.hash == b.hash

proc `[]`*(x: MMDBData; key: MMDBData): MMDBData =
  if x.kind != mdkMap:
    raise newException(ValueError, "Expected kind " & $mdkMap)
  x.mapVal[key]

proc `[]`*(x: MMDBData; key: string): MMDBData =
  x[key.toMMDB]

proc `$`*(x: MMDBData): string =
  case x.kind
  of mdkNone, mdkPointer:
    $x
  of mdkString:
    $x.stringVal
  of mdkDouble:
    $x.doubleVal
  of mdkBytes:
    $x.bytesVal
  of mdkU16, mdkU32, mdkU64:
    $x.u64Val
  of mdkU128:
    $x.u128Val
  of mdkI32:
    $x.i32Val
  of mdkMap:
    $x.mapVal
  of mdkArray:
    $x.arrayVal
  of mdkBoolean:
    $x.booleanVal
  of mdkFloat:
    $x.floatVal

# bit and byte helpers #

proc getBit[T: SomeInteger](v: T; bit: BitsRange[T]): uint8 {.inline.} =
  if v.testBit(7 - bit):
    1'u8
  else:
    0'u8

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

proc readBytes(f: File; size: int): seq[uint8] =
  result = newSeq[uint8](size)
  discard f.readBytes(result, 0, size)

proc readByte(f: File): uint8 =
  f.readBytes(1)[0]

proc readNumber(f: File; size: int): uint64 =
  for i in countdown(size - 1, 0):
    let n = f.readByte()
    result += n * (256 ^ i).uint64

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

  (MMDBDataKind(dataFormat), dataSize)

# data decode #

proc decode(mmdb: MMDB): MMDBData

proc decodePointer(mmdb: MMDB; value: int): MMDBData =
  let
    metadata = mmdb.metadata.get.mapVal
    # first two bits indicate size
    size = 2*value.getBit(3 + 0) + value.getBit(3 + 1)
    # last three bits are used for the address
    addrPart = 3*value.getBit(3 + 2) + 2*value.getBit(3 + 3) + value.getBit(3 + 4)
    dataSectionStart = 16 + ((metadata["record_size".toMMDB].u64Val * 2) div 8) * metadata["node_count".toMMDB].u64Val  # given formula
    p: uint64 =
      if size == 0:
        (2'u64 ^ 8)*addrPart + mmdb.f.readByte()
      elif size == 1:
        (2'u64 ^ 16)*addrPart + (2'u64 ^ 8)*mmdb.f.readByte() + mmdb.f.readByte() + 2048'u64
      elif size == 2:
        (2'u64 ^ 24)*addrPart + (2'u64 ^ 16)*mmdb.f.readByte() + (2'u64 ^ 8)*mmdb.f.readByte() + mmdb.f.readByte() + 526336'u64
      elif size == 3:
        mmdb.f.readNumber(4)
      else:
        raise newException(ValueError, "invalid pointer size " & $size)
    absoluteOffset = dataSectionStart + p
    localPos = mmdb.f.getFilePos()

  mmdb.f.setFilePos(absoluteOffset.int64)
  result = mmdb.decode()

  mmdb.f.setFilePos(localPos)

proc decodeString(mmdb: MMDB; size: int): MMDBData =
  result = MMDBData(kind: mdkString)
  result.stringVal = newString(size)
  discard mmdb.f.readChars(result.stringVal, 0, size)

proc decodeDouble(mmdb: MMDB; _: int): MMDBData =
  result = MMDBData(kind: mdkDouble)
  discard mmdb.f.readBuffer(result.doubleVal.addr, 8)

proc decodeBytes(mmdb: MMDB; size: int): MMDBData =
  result = MMDBData(kind: mdkBytes)
  if size == 0:
    result.bytesVal = newSeqOfCap[uint8](0)
  else:
    result.bytesVal = mmdb.f.readBytes(size)

proc decodeU16(mmdb: MMDB; size: int): MMDBData =
  result = MMDBData(kind: mdkU16)
  result.u64Val = mmdb.f.readNumber(size)

proc decodeU32(mmdb: MMDB; size: int): MMDBData =
  result = MMDBData(kind: mdkU32)
  result.u64Val = mmdb.f.readNumber(size)

proc decodeU64(mmdb: MMDB; size: int): MMDBData =
  result = MMDBData(kind: mdkU64)
  result.u64Val = mmdb.f.readNumber(size)

proc decodeU128(mmdb: MMDB; size: int): MMDBData =
  result = MMDBData(kind: mdkU128)
  result.u128Val = mmdb.f.readBytes(size)

proc decodeI32(mmdb: MMDB; size: int): MMDBData =
  result = MMDBData(kind: mdkI32)
  discard mmdb.f.readBuffer(result.i32Val.addr, size)

proc decodeMap(mmdb: MMDB; entryCount: int): MMDBData =
  result = MMDBData(kind: mdkMap)
  for _ in 0..<entryCount:
    let
      key = mmdb.decode()
      val = mmdb.decode()
    result.mapVal[key] = val

proc decodeArray(mmdb: MMDB; entryCount: int): MMDBData =
  result = MMDBData(kind: mdkArray)
  for _ in 0..<entryCount:
    let val = mmdb.decode()
    result.arrayVal.add(val)

proc decodeBoolean(mmdb: MMDB; value: int): MMDBData =
  result = MMDBData(kind: mdkBoolean)
  result.booleanVal = value.bool

proc decodeFloat(mmdb: MMDB; _: int): MMDBData =
  result = MMDBData(kind: mdkFloat)
  discard mmdb.f.readBuffer(result.floatVal.addr, 4)

proc decode(mmdb: MMDB): MMDBData =
  let (dataFormat, dataSize) = mmdb.f.readControlByte()
  result = case dataFormat
    of mdkPointer:
      mmdb.decodePointer(dataSize)
    of mdkString:
      mmdb.decodeString(dataSize)
    of mdkDouble:
      mmdb.decodeDouble(dataSize)
    of mdkBytes:
      mmdb.decodeBytes(dataSize)
    of mdkU16:
      mmdb.decodeU16(dataSize)
    of mdkU32:
      mmdb.decodeU32(dataSize)
    of mdkU64:
      mmdb.decodeU64(dataSize)
    of mdkU128:
      mmdb.decodeU128(dataSize)
    of mdkI32:
      mmdb.decodeI32(dataSize)
    of mdkMap:
      mmdb.decodeMap(dataSize)
    of mdkArray:
      mmdb.decodeArray(dataSize)
    of mdkBoolean:
      mmdb.decodeBoolean(dataSize)
    of mdkFloat:
      mmdb.decodeFloat(dataSize)
    else:
      raise newException(ValueError, "Can't deal with format " & $dataFormat)

# metadata #

proc getMetadataPos(mmdb: MMDB): int =
  mmdb.f.rFind(MetadataMarker) + MetadataMarker.len

proc readMetadata(mmdb: var MMDB) =
  mmdb.f.setFilePos(mmdb.getMetadataPos())
  mmdb.metadata = some(mmdb.decode())

# public methods #

proc lookup*(mmdb: MMDB; ipAddr: openArray[uint8]): MMDBData =
  if mmdb.metadata.isNone:
    raise newException(ValueError, "No database is open.")
  if mmdb.metadata.get.kind != mdkMap:
    raise newException(ValueError, "Invalid metadata; expected " & $mdkMap & ", got " & $mmdb.metadata.get.kind)

  let
    metadata = mmdb.metadata.get.mapVal
    recordSizeBits: uint64 = metadata["record_size".toMMDB].u64Val
    nodeSizeBits: uint64 = 2 * recordSizeBits
    nodeCount: uint64 = metadata["node_count".toMMDB].u64Val
    treeSize: uint64 = ((recordSizeBits.int * 2) div 8).uint64 * nodeCount.uint64

  if metadata["ip_version".toMMDB].u64Val != 6.uint64:
    raise newException(ValueError, "Only IPv6 databases are supported for now")
  if recordSizeBits != 24:
    raise newException(ValueError, "Only record size 24 is supported for now")
  
  mmdb.f.setFilePos(0)  # go to root node

  for b in ipAddr:
    for j in 0..<8:
      let bit = b.getBit(j)

      if bit == 1:  # right record
        mmdb.f.setFilePos((recordSizeBits div 8).int64, fspCur)
      # else, if left record, we are already in the correct position

      let recordVal = mmdb.f.readNumber((recordSizeBits div 8).int)

      if recordVal < nodeCount:
        let absoluteOffset = recordVal * nodeSizeBits div 8
        mmdb.f.setFilePos(absoluteOffset.int64)
      elif recordVal == nodeCount:
        raise newException(KeyError, "IP address does not exist in database")
      else: # recordVal > nodeCount
        let absoluteOffset = (recordVal - nodeCount) + treeSize  # given formula
        mmdb.f.setFilePos(absoluteOffset.int64)
        return mmdb.decode()

proc lookup*(mmdb: MMDB; ipAddrStr: string): MMDBData =
  let ipAddrObj = parseIpAddress(ipAddrStr)  
  case ipAddrObj.family
  of IpAddressFamily.IPv6:
    lookup(mmdb, ipAddrObj.address_v6)
  of IpAddressFamily.IPv4:
    var addrV4Padded: array[0..15, uint8]
    for i in 0..11:
      addrV4Padded[i] = 0
    for i in 0..3:
      addrV4Padded[12 + i] = ipAddrObj.address_v4[i]
    lookup(mmdb, addrV4Padded)

proc openFile*(mmdb: var MMDB; filename: string) =
  mmdb.f = open(filename, fmRead)
  mmdb.readMetadata()

proc openFile*(mmdb: var MMDB; file: File) =
  mmdb.f = file
  mmdb.readMetadata()


when isMainModule:
  var mmdb: MMDB
  mmdb.openFile("dbip-lite.mmdb")
  let info = mmdb.lookup("1.1.1.1")
  echo $info["country"]["names"]["en"] & " (" & $info["country"]["iso_code"] & ")"
