import std/tables
import std/hashes
import std/options
import std/bitops
import std/net
import std/streams

export options

const
  MetadataMarker = "\xab\xcd\xefMaxMind.com"

type
  MMDBDataKind* = enum
    mdkNone
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
    mdkInvalid12
    mdkInvalid13
    mdkBoolean = 14
    mdkFloat = 15
  MMDBData* = object
    case kind*: MMDBDataKind
    of mdkPointer:
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
      u128Val*: string # any better ideas?
    of mdkI32:
      i32Val*: int32
    of mdkMap:
      mapVal*: OrderedTable[MMDBData, MMDBData]
    of mdkArray:
      arrayVal*: seq[MMDBData]
    of mdkBoolean:
      booleanVal*: bool
    of mdkFloat:
      floatVal*: float32
    else:
      discard
  MMDB* = object
    metadata*: Option[MMDBData]
    s*: Stream
    size: int

# MMDBData methods #

proc hash*(x: MMDBData): Hash =
  var h: Hash = 0
  h = h !& x.kind.ord
  let atomHash = case x.kind
    of mdkPointer:
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
    else:
      0.hash
  h = h !& atomHash
  result = !$h

proc `==`*(a, b: MMDBData): bool =
  a.hash == b.hash

proc `==`*(a: MMDBData; b: uint64): bool =
  assert a.kind == mdkU16 or a.kind == mdkU32 or a.kind == mdkU64
  a.u64Val == b

proc `>`*(a: MMDBData; b: uint64): bool =
  assert a.kind == mdkU16 or a.kind == mdkU32 or a.kind == mdkU64
  a.u64Val > b

proc `==`*(a: MMDBData; b: string): bool =
  assert a.kind == mdkString
  a.stringVal == b

proc toMMDB*(stringVal: string): MMDBData =
  MMDBData(kind: mdkString, stringVal: stringVal)

proc toMMDB*(mapVal: OrderedTable[MMDBData, MMDBData]): MMDBData =
  MMDBData(kind: mdkMap, mapVal: mapVal)

proc toMMDB*(mapVal: openArray[(MMDBData, MMDBData)]): MMDBData =
  MMDBData(kind: mdkMap, mapVal: mapVal.toOrderedTable)

template m*(s: string): MMDBData =
  s.toMMDB

proc `[]`*(x: MMDBData; key: MMDBData): MMDBData =
  if x.kind != mdkMap:
    raise newException(ValueError, "Expected kind " & $mdkMap)
  x.mapVal[key]

proc `[]`*(x: MMDBData; key: string): MMDBData =
  x[key.toMMDB]

proc `$`*(x: MMDBData): string =
  case x.kind
  of mdkPointer:
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
  else:
    $x

# bit and byte helpers #

when system.cpuEndian == bigEndian:
  func beToHost32(outp, inp: pointer) = discard
  func beToHost64(outp, inp: pointer) = discard
else:
  import std/endians
  func beToHost32(outp, inp: pointer) = swapEndian32(outp, inp)
  func beToHost64(outp, inp: pointer) = swapEndian64(outp, inp)

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

proc `+@`[T](p: ptr T; offset: int): ptr T =
  ## Pointer offset
  cast[ptr T](cast[ByteAddress](p) + offset)

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

template readBytes(s: Stream; size: int): string =
  s.readStr(size)

template readByte(s: Stream): uint8 =
  s.readUint8()

proc readNumber(s: Stream; size: int): uint64 =
  for i in countdown(size - 1, 0):
    let n = s.readUint8()
    result = result or (n.uint64 shl (i * 8))

# data decode #

