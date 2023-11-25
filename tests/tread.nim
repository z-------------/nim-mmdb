#
# Reader tests
# Test cases taken from https://github.com/maxmind/MaxMind-DB-Reader-python/blob/968142fb5cf52473bdbcddb05ccff407820a2fa1/tests/reader_test.py
#

import unittest
import mmdb

import math
# import streams
# import strutils
import tables

template checkDoubleEqual(a, b: float64): untyped =
  check abs(a - b) < 0.000001

template checkFloatEqual(a, b: float32): untyped =
  check abs(a - b) < 0.00001

proc checkRecordEqual(a, b: MMDBData) =
  check a.kind == b.kind
  case a.kind
  of mdkMap:
    for k, v in a.mapVal.pairs:
      checkRecordEqual v, b[k]
  of mdkDouble:
    checkDoubleEqual a.doubleVal, b.doubleVal
  of mdkFloat:
    checkFloatEqual a.floatVal, b.floatVal
  else:
    check a == b

template checkMetadata(db: MMDB; ipVersion: uint16, recordSizeBits: uint16): untyped =
  let metadata = db.metadata.get
  check metadata["binary_format_major_version"] == 2'u64
  check metadata["binary_format_minor_version"] == 0'u64
  check metadata["build_epoch"] > 1373571901'u64
  check metadata["database_type"] == "Test"
  check metadata["description"] == {m"en": m"Test Database", m"zh": m"Test Database Chinese"}.toMMDB
  check metadata["ip_version"] == ipVersion
  check metadata["languages"] == MMDBData(kind: mdkArray, arrayVal: @[m"en", m"zh"])
  check metadata["node_count"] > 36'u32
  check metadata["record_size"].u64Val == recordSizeBits

template checkIPv4(db: MMDB) =
  for i in 0..<6:
    let address = "1.1.1." & $(2 ^ i)
    check db.lookup(address) == {m"ip": m(address)}.toMMDB
  
  let pairs = {
    "1.1.1.3": "1.1.1.2",
    "1.1.1.5": "1.1.1.4",
    "1.1.1.7": "1.1.1.4",
    "1.1.1.9": "1.1.1.8",
    "1.1.1.15": "1.1.1.8",
    "1.1.1.17": "1.1.1.16",
    "1.1.1.31": "1.1.1.16",
  }
  for _, (keyAddr, valueAddr) in pairs:
    check db.lookup(keyAddr) == {m"ip": m(valueAddr)}.toMMDB
  
  for ip in ["1.1.1.33", "255.254.253.123"]:
    expect KeyError:
      discard db.lookup(ip)

template checkIPv6(db: MMDB) =
  let subnets = ["::1:ffff:ffff", "::2:0:0", "::2:0:40", "::2:0:50", "::2:0:58"]
  for address in subnets:
    check db.lookup(address) == {m"ip": m(address)}.toMMDB
  
  let pairs = {
      "::2:0:1": "::2:0:0",
      "::2:0:33": "::2:0:0",
      "::2:0:39": "::2:0:0",
      "::2:0:41": "::2:0:40",
      "::2:0:49": "::2:0:40",
      "::2:0:52": "::2:0:50",
      "::2:0:57": "::2:0:50",
      "::2:0:59": "::2:0:58",
  }
  for _, (keyAddr, valueAddr) in pairs:
    check db.lookup(keyAddr) == {m"ip": m(valueAddr)}.toMMDB

  for ip in ["1.1.1.33", "255.254.253.123", "89fa::"]:
    expect KeyError:
      discard db.lookup(ip)

