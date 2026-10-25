/// Edge TTS `Sec-MS-GEC` v2 令牌生成。
///
/// 2025 年起微软把 Edge 朗读接口的 DRM 从 v1（时间串 + 客户端令牌的
/// 纯 SHA-256）升级为 v2 组合摘要：`<CS64 16hex>-<SHA-256 64hex>`，
/// 请求还需附带随机 `MUID` Cookie。算法步骤基于社区公开逆向结论
/// （rany2/edge-tts issue #290 及后续），本文件为 Dart 独立实现：
/// - CS64：自定义 32 位字乘 + 16 位旋转混合原语；
/// - SHA-256：标准压缩函数的定制版本（预置中途状态/调度表魔数，
///   对 token 前缀跳过前 14 轮）；
/// - 时间戳：Unix 秒 + 1601 纪元偏移，**向下取整**到 300 秒窗口后
///   换算为 100ns tick（全整数路径，避免浮点取整歧义）。
///
/// 32 位语义：Dart int 为 64 位补码；所有 Python 的无符号右移译作
/// `>>>`，环加法在 mod 2^64 下与任意精度加法的低位结果一致。
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

const int _u32Mask = 0xFFFFFFFF;

const int _winEpoch = 11644473600;
const int _rounding = 300;
const String kEdgeTrustedClientToken =
    '6A5AA1D4EAFF4E9FB37E23D68491D6F4';

// ── 定制 SHA-256 魔数（FIPS 180-4 标准值 + 逆向得到的调度/调整值） ──

const List<int> _sha256Initial = <int>[
  0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A,
  0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
];

const List<int> _sha256State = <int>[
  0xFD9FBEA2, 0x91243CE7, 0xBE499094, 0xCD2E1E0A,
  0x6C006F49, 0x04BD35AB, 0xFEB0A7E4, 0x03EFFBD2,
];

const List<int> _sha256Schedule = <int>[
  0xEB24BF9E, 0x1558691F, 0xA0C09EE2, 0x0CFA32BA,
  0xA622EE8C, 0xD1DD9491, 0xC0DD25A0, 0xF9E70AB6,
  0xF0C31573, 0x7058CE4E, 0x7188E606, 0x00E5AB33,
  0xD258B060, 0x72766564,
];

const List<int> _sha256RoundConstants = <int>[
  0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5,
  0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
  0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
  0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
  0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC,
  0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
  0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7,
  0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
  0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
  0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
  0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3,
  0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
  0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5,
  0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
  0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
  0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
];

const int _sha256Adjustment = 0xC9DC06A7;
const int _sha256Sigma0Adjustment = 0x059C0B80;
const int _sha256Sigma1Adjustment = 0x000B92C0;

const List<int> _cs64CoefficientsHi = <int>[
  0xE82E91B1, 0x44DE24C6, 0x3BEB65BC, 0xC89C5933,
  0x8D1EC211, 0x314EF5D5, 0xE92491B1, 0xF0A5B9D5,
  0x06064CF3, 0xDA79FA60, 0xBED20560, 0x89F9C9F8,
  0x35FA38C6, 0xCB49E3C6,
];
const List<int> _cs64CoefficientsLo = <int>[
  0xB32700D0, 0x88DFF51D, 0x29514038, 0xB328CBDF,
  0xD405B4D5, 0x26E55F3C, 0x607801C6, 0x82B2C1FB,
  0xFA51A3DA, 0x207CC464, 0x3C3C74F3, 0xD2D14B61,
  0xBB04A2C1, 0xC5626167,
];
const int _cs64Factor = 0x82893933;
const int _cs64Adjustment0 = 0xF2F90B1A;
const int _cs64Adjustment1 = 0x0B1A0000;

int _rol16(int v) {
  v &= _u32Mask;
  return ((v << 16) | (v >>> 16)) & _u32Mask;
}

/// 定制 sigma（移位项先不 mask，求和后统一取低 32 位，与环运算兼容）。
int _sigma0(int v) =>
    (v >>> 7) ^ (v << 25) ^ (v >>> 18) ^ (v << 14) ^ (v >>> 3);

int _sigma1(int v) =>
    (v >>> 17) ^ (v << 15) ^ (v >>> 19) ^ (v << 13) ^ (v >>> 10);

/// 数据按小端 u32 分字（右侧零填充至偶数个字）。
List<int> _wordsLe4Even(List<int> data) {
  final padded = List<int>.of(data)..addAll(
      List<int>.filled((-data.length) % 4, 0));
  if (padded.isEmpty) return <int>[];
  final words = <int>[];
  for (var i = 0; i < padded.length; i += 4) {
    words.add(padded[i] |
        (padded[i + 1] << 8) |
        (padded[i + 2] << 16) |
        (padded[i + 3] << 24));
  }
  if (words.length.isOdd) words.add(0);
  return words;
}