proc readControlByte*(s: Stream): (MMDBDataKind, int) =
  let controlByte = s.readByte()
  var
    dataFormat = controlByte shr 5
    dataSize = (controlByte and 31).int # 0d31 = 0b00011111

  if dataFormat == 0: # extended
    dataFormat = 7 + s.readByte()

  if dataSize == 29:
    dataSize = 29 + s.readByte().int
  elif dataSize == 30:
    dataSize = 285 + s.readNumber(2).int
  elif dataSize == 31:
    dataSize = 65821 + s.readNumber(3).int

  (MMDBDataKind(dataFormat), dataSize)

proc readPointer*(s: Stream; value: int): uint64 =
  let
    # first two bits indicate size
    size = (value and 0b11000) shr 3
    # last three bits are used for the address
    addrPart = (value and 0b00111).uint64
  case size
    of 0:
      (addrPart shl 8) + s.readByte()
    of 1:
      (addrPart shl 16) + s.readNumber(2) + 2048'u64
    of 2:
      (addrPart shl 24) + s.readNumber(3) + 526336'u64
    of 3:
      s.readNumber(4)
    else:
      raise newException(ValueError, "invalid pointer size " & $size)

proc readNode*(s: Stream; bit: uint8; recordSizeBits: uint64): uint64 =
  if recordSizeBits == 24 or recordSizeBits == 32:
    if bit == 1: # right record
      s.setPosition((recordSizeBits shr 3).int, fspCur)
    # else, if left record, we are already in the correct position
    s.readNumber((recordSizeBits shr 3).int)
  elif recordSizeBits == 28:
    let baseOffset = s.getPosition()
    if bit == 1: # right record
      s.setPosition(baseOffset + 4)
    # else, if left record, we are already in the correct position
    let n = s.readNumber(3) # read 3 bytes
    s.setPosition(baseOffset + 3) # go to the middle byte
    let
      middle = s.readNumber(1).uint8 # read the middle byte
      pref =
        if bit == 1: # right record
          middle and 0x0F
        else: # left record
          (middle and 0xF0) shr 4
    n + (pref.uint64 shl 24) # prepend to the 3 bytes
  else:
    raise newException(ValueError, "Unsupported record size " & $recordSizeBits)

proc decode*(mmdb: MMDB): MMDBData

proc decodePointer(mmdb: MMDB; value: int): MMDBData =
  let
    metadata = mmdb.metadata.get
    dataSectionStart = 16 + ((metadata["record_size"].u64Val * 2) shr 3) * metadata["node_count"].u64Val # given formula
    p = readPointer(mmdb.s, value)
    absoluteOffset = dataSectionStart + p
    localPos = mmdb.s.getPosition()

  mmdb.s.setPosition(absoluteOffset.int)
  result = mmdb.decode()

  mmdb.s.setPosition(localPos)

proc decodeString(mmdb: MMDB; size: int): MMDBData =
  result = MMDBData(kind: mdkString)
  result.stringVal = mmdb.s.readStr(size)

proc decodeDouble(mmdb: MMDB; _: int): MMDBData =
  result = MMDBData(kind: mdkDouble)
  var buf: float64
  discard mmdb.s.readData(addr buf, 8)
  beToHost64(addr result.doubleVal, addr buf)

proc decodeBytes(mmdb: MMDB; size: int): MMDBData =
  result = MMDBData(kind: mdkBytes)
  if size == 0:
    result.bytesVal = ""
  else:
    result.bytesVal = mmdb.s.readBytes(size)

proc decodeUInt(mmdb: MMDB; size: int; kind: MMDBDataKind): MMDBData =
  result = MMDBData(kind: kind)
  result.u64Val = mmdb.s.readNumber(size)

proc decodeU128(mmdb: MMDB; size: int): MMDBData =
  result = MMDBData(kind: mdkU128)
  result.u128Val = mmdb.s.readBytes(size)

proc decodeI32(mmdb: MMDB; size: int): MMDBData =
  result = MMDBData(kind: mdkI32)
  var buf: int32
  discard mmdb.s.readData((addr buf) +@ (4 - size), size)
  beToHost32(addr result.i32Val, addr buf)

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
  var buf: float32
  discard mmdb.s.readData(addr buf, 4)
  beToHost32(addr result.floatVal, addr buf)

