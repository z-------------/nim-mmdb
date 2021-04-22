#
# Reader tests
# Test cases taken from https://github.com/maxmind/MaxMind-DB-Reader-python/blob/968142fb5cf52473bdbcddb05ccff407820a2fa1/tests/reader_test.py
#

import unittest
import mmdb

import math
# import streams
# import strutils
# import tables

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

test "reader":
  for recordSizeBits in [24'u16, #[28'u16,]# 32'u16]:
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