List<int> _sha256Rounds(List<int> state, List<int> words,
    [int firstRound = 0]) {
  var a = state[0], b = state[1], c = state[2], d = state[3];
  var e = state[4], f = state[5], g = state[6], h = state[7];
  final constants = firstRound == 14
      ? <int>[
          ..._sha256RoundConstants.sublist(0, 14),
          _sha256Adjustment,
          ..._sha256RoundConstants.sublist(15),
        ]
      : _sha256RoundConstants;

  int dup(int v) => (v << 32) | v;

  final aligned = math.min(64, ((firstRound + 7) ~/ 8) * 8);
  // 对齐前的轮次：逐轮推进。
  for (var i = firstRound; i < aligned; i++) {
    final re = dup(e), ra = dup(a);
    final t1 = h +
        ((re >>> 6) ^ (re >>> 11) ^ (re >>> 25)) +
        (g ^ (e & (f ^ g))) +
        constants[i] +
        words[i];
    final t2 = ((ra >>> 2) ^ (ra >>> 13) ^ (ra >>> 22)) +
        ((a & b) | (c & (a | b)));
    final na = (t1 + t2) & _u32Mask;
    h = g; g = f; f = e;
    e = (d + t1) & _u32Mask;
    d = c; c = b; b = a; a = na;
  }
  // 对齐后的轮次：8 轮一组展开推进。
  for (var idx = aligned; idx < 64; idx += 8) {
    final re = dup(e), ra = dup(a);
    var t1 = h +
        ((re >>> 6) ^ (re >>> 11) ^ (re >>> 25)) +
        (g ^ (e & (f ^ g))) +
        constants[idx] +
        words[idx];
    var t2 = ((ra >>> 2) ^ (ra >>> 13) ^ (ra >>> 22)) +
        ((a & b) | (c & (a | b)));
    d = (d + t1) & _u32Mask;
    h = (t1 + t2) & _u32Mask;
    final rd = dup(d), rh = dup(h);
    t1 = g +
        ((rd >>> 6) ^ (rd >>> 11) ^ (rd >>> 25)) +
        (f ^ (d & (e ^ f))) +
        constants[idx + 1] +
        words[idx + 1];
    t2 = ((rh >>> 2) ^ (rh >>> 13) ^ (rh >>> 22)) +
        ((h & a) | (b & (h | a)));
    c = (c + t1) & _u32Mask;
    g = (t1 + t2) & _u32Mask;
    final rc = dup(c), rg = dup(g);
    t1 = f +
        ((rc >>> 6) ^ (rc >>> 11) ^ (rc >>> 25)) +
        (e ^ (c & (d ^ e))) +
        constants[idx + 2] +
        words[idx + 2];
    t2 = ((rg >>> 2) ^ (rg >>> 13) ^ (rg >>> 22)) +
        ((g & h) | (a & (g | h)));
    b = (b + t1) & _u32Mask;
    f = (t1 + t2) & _u32Mask;
    final rb = dup(b), rf = dup(f);
    t1 = e +
        ((rb >>> 6) ^ (rb >>> 11) ^ (rb >>> 25)) +
        (d ^ (b & (c ^ d))) +
        constants[idx + 3] +
        words[idx + 3];
    t2 = ((rf >>> 2) ^ (rf >>> 13) ^ (rf >>> 22)) +
        ((f & g) | (h & (f | g)));
    a = (a + t1) & _u32Mask;
    e = (t1 + t2) & _u32Mask;
    final ra2 = dup(a), re2 = dup(e);
    t1 = d +
        ((ra2 >>> 6) ^ (ra2 >>> 11) ^ (ra2 >>> 25)) +
        (c ^ (a & (b ^ c))) +
        constants[idx + 4] +
        words[idx + 4];
    t2 = ((re2 >>> 2) ^ (re2 >>> 13) ^ (re2 >>> 22)) +
        ((e & f) | (g & (e | f)));
    h = (h + t1) & _u32Mask;
    d = (t1 + t2) & _u32Mask;
    final rh2 = dup(h), rd2 = dup(d);
    t1 = c +
        ((rh2 >>> 6) ^ (rh2 >>> 11) ^ (rh2 >>> 25)) +
        (b ^ (h & (a ^ b))) +
        constants[idx + 5] +
        words[idx + 5];
    t2 = ((rd2 >>> 2) ^ (rd2 >>> 13) ^ (rd2 >>> 22)) +
        ((d & e) | (f & (d | e)));
    g = (g + t1) & _u32Mask;
    c = (t1 + t2) & _u32Mask;
    final rg2 = dup(g), rc2 = dup(c);
    t1 = b +
        ((rg2 >>> 6) ^ (rg2 >>> 11) ^ (rg2 >>> 25)) +
        (a ^ (g & (h ^ a))) +
        constants[idx + 6] +
        words[idx + 6];
    t2 = ((rc2 >>> 2) ^ (rc2 >>> 13) ^ (rc2 >>> 22)) +
        ((c & d) | (e & (c | d)));
    f = (f + t1) & _u32Mask;
    b = (t1 + t2) & _u32Mask;
    final rf2 = dup(f), rb2 = dup(b);
    t1 = a +
        ((rf2 >>> 6) ^ (rf2 >>> 11) ^ (rf2 >>> 25)) +
        (h ^ (f & (g ^ h))) +
        constants[idx + 7] +
        words[idx + 7];
    t2 = ((rb2 >>> 2) ^ (rb2 >>> 13) ^ (rb2 >>> 22)) +
        ((b & c) | (d & (b | c)));
    e = (e + t1) & _u32Mask;
    a = (t1 + t2) & _u32Mask;
  }
  return <int>[a, b, c, d, e, f, g, h];
}