proc decode*(mmdb: MMDB): MMDBData =
  let (dataKind, dataSize) = mmdb.s.readControlByte()
  result = case dataKind
    of mdkPointer:
      mmdb.decodePointer(dataSize)
    of mdkString:
      mmdb.decodeString(dataSize)
    of mdkDouble:
      mmdb.decodeDouble(dataSize)
    of mdkBytes:
      mmdb.decodeBytes(dataSize)
    of mdkU16, mdkU32, mdkU64:
      mmdb.decodeUInt(dataSize, dataKind)
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
      raise newException(ValueError, "Can't deal with format " & $dataKind)

# metadata #

proc getMetadataPos(mmdb: MMDB): int =
  mmdb.s.rFind(mmdb.size, MetadataMarker) + MetadataMarker.len

proc readMetadata(mmdb: var MMDB) =
  mmdb.s.setPosition(mmdb.getMetadataPos())
  mmdb.metadata = some(mmdb.decode())

template checkMetadataValid(mmdb: MMDB): untyped =
  if mmdb.metadata.isNone:
    raise newException(ValueError, "No database is open.")
  if mmdb.metadata.get.kind != mdkMap:
    raise newException(ValueError, "Invalid metadata; expected " & $mdkMap & ", got " & $mmdb.metadata.get.kind)

# lookup #

proc doLookup(mmdb: MMDB; ipAddr: openArray[uint8]): MMDBData =
  let
    metadata = mmdb.metadata.get
    recordSizeBits: uint64 = metadata["record_size"].u64Val
    nodeSizeBits: uint64 = 2 * recordSizeBits
    nodeCount: uint64 = metadata["node_count"].u64Val
    treeSize: uint64 = (recordSizeBits shr 2) * nodeCount # shl 1, shr 3

  mmdb.s.setPosition(0) # go to root node

  for b in ipAddr:
    for j in 0..<8:
      let
        bit = b.getBit(j)
        recordVal = mmdb.s.readNode(bit, recordSizeBits)
      if recordVal < nodeCount:
        let absoluteOffset = recordVal * (nodeSizeBits shr 3)
        mmdb.s.setPosition(absoluteOffset.int)
      elif recordVal == nodeCount:
        raise newException(KeyError, "IP address does not exist in database")
      else: # recordVal > nodeCount
        let absoluteOffset = (recordVal - nodeCount) + treeSize # given formula
        mmdb.s.setPosition(absoluteOffset.int)
        return mmdb.decode()

proc lookup*(mmdb: MMDB; ipAddr: openArray[uint8]): MMDBData =
  mmdb.checkMetadataValid()
  mmdb.doLookup(ipAddr)

proc lookup*(mmdb: MMDB; ipAddrStr: string): MMDBData =
  mmdb.checkMetadataValid()
  let
    ipVersion = mmdb.metadata.get["ip_version"].u64Val
    ipAddrObj = parseIpAddress(ipAddrStr)
  case ipAddrObj.family
  of IpAddressFamily.IPv6:
    if ipVersion != 6'u64:
      raise newException(ValueError, "Cannot lookup IPv6 address in IPv4 database")
    mmdb.doLookup(ipAddrObj.address_v6)
  of IpAddressFamily.IPv4:
    if ipVersion == 4'u64:
      mmdb.doLookup(ipAddrObj.address_v4)
    else:
      mmdb.doLookup(padIPv4Address(ipAddrObj.address_v4))

# init #

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

proc close*(mmdb: MMDB) =
  mmdb.s.close()


when isMainModule:
  let mmdb = initMMDB("dbip-lite.mmdb")
  echo mmdb.metadata
  let info = mmdb.lookup("1.1.1.1")
  echo info["country"]["names"]["en"], " (", info["country"]["iso_code"], ")"
