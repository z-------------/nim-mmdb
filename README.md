
# API: mmdb

```nim
import mmdb
```

## **type** MMDBDataKind


```nim
MMDBDataKind = enum
 mdkNone, mdkPointer = 1, mdkString = 2, mdkDouble = 3, mdkBytes = 4, mdkU16 = 5, mdkU32 = 6, mdkMap = 7, mdkI32 = 8, mdkU64 = 9, mdkU128 = 10, mdkArray = 11, mdkInvalid12, mdkInvalid13, mdkBoolean = 14, mdkFloat = 15
```

## **type** MMDBData


```nim
MMDBData = object
 case kind*: MMDBDataKind
 of mdkString:
 stringVal*: string

 of mdkDouble:
 doubleVal*: float64

 of mdkBytes:
 bytesVal*: string

 of mdkU16, mdkU32, mdkU64:
 u64Val*: uint64

 of mdkU128:
 u128Val*: string

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

 of mdkPointer, mdkNone, mdkInvalid12, mdkInvalid13:
 nil
```

## **type** MMDB


```nim
MMDB = object
 metadata*: Option[MMDBData]
 s*: Stream
 size: int
 recordSizeBits: uint64
 nodeSizeBits: uint64
 nodeCount: uint64
 treeSize: uint64
 dataSectionStart: uint64
```

## **proc** hash


```nim
proc hash(x: MMDBData): Hash
```

## **proc** `==`


```nim
proc `==`(a, b: MMDBData): bool
```

## **proc** `==`


```nim
proc `==`(a: MMDBData; b: uint64): bool
```

## **proc** `>`


```nim
proc `>`(a: MMDBData; b: uint64): bool
```

## **proc** `==`


```nim
proc `==`(a: MMDBData; b: string): bool
```

## **proc** toMMDB


```nim
proc toMMDB(stringVal: string): MMDBData
```

## **proc** toMMDB


```nim
proc toMMDB(mapVal: OrderedTable[MMDBData, MMDBData]): MMDBData
```

## **proc** toMMDB


```nim
proc toMMDB(mapVal: openArray[(MMDBData, MMDBData)]): MMDBData
```

## **template** m


```nim
template m(s: string): MMDBData
```

## **proc** `[]`


```nim
proc `[]`(x: MMDBData; key: MMDBData): MMDBData {.raises: [ValueError, KeyError].}
```

## **proc** `[]`


```nim
proc `[]`(x: MMDBData; key: string): MMDBData {.raises: [ValueError, KeyError], tags: [].}
```

## **proc** `$`


```nim
proc `$`(x: MMDBData): string
```

## **proc** readControlByte


```nim
proc readControlByte(s: Stream): (MMDBDataKind, int) {.raises: [IOError, OSError], tags: [ReadIOEffect].}
```

## **proc** readPointer


```nim
proc readPointer(s: Stream; value: int): uint64 {.raises: [IOError, OSError, ValueError], tags: [ReadIOEffect].}
```

## **proc** readNode


```nim
proc readNode(s: Stream; bit: uint8; recordSizeBits: uint64): uint64 {.raises: [IOError, OSError, ValueError], tags: [ReadIOEffect].}
```

## **proc** decode


```nim
proc decode(mmdb: MMDB): MMDBData {.raises: [IOError, OSError, ValueError, Exception], tags: [ReadIOEffect, RootEffect].}
```

## **proc** lookup


```nim
proc lookup(mmdb: MMDB; ipAddr: openArray[uint8]): MMDBData {.raises: [ValueError, IOError, OSError, KeyError, Exception], tags: [ReadIOEffect, RootEffect].}
```

## **proc** lookup


```nim
proc lookup(mmdb: MMDB; ipAddrStr: string): MMDBData {.raises: [ValueError, KeyError, IOError, OSError, Exception], tags: [ReadIOEffect, RootEffect].}
```

## **proc** openFile


```nim
proc openFile(mmdb: var MMDB; stream: Stream) {.raises: [IOError, OSError, ValueError, Exception, KeyError], tags: [ReadIOEffect, RootEffect].}
```

## **proc** openFile


```nim
proc openFile(mmdb: var MMDB; file: File) {.raises: [IOError, OSError, ValueError, Exception, KeyError], tags: [ReadIOEffect, RootEffect].}
```

## **proc** openFile


```nim
proc openFile(mmdb: var MMDB; filename: string) {.raises: [IOError, OSError, ValueError, Exception, KeyError], tags: [ReadIOEffect, RootEffect].}
```

## **proc** initMMDB


```nim
proc initMMDB(filename: string): MMDB {.raises: [IOError, OSError, ValueError, Exception, KeyError], tags: [ReadIOEffect, RootEffect].}
```

## **proc** initMMDB


```nim
proc initMMDB(file: File): MMDB {.raises: [IOError, OSError, ValueError, Exception, KeyError], tags: [ReadIOEffect, RootEffect].}
```

## **proc** close


```nim
proc close(mmdb: MMDB) {.raises: [Exception, IOError, OSError], tags: [WriteIOEffect].}
```