void _expandSha256Schedule(List<int> words, [int firstWord = 16]) {
  for (var i = firstWord; i < 64; i++) {
    final x = words[i - 2], y = words[i - 15];
    final s1 = (x >>> 17) ^ (x << 15) ^ (x >>> 19) ^ (x << 13) ^ (x >>> 10);
    final s0 = (y >>> 7) ^ (y << 25) ^ (y >>> 18) ^ (y << 14) ^ (y >>> 3);
    words.add((s1 + words[i - 7] + s0 + words[i - 16]) & _u32Mask);
  }
}

/// 计算 token 前缀（前 7 字节）对应的定制 SHA-256 中途状态。
List<int> _sha256InitCached(Uint8List prefix) {
  final data = prefix;
  final words = <int>[
    ...List<int>.filled(14, 0),
    (data[0] << 16) | (data[1] << 8) | data[2],
    (data[3] << 24) | (data[4] << 16) | (data[5] << 8) | data[6],
  ];
  for (var i = 16; i < 30; i++) {
    var value = _sha256Schedule[i - 16];
    if (i - 2 >= 14) {
      value += i == 16
          ? (_sigma1(words[i - 2]) ^ _sha256Sigma1Adjustment)
          : _sigma1(words[i - 2]);
    }
    if (i - 7 >= 14) {
      value += words[i - 7];
    }
    if (i - 15 >= 14) {
      value += i == 29
          ? (_sigma0(words[i - 15]) ^ _sha256Sigma0Adjustment)
          : _sigma0(words[i - 15]);
    }
    words.add(value & _u32Mask);
  }
  words.add((_sigma1(words[28]) +
          words[23] +
          _sigma0(words[15]) +
          words[14] +
          _sha256Adjustment -
          _sha256RoundConstants[14]) &
      _u32Mask);
  _expandSha256Schedule(words, 31);
  final working = _sha256Rounds(_sha256State, words, 14);
  return <int>[
    for (var i = 0; i < 8; i++)
      (_sha256Initial[i] + working[i]) & _u32Mask,
  ];
}

Uint8List _sha256Digest(Uint8List data) {
  if (data.length < 7) {
    throw ArgumentError('token 数据至少 7 字节');
  }
  final length = 57 + data.length;
  final tail = <int>[
    ...data.sublist(7),
    0x80,
    ...List<int>.filled((55 - length) % 64, 0),
  ];
  final bitLen = length * 8;
  final padded = Uint8List.fromList(<int>[
    ...tail,
    (bitLen >>> 56) & 0xFF,
    (bitLen >>> 48) & 0xFF,
    (bitLen >>> 40) & 0xFF,
    (bitLen >>> 32) & 0xFF,
    (bitLen >>> 24) & 0xFF,
    (bitLen >>> 16) & 0xFF,
    (bitLen >>> 8) & 0xFF,
    bitLen & 0xFF,
  ]);
  final init = _sha256InitCached(data.sublist(0, 7));
  var state = List<int>.of(init);
  final byteData = ByteData.view(padded.buffer);
  for (var offset = 0; offset < padded.length; offset += 64) {
    final words = <int>[
      for (var w = 0; w < 16; w++) byteData.getUint32(offset + w * 4),
    ];
    _expandSha256Schedule(words);
    final working = _sha256Rounds(state, words);
    state = <int>[
      for (var i = 0; i < 8; i++) (state[i] + working[i]) & _u32Mask,
    ];
  }
  final out = ByteData(32);
  for (var i = 0; i < 8; i++) {
    out.setUint32(i * 4, state[i]);
  }
  return out.buffer.asUint8List();
}

