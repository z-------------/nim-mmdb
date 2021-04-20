#
# Decoder tests
# Test data taken from https://github.com/maxmind/MaxMind-DB-Reader-python/blob/968142fb5cf52473bdbcddb05ccff407820a2fa1/tests/decoder_test.py
#

import unittest
import mmdb
import streams

test "array":
  let datas = {
    "\x00\x04": @[],
    "\x01\x04\x43\x46\x6f\x6f": @["Foo"],
    "\x02\x04\x43\x46\x6f\x6f\x43\xe4\xba\xba": @["Foo", "人"],
  }
  for _, (k, v) in datas:
    let decoded = decode(newStringStream(k))
    check decoded.kind == mdkArray
    for i in 0..decoded.arrayVal.high:
      check decoded.arrayVal[i] == v[i].toMMDB()

test "boolean":
  let datas = {
    "\x00\x07": false,
    "\x01\x07": true,
  }
  for _, (k, expected) in datas:
    let decoded = decode(newStringStream(k))
    check decoded.kind == mdkBoolean
    check decoded.booleanVal == expected

test "double":
  let datas = {
    "\x68\x00\x00\x00\x00\x00\x00\x00\x00": 0.0,
    "\x68\x3F\xE0\x00\x00\x00\x00\x00\x00": 0.5,
    "\x68\x40\x09\x21\xFB\x54\x44\x2E\xEA": 3.14159265359,
    "\x68\x40\x5E\xC0\x00\x00\x00\x00\x00": 123.0,
    "\x68\x41\xD0\x00\x00\x00\x07\xF8\xF4": 1073741824.12457,
    "\x68\xBF\xE0\x00\x00\x00\x00\x00\x00": -0.5,
    "\x68\xC0\x09\x21\xFB\x54\x44\x2E\xEA": -3.14159265359,
    "\x68\xC1\xD0\x00\x00\x00\x07\xF8\xF4": -1073741824.12457,
  }
  for _, (k, expected) in datas:
    let decoded = decode(newStringStream(k))
    check decoded.kind == mdkDouble
    check abs(decoded.doubleVal - expected) < 0.00001

test "float":
  let datas = {
    "\x04\x08\x00\x00\x00\x00": 0.0,
    "\x04\x08\x3F\x80\x00\x00": 1.0,
    "\x04\x08\x3F\x8C\xCC\xCD": 1.1,
    "\x04\x08\x40\x48\xF5\xC3": 3.14,
    "\x04\x08\x46\x1C\x3F\xF6": 9999.99,
    "\x04\x08\xBF\x80\x00\x00": -1.0,
    "\x04\x08\xBF\x8C\xCC\xCD": -1.1,
    "\x04\x08\xC0\x48\xF5\xC3": -3.14,
    "\x04\x08\xC6\x1C\x3F\xF6": -9999.99,
  }
  for _, (k, expected) in datas:
    let decoded = decode(newStringStream(k))
    check decoded.kind == mdkFloat
    check abs(decoded.floatVal - expected) < 0.001

test "int32":
  let datas = {
    "\x00\x01": 0,
    "\x04\x01\xff\xff\xff\xff": -1,
    "\x01\x01\xff": 255,
    "\x04\x01\xff\xff\xff\x01": -255,
    "\x02\x01\x01\xf4": 500,
    "\x04\x01\xff\xff\xfe\x0c": -500,
    "\x02\x01\xff\xff": 65535,
    "\x04\x01\xff\xff\x00\x01": -65535,
    "\x03\x01\xff\xff\xff": 16777215,
    "\x04\x01\xff\x00\x00\x01": -16777215,
    "\x04\x01\x7f\xff\xff\xff": 2147483647,
    "\x04\x01\x80\x00\x00\x01": -2147483647,
  }
  for _, (k, expected) in datas:
    let decoded = decode(newStringStream(k))
    check decoded.kind == mdkI32
    check decoded.i32Val == expected

test "uint16":
  let datas = {
    "\xa0": 0'u16,
    "\xa1\xff": 255'u16,
    "\xa2\x01\xf4": 500'u16,
    "\xa2\x2a\x78": 10872'u16,
    "\xa2\xff\xff": 65535'u16,
  }
  for _, (k, expected) in datas:
    let decoded = decode(newStringStream(k))
    check decoded.kind == mdkU16
    check decoded.u64Val == expected

test "uint32":
  let datas = {
    "\xc0": 0'u32,
    "\xc1\xff": 255'u32,
    "\xc2\x01\xf4": 500'u32,
    "\xc2\x2a\x78": 10872'u32,
    "\xc2\xff\xff": 65535'u32,
    "\xc3\xff\xff\xff": 16777215'u32,
    "\xc4\xff\xff\xff\xff": 4294967295'u32,
  }
  for _, (k, expected) in datas:
    let decoded = decode(newStringStream(k))
    check decoded.kind == mdkU32
    check decoded.u64Val == expected