test "reader 1":
  for recordSizeBits in [24'u16, 28'u16, 32'u16]:
    for ipVersion in [4'u16, 6'u16]:
      let filename =
        "tests/data/test-data/MaxMind-DB-test-ipv" & $ipVersion &
        "-" &
        $recordSizeBits &
        ".mmdb"

      var db = initMMDB(filename)
      checkMetadata(db, ipVersion, recordSizeBits)

      if ipVersion == 4'u16:
        checkIPv4(db)
      else:
        checkIPv6(db)
      
      db.close()

let decoderRecord = {
  m"array": MMDBData(kind: mdkArray, arrayVal: @[
    MMDBData(kind: mdkU32, u64Val: 1),
    MMDBData(kind: mdkU32, u64Val: 2),
    MMDBData(kind: mdkU32, u64Val: 3),
  ]),
  m"boolean": MMDBData(kind: mdkBoolean, booleanVal: true),
  m"bytes": MMDBData(kind: mdkBytes, bytesVal: "\x00\x00\x00*"),
  m"double": MMDBData(kind: mdkDouble, doubleVal: 42.123456),
  m"float": MMDBData(kind: mdkFloat, floatVal: 1.1),
  m"int32": MMDBData(kind: mdkI32, i32Val: -268435456),
  m"map": {
    m"mapX": {
      m"arrayX": MMDBData(kind: mdkArray, arrayVal: @[
        MMDBData(kind: mdkU32, u64Val: 7),
        MMDBData(kind: mdkU32, u64Val: 8),
        MMDBData(kind: mdkU32, u64Val: 9),
      ]),
      m"utf8_stringX": m"hello"
    }.toMMDB
  }.toMMDB,
  m"uint16": MMDBData(kind: mdkU16, u64Val: 100'u16),
  m"uint32": MMDBData(kind: mdkU32, u64Val: 268435456'u32),
  m"uint64": MMDBData(kind: mdkU64, u64Val: 1152921504606846976'u64),
  m"uint128": MMDBData(kind: mdkU128, u128Val: "\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"), # 1329227995784915872903807060280344576
  m"utf8_string": MMDBData(kind: mdkString, stringVal: "unicode! ☯ - ♫"),
}.toMMDB

test "reader 2":
  let tests = @[
    (
      ip: "1.1.1.1",
      fileName: "MaxMind-DB-test-ipv6-32.mmdb",
      expectedPrefixLen: 8,
      expectedRecord: MMDBData(kind: mdkNone),
    ),
    (
      ip: "::1:ffff:ffff",
      fileName: "MaxMind-DB-test-ipv6-24.mmdb",
      expectedPrefixLen: 128,
      expectedRecord: {m"ip": m"::1:ffff:ffff"}.toMMDB,
    ),
    (
      ip: "::2:0:1",
      fileName: "MaxMind-DB-test-ipv6-24.mmdb",
      expectedPrefixLen: 122,
      expectedRecord: {m"ip": m"::2:0:0"}.toMMDB,
    ),
    (
      ip: "1.1.1.1",
      fileName: "MaxMind-DB-test-ipv4-24.mmdb",
      expectedPrefixLen: 32,
      expectedRecord: {m"ip": m"1.1.1.1"}.toMMDB,
    ),
    (
      ip: "1.1.1.3",
      fileName: "MaxMind-DB-test-ipv4-24.mmdb",
      expectedPrefixLen: 31,
      expectedRecord: {m"ip": m"1.1.1.2"}.toMMDB,
    ),
    (
      ip: "1.1.1.3",
      file_name: "MaxMind-DB-test-decoder.mmdb",
      expectedPrefixLen: 24,
      expectedRecord: decoderRecord,
    ),
    (
      ip: "::ffff:1.1.1.128",
      fileName: "MaxMind-DB-test-decoder.mmdb",
      expectedPrefixLen: 120,
      expectedRecord: decoderRecord,
    ),
    (
      ip: "::1.1.1.128",
      fileName: "MaxMind-DB-test-decoder.mmdb",
      expectedPrefixLen: 120,
      expectedRecord: decoderRecord,
    ),
    # (
    #   ip: "200.0.2.1",
    #   fileName: "MaxMind-DB-no-ipv4-search-tree.mmdb",
    #   expectedPrefixLen: 0,
    #   expectedRecord: m"::0/64",
    # ),
    # (
    #   ip: "::200.0.2.1",
    #   fileName: "MaxMind-DB-no-ipv4-search-tree.mmdb",
    #   expectedPrefixLen: 64,
    #   expectedRecord: m"::0/64",
    # ),
    # (
    #   ip: "0:0:0:0:ffff:ffff:ffff:ffff",
    #   fileName: "MaxMind-DB-no-ipv4-search-tree.mmdb",
    #   expectedPrefixLen: 64,
    #   expectedRecord: m"::0/64",
    # ),
    # (
    #   ip: "ef00::",
    #   fileName: "MaxMind-DB-no-ipv4-search-tree.mmdb",
    #   expectedPrefixLen: 1,
    #   expectedRecord: MMDBData(kind: mdkNone),
    # ),
  ]
  for test in tests:
    let db = initMMDB("tests/data/test-data/" & test.fileName)

    try:
      let record = db.lookup(test.ip)
      checkRecordEqual record, test.expectedRecord
    except KeyError:
      check test.expectedRecord.kind == mdkNone

    db.close()

test "decoder":
  let filename = "tests/data/test-data/MaxMind-DB-test-decoder.mmdb"
  var db = initMMDB(filename)
  let record = db.lookup("::1.1.1.0")

  checkRecordEqual record, decoderRecord

  db.close()

# test "no IPv4 search tree":
#   let filename = "tests/data/test-data/MaxMind-DB-no-ipv4-search-tree.mmdb"
#   var db = initMMDB(filename)

#   check db.lookup("1.1.1.1") == "::0/64"
#   check db.lookup("192.1.1.1") == "::0/64"

#   db.close()

test "IPv6 address in IPv4 database":
  let filename = "tests/data/test-data/MaxMind-DB-test-ipv4-24.mmdb"
  var db = initMMDB(filename)

  expect ValueError:
    discard db.lookup("2001::")

  db.close()

test "missing database":
  expect IOError:
    let filename = "file-does-not-exist.mmdb"
    discard initMMDB(filename)
