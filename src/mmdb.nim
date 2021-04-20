import tables
import hashes
import math
import options
import bitops
import net
import streams
import endians

const
  MetadataMarker = "\xab\xcd\xefMaxMind.com"

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
      bytesVal*: string
    of mdkU16, mdkU32, mdkU64:
      u64Val*: uint64
    of mdkU128:
      u128Val*: string  # any better ideas?
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
    s*: Stream
    size: int

# MMDBData methods #

proc toMMDB*(stringVal: string): MMDBData =
  MMDBData(kind: mdkString, stringVal: stringVal)

proc hash*(x: MMDBData): Hash =
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
    of mdkMap:
      var mapHash: Hash = 0
      for k, v in x.mapVal.pairs:
        mapHash = mapHash !& k.hash !& v.hash
      mapHash
    of mdkArray:
      x.arrayVal.hash
    of mdkBoolean:
      x.booleanVal.hash
    of mdkFloat:
      x.floatVal.hash
  h = h !& atomHash
  result = !$h

proc `==`*(a, b: MMDBData): bool =
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

proc padIPv4Address(ipv4: array[0..3, uint8]): array[0..15, uint8] =
  for i in 0..11:
    result[i] = 0
  for i in 0..3:
    result[12 + i] = ipv4[i]

proc `+@`(p: pointer; offset: int): pointer =
  ## Pointer offset
  cast[pointer](cast[int](p) + offset)

# stream helpers #

proc setPosition(s: Stream; pos: int; relativeTo = fspSet; streamSize: int = -1) =
  case relativeTo
  of fspSet:
    streams.setPosition(s, pos)
  of fspCur:
    streams.setPosition(s, s.getPosition() + pos)
  of fspEnd:
    assert streamSize >= 0
    streams.setPosition(s, streamSize + pos)

proc rFind(s: Stream; streamSize: int; needle: string): int =
  let needleLen = needle.len
  var i = needleLen

  s.setPosition(-i, fspEnd, streamSize)

  while true:
    let buf = s.readStr(needleLen)
    if buf == needle:
      return streamSize - i
    if i == streamSize:
      break
    i.inc()
    s.setPosition(-i, fspEnd, streamSize)
  
  return -1

proc readBytes(s: Stream; size: int): string =
  s.readStr(size)

proc readByte(s: Stream): uint8 =
  s.readBytes(1)[0].uint8

proc readNumber(s: Stream; size: int): uint64 =
  for i in countdown(size - 1, 0):
    let n = s.readUint8()
    result += n * (256 ^ i).uint64

proc readControlByte(s: Stream): (MMDBDataKind, int) =
  let controlByte = s.readByte()
  var
    dataFormat = controlByte shr 5
    dataSize = (controlByte and 31).int  # 0d31 = 0b00011111

  if dataFormat == 0:  # extended
    dataFormat = 7 + s.readByte()

  if dataSize == 29:
    dataSize = 29 + s.readByte().int
  elif dataSize == 30:
    dataSize = 285 + (2 ^ 8)*s.readByte().int + s.readByte().int
  elif dataSize == 31:
    dataSize = 65821 + (2 ^ 16)*s.readByte().int + (2 ^ 8)*s.readByte().int + s.readByte().int

  (MMDBDataKind(dataFormat), dataSize)

# data decode #

proc decode*(mmdb: MMDB): MMDBData

proc decode*(s: Stream): MMDBData

proc decodeData(s: Stream; dataKind: MMDBDataKind; dataSize: int): MMDBData