/// CS64 摘要（两个 32 位字，小端拼 hex）。
(int, int) _cs64Digest(Uint8List data, Uint8List digest) {
  var keyA = digest.byteData.getUint32(0, Endian.little) | 1;
  var keyB = digest.byteData.getUint32(4, Endian.little) | 1;
  final fA = (keyA * _cs64Factor) & _u32Mask;
  final fB = (keyB * _cs64Factor) & _u32Mask;
  final terms = <int>[
    for (var i = 0; i < _cs64CoefficientsHi.length; i++)
      (_cs64CoefficientsHi[i] * (i.isEven ? fA : fB)) & _u32Mask,
  ];
  final offsets = <int>[..._cs64CoefficientsLo];
  final stream = _wordsLe4Even(<int>[0, ...data]);
  for (var i = 0; i < stream.length; i++) {
    final word = stream[i];
    var term = word * (i.isEven ? keyA : keyB);
    var offset = _rol16(word) * (i.isEven ? 0xEF0569FB : 0xC31713DB);
    if (i == 0) {
      term += _cs64Adjustment0 * fA;
      offset += _cs64Adjustment1;
    }
    terms.add(term & _u32Mask);
    offsets.add(offset & _u32Mask);
  }
  var swapAcc = 0, swapLast = 0, state = 0, acc = 0;
  for (var i = 0; i < terms.length; i += 2) {
    final x = terms[i], y = terms[i + 1];
    var t = _rol16((offsets[i] + x) & _u32Mask);
    var q = (t * 0x76F50F34) & _u32Mask;
    swapAcc += (_rol16(q) * 0xC3EFEA97 + q) & _u32Mask;
    t = _rol16((offsets[i + 1] + y) & _u32Mask);
    q = (t * 0x1881CE3C) & _u32Mask;
    swapLast = (_rol16(q) * 0x35BD1EC9 + q) & _u32Mask;
    swapAcc = (swapAcc + swapLast) & _u32Mask;

    state = (state * keyA + x) & _u32Mask;
    state = (_rol16(state) * 0xCF98B111) & _u32Mask;
    state = (_rol16(state) * 0x87085B9F) & _u32Mask;
    state = (_rol16(state) * 0x12CEB96D) & _u32Mask;
    state = (_rol16(state) * 0x257E1D83) & _u32Mask;
    acc += state;
    var u = (state * keyB + y) & _u32Mask;
    u = (_rol16(u) * 0xA27416F5) & _u32Mask;
    u = (_rol16(u) * 0xD38396FF) & _u32Mask;
    state = ((_rol16(_rol16(u) * 0x7C932B89) & _u32Mask) *
            0xBFA49F69) &
        _u32Mask;
    acc = (acc + state) & _u32Mask;
  }
  return (swapLast ^ state, swapAcc ^ acc);
}

(String cs64, String sha256) _tokenHash(Uint8List data) {
  final digest = _sha256Digest(data);
  final (csA, csB) = _cs64Digest(data, digest);
  final csBytes = ByteData(8)
    ..setUint32(0, csA, Endian.little)
    ..setUint32(4, csB, Endian.little);
  return (
    _hexUpper(csBytes.buffer.asUint8List()),
    _hexUpper(digest),
  );
}

String _hexUpper(List<int> bytes) => bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0'))
    .join()
    .toUpperCase();

/// 生成 v2 Sec-MS-GEC 令牌：`<CS64 16hex>-<SHA-256 64hex>`。
///
/// [unixTimestampMs] 缺省用当前时间（测试可注入）。
///
/// tick 换算刻意走 float64：参照实现以 double 乘 10^7 后取「该浮点的
/// 精确整数值」入串（带浮点噪声尾数，如 `…00000512`），服务端以同样
/// 方式校验——整数精确乘法反而会令牌不匹配。Dart double 与 Python
/// float 同为 IEEE 754 双精度，`BigInt.from` 给出同样的精确整数。
String generateEdgeSecMsGecV2({int? unixTimestampMs}) {
  final ms = unixTimestampMs ?? DateTime.now().millisecondsSinceEpoch;
  var windowed = ms ~/ 1000 + _winEpoch;
  windowed -= windowed % _rounding; // 向下取整到 300 秒窗口
  final ticks = windowed.toDouble() * 1e7;
  final strToHash =
      utf8.encode('${BigInt.from(ticks)}$kEdgeTrustedClientToken');
  final (cs64, sha) = _tokenHash(Uint8List.fromList(strToHash));
  return '$cs64-$sha';
}

/// 随机 MUID Cookie 值（32 位大写 hex）。
String generateEdgeMuid() {
  final rnd = math.Random.secure();
  return List<int>.generate(16, (_) => rnd.nextInt(256))
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
}

extension _ByteDataX on Uint8List {
  ByteData get byteData => ByteData.view(buffer, offsetInBytes, length);
}