proc decodePointer(mmdb: MMDB; value: int): MMDBData =
  let
    metadata = mmdb.metadata.get
    # first two bits indicate size
    size = 2*value.getBit(3 + 0) + value.getBit(3 + 1)
    # last three bits are used for the address
    addrPart = 3*value.getBit(3 + 2) + 2*value.getBit(3 + 3) + value.getBit(3 + 4)
    dataSectionStart = 16 + ((metadata["record_size"].u64Val * 2) div 8) * metadata["node_count"].u64Val  # given formula
    p: uint64 =
      if size == 0:
        (2'u64 ^ 8)*addrPart + mmdb.s.readByte()
      elif size == 1:
        (2'u64 ^ 16)*addrPart + (2'u64 ^ 8)*mmdb.s.readByte() + mmdb.s.readByte() + 2048'u64
      elif size == 2:
        (2'u64 ^ 24)*addrPart + (2'u64 ^ 16)*mmdb.s.readByte() + (2'u64 ^ 8)*mmdb.s.readByte() + mmdb.s.readByte() + 526336'u64
      elif size == 3:
        mmdb.s.readNumber(4)
      else:
        raise newException(ValueError, "invalid pointer size " & $size)
    absoluteOffset = dataSectionStart + p
    localPos = mmdb.s.getPosition()

  mmdb.s.setPosition(absoluteOffset.int)
  result = mmdb.decode()

  mmdb.s.setPosition(localPos)

proc decodeString(s: Stream; size: int): MMDBData =
  result = MMDBData(kind: mdkString)
  result.stringVal = s.readStr(size)

proc decodeDouble(s: Stream; _: int): MMDBData =
  result = MMDBData(kind: mdkDouble)
  var buf: float64
  discard s.readData(addr buf, 8)
  bigEndian64(addr result.doubleVal, addr buf)

proc decodeBytes(s: Stream; size: int): MMDBData =
  result = MMDBData(kind: mdkBytes)
  if size == 0:
    result.bytesVal = ""
  else:
    result.bytesVal = s.readBytes(size)

proc decodeUInt(s: Stream; size: int; kind: MMDBDataKind): MMDBData =
  result = MMDBData(kind: kind)
  result.u64Val = s.readNumber(size)

proc decodeU128(s: Stream; size: int): MMDBData =
  result = MMDBData(kind: mdkU128)
  result.u128Val = s.readBytes(size)

proc decodeI32(s: Stream; size: int): MMDBData =
  result = MMDBData(kind: mdkI32)
  var buf: int32
  discard s.readData((addr buf) +@ (4 - size), size)
  bigEndian32(addr result.i32Val, addr buf)

proc decodeMap(s: Stream; entryCount: int): MMDBData =
  result = MMDBData(kind: mdkMap)
  for _ in 0..<entryCount:
    let
      key = s.decode()
      val = s.decode()
    result.mapVal[key] = val

proc decodeArray(s: Stream; entryCount: int): MMDBData =
  result = MMDBData(kind: mdkArray)
  for _ in 0..<entryCount:
    let val = s.decode()
    result.arrayVal.add(val)

proc decodeBoolean(s: Stream; value: int): MMDBData =
  result = MMDBData(kind: mdkBoolean)
  result.booleanVal = value.bool

proc decodeFloat(s: Stream; _: int): MMDBData =
  result = MMDBData(kind: mdkFloat)
  var buf: float32
  discard s.readData(addr buf, 4)
  bigEndian32(addr result.floatVal, addr buf)

proc decodeData(s: Stream; dataKind: MMDBDataKind; dataSize: int): MMDBData =
  result = case dataKind
    of mdkString:
      s.decodeString(dataSize)
    of mdkDouble:
      s.decodeDouble(dataSize)
    of mdkBytes:
      s.decodeBytes(dataSize)
    of mdkU16, mdkU32, mdkU64:
      s.decodeUInt(dataSize, dataKind)
    of mdkU128:
      s.decodeU128(dataSize)
    of mdkI32:
      s.decodeI32(dataSize)
    of mdkMap:
      s.decodeMap(dataSize)
    of mdkArray:
      s.decodeArray(dataSize)
    of mdkBoolean:
      s.decodeBoolean(dataSize)
    of mdkFloat:
      s.decodeFloat(dataSize)
    of mdkPointer:
      raise newException(ValueError, "Decoding " & $dataKind & " requires an MMDB object")
    else:
      raise newException(ValueError, "Can't deal with format " & $dataKind)

proc decode*(mmdb: MMDB): MMDBData =
  let (dataKind, dataSize) = mmdb.s.readControlByte()
  result = case dataKind
    of mdkPointer:
      mmdb.decodePointer(dataSize)
    else:
      mmdb.s.decodeData(dataKind, dataSize)

proc decode*(s: Stream): MMDBData =
  let (dataKind, dataSize) = s.readControlByte()
  s.decodeData(dataKind, dataSize)

# metadata #
# TODO: fail gracefully when metadata not found, maybe conditional on a compilation flag

proc getMetadataPos(mmdb: MMDB): int =
  mmdb.s.rFind(mmdb.size, MetadataMarker) + MetadataMarker.len

proc readMetadata(mmdb: var MMDB) =
  mmdb.s.setPosition(mmdb.getMetadataPos())
  mmdb.metadata = some(mmdb.decode())

# public methods #

proc lookup*(mmdb: MMDB; ipAddr: openArray[uint8]): MMDBData =
  if mmdb.metadata.isNone:
    raise newException(ValueError, "No database is open.")
  if mmdb.metadata.get.kind != mdkMap:
    raise newException(ValueError, "Invalid metadata; expected " & $mdkMap & ", got " & $mmdb.metadata.get.kind)

  let
    metadata = mmdb.metadata.get
    recordSizeBits: uint64 = metadata["record_size"].u64Val
    nodeSizeBits: uint64 = 2 * recordSizeBits
    nodeCount: uint64 = metadata["node_count"].u64Val
    treeSize: uint64 = ((recordSizeBits.int * 2) div 8).uint64 * nodeCount.uint64

  if metadata["ip_version"].u64Val != 6'u64:
    raise newException(ValueError, "Only IPv6 databases are supported for now")
  if recordSizeBits != 24:
    raise newException(ValueError, "Only record size 24 is supported for now")
  
  mmdb.s.setPosition(0)  # go to root node

  for b in ipAddr:
    for j in 0..<8:
      let bit = b.getBit(j)

      if bit == 1:  # right record
        mmdb.s.setPosition((recordSizeBits div 8).int, fspCur)
      # else, if left record, we are already in the correct position

      let recordVal = mmdb.s.readNumber((recordSizeBits div 8).int)

      if recordVal < nodeCount:
        let absoluteOffset = recordVal * nodeSizeBits div 8
        mmdb.s.setPosition(absoluteOffset.int)
      elif recordVal == nodeCount:
        raise newException(KeyError, "IP address does not exist in database")
      else: # recordVal > nodeCount
        let absoluteOffset = (recordVal - nodeCount) + treeSize  # given formula
        mmdb.s.setPosition(absoluteOffset.int)
        return mmdb.decode()

proc lookup*(mmdb: MMDB; ipAddrStr: string): MMDBData =
  let
    ipAddrObj = parseIpAddress(ipAddrStr)
    ipAddrBytes =
      case ipAddrObj.family
      of IpAddressFamily.IPv6:
        ipAddrObj.address_v6
      of IpAddressFamily.IPv4:
        padIPv4Address(ipAddrObj.address_v4)
  mmdb.lookup(ipAddrBytes)

proc openFile*(mmdb: var MMDB; stream: Stream) =
  mmdb.s = stream
  mmdb.readMetadata()

proc openFile*(mmdb: var MMDB; file: File) =
  mmdb.size = file.getFileSize().int
  mmdb.openFile(newFileStream(file))

proc openFile*(mmdb: var MMDB; filename: string) =
  let file = open(filename, fmRead)
  mmdb.openFile(file)

proc initMMDB*(filename: string): MMDB =
  result.openFile(filename)

proc initMMDB*(file: File): MMDB =
  result.openFile(file)


when isMainModule:
  let mmdb = initMMDB("dbip-lite.mmdb")
  echo mmdb.metadata
  let info = mmdb.lookup("1.1.1.1")
  echo $info["country"]["names"]["en"] & " (" & $info["country"]["iso_code"] & ")"
