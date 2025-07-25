import 'dart:async';
import 'dart:convert';
import 'dart:io';

const hex = '[\\da-fA-F]';
const space = '\\s';
const nonSpace = '\\S';
const number = '\\d';
const nonNumber = '\\S';
const lineStart = '^';
const lineEnd = '\$';

class LineBlockParsingException {
  final LineBlock parser;
  final int globalLN;
  final int localLN;
  final String line;
  final String message;

  LineBlockParsingException(
    this.parser,
    this.globalLN,
    this.localLN,
    this.line,
    this.message,
  );
}

class ParserStack {
  final _parsers = <LineBlock>[];

  LineBlock get _last => _parsers.last;

  bool _debug = false;

  void parse(int gLN, String line) {
    while (_parsers.isNotEmpty) {
      if (_last.parse(gLN, line)) {
        break;
      } else {
        popParser();
      }
    }
  }

  void pushParser(LineBlock parser) {
    _parsers.add(parser);
    parser.init(this);
  }

  void popParser() {
    assert(_parsers.isNotEmpty);
    final removed = _parsers.removeLast();
    removed.close();
  }

  void _close() {
    while (_parsers.isNotEmpty) {
      popParser();
    }
  }

  // Return an error message or null for success.
  Future<void> _parseStream(
    Stream<String> source, {
    required dynamic parsers,
    bool debug = false,
  }) async {
    var gLN = 0;
    _debug = debug;
    pushParser(LineBlock(name: 'root', nested: parsers)..root = true);
    await for (final line in source) {
      gLN++;
      if (_debug) {
        stdout.write('${'$gLN'.padLeft(8)}:  $line');
      }
      parse(gLN, line);
    }
    _close();
  }

  void lineMatched() {
    if (_debug) {
      stdout.write('    (O)');
      for (final parser in _parsers) {
        stdout.write(' #${parser.name}');
      }
      stdout.writeln();
    }
  }

  void lineSkipped() {
    if (_debug) {
      stdout.write('    (X)');
      for (final parser in _parsers) {
        stdout.write(' #${parser.name}');
      }
      stdout.writeln();
    }
  }

  bool tryEnding(int gLN, String line) {
    for (final parser in _parsers.reversed) {
      if (parser.root) {
        break;
      }
      if (parser.tryParse(gLN, line)) {
        return true;
      }
    }
    return false;
  }
}

Future<void> parseStream(
  Stream<String> source, {
  required dynamic define,
  bool debug = false,
}) async {
  return ParserStack()._parseStream(source, parsers: define, debug: debug);
}

Future<void> parseFile(
  File file, {
  required dynamic define,
  bool debug = false,
}) async {
  return ParserStack()._parseStream(
    file.openRead().lines(),
    parsers: define,
    debug: debug,
  );
}

Future<void> parseFileAt(
  String path, {
  required dynamic define,
  bool debug = false,
}) async {
  return ParserStack()._parseStream(
    File(path).openRead().lines(),
    parsers: define,
    debug: debug,
  );
}

typedef MatchHandler =
    void Function(
      LineBlock kind,
      int globalLN,
      int localLN,
      String line,
      Object matchResult,
    );
typedef ContentHandler = void Function(List<String> lines);

abstract class Matcher {
  final String name;
  final MatchHandler? _handler;

  late LineBlock parser;

  int _gLN = 0;
  int _lLN = 0;
  String _line = '';
  Object? _matchResult;

  Matcher({String? name, MatchHandler? then})
    : name = name ?? _generateName('Matcher'),
      _handler = then;

  // Return null for no match
  Object? match(int gLN, int lLN, String line);

  bool matchLine(int gLN, int lLN, String line) {
    // 同一條 line 不 match() 兩次
    if (_gLN != gLN) {
      _gLN = gLN;
      _lLN = lLN;
      _line = line;
      _matchResult = match(gLN, lLN, line);
    }
    return _matchResult != null && _matchResult != false;
  }

  void handleMatch() {
    _handler?.call(parser, _gLN, _lLN, _line, _matchResult!);
  }
}

class Pattern extends Matcher {
  final RegExp _regExp;

  Pattern(String regExp, {String? name, super.then})
    : _regExp = RegExp(regExp),
      super(name: name ?? _generateName('Pattern'));

  @override
  Object? match(int gLN, int lLN, String line) => _regExp.firstMatch(line);
}

class LineNo extends Matcher {
  final List<int> _lines;
  final bool _global;

  LineNo(dynamic lines, {bool global = false, String? name, super.then})
    : _lines = _parse(lines),
      _global = global,
      super(name: name ?? _generateName('Lines'));

  @override
  Object? match(int gLN, int lLN, String line) =>
      _lines.contains(_global ? gLN : lLN);

  static List<int> _parse(dynamic value) {
    if (value is List<int>) {
      return value;
    } else if (value is int) {
      return [value];
    } else if (value is String) {
      final m = value.split(',');
      final l = <int>[];
      final single = RegExp(r'^\s*(\d+)\s*$');
      final range = RegExp(r'^\s*(\d+)\s*[-~]\s*(\d+)\s*$');
      for (final e in m) {
        var m = single.firstMatch(e);
        if (m != null) {
          l.add(int.parse(m[1]!));
        } else {
          m = range.firstMatch(e);
          if (m != null) {
            var i = int.parse(m[1]!);
            var j = int.parse(m[2]!);
            if (i > j) {
              final k = i;
              i = j;
              j = k;
            }
            final l = <int>[];
            for (var k = i; k <= j; k++) {
              l.add(k);
            }
          }
        }
      }
      return l;
    } else {
      return const <int>[];
    }
  }
}

class Literal extends Matcher {
  final String _literal;

  Literal(this._literal, {String? name, super.then})
    : super(name: name ?? _generateName('Literal'));

  @override
  Object? match(int gLN, int lLN, String line) => line.contains(_literal);
}

class AllOthers extends Matcher {
  AllOthers({String? name, super.then})
    : super(name: name ?? _generateName('AllOthers'));

  @override
  Object? match(int gLN, int lLN, String line) {
    if (parser.isOpenEnding) {
      return !parser.parserStack!.tryEnding(gLN, line);
    }
    return true;
  }
}

class LineBlock {
  final String name;

  ParserStack? parserStack;

  List<Matcher> _head;
  List<Matcher> _body;
  List<Matcher> _tail;

  dynamic _nested;
  List<LineBlock> _nestedParsers;

  int priority; // smaller => higher
  int? lineCount;
  int? lineLimit;
  int? usageLimit;
  bool root = false;
  bool enabled = true;

  int _lLN = 0;
  bool _closed = false;
  final List<String> _content = [];

  ContentHandler? action;

  LineBlock({
    String? name,
    dynamic head = const <Matcher>[],
    dynamic body = const <Matcher>[],
    dynamic tail = const <Matcher>[],
    this.priority = 1,
    this.lineCount,
    this.lineLimit,
    this.usageLimit,
    this.action,
    dynamic nested = const <LineBlock>{},
  }) : name = name ?? _generateName('Parser'),
       _head = _toList(head),
       _body = _toList(body),
       _tail = _toList(tail),
       _nested = nested,
       _nestedParsers = _build(nested) {
    for (var matcher in _head) {
      matcher.parser = this;
    }
    for (var matcher in _body) {
      matcher.parser = this;
    }
    for (var matcher in _tail) {
      matcher.parser = this;
    }
    if (_head.any((m) => m is AllOthers)) {
      throw ArgumentError('AllOthers is not allowed for head.', 'head');
    }
    if (_tail.any((m) => m is AllOthers)) {
      throw ArgumentError('AllOthers is not allowed for tail.', 'tail');
    }
    if (_body.any((m) => m is AllOthers)) {
      if (_head.isEmpty) {
        throw ArgumentError('AllOthers is not allowed without head.', 'body');
      }
      if (_body.length > 1 && _body.last is! AllOthers) {
        throw ArgumentError('AllOthers must be the last one.', 'body');
      }
      if (_body.whereType<AllOthers>().length > 1) {
        throw ArgumentError('Only one AllOthers is allowed.', 'body');
      }
    }
  }

  static List<Matcher> _toList(dynamic matcher) {
    assert(matcher is Matcher || matcher is List<Matcher>);
    if (matcher is Matcher) {
      return [matcher];
    } else {
      return matcher;
    }
  }

  List<Matcher> get head => _head;

  set head(dynamic value) {
    _head = _toList(value);
    for (var matcher in _head) {
      matcher.parser = this;
    }
  }

  List<Matcher> get body => _body;

  set body(dynamic value) {
    _body = _toList(value);
    for (var matcher in _body) {
      matcher.parser = this;
    }
  }

  List<Matcher> get tail => _tail;

  set tail(dynamic value) {
    _tail = _toList(value);
    for (var matcher in _tail) {
      matcher.parser = this;
    }
  }

  bool get isOpenEnding => _tail.isEmpty;

  static List<LineBlock> _build(dynamic parsers) {
    assert(
      parsers is LineBlock || parsers is List<LineBlock> || parsers is Set,
    );
    if (parsers is LineBlock) {
      return [parsers];
    } else if (parsers is List<LineBlock>) {
      return [Ordered(parsers)];
    } else {
      return (parsers as Set)
          .map((e) {
            assert(e is LineBlock || e is List<LineBlock>);
            if (e is LineBlock) {
              return e;
            } else {
              return Ordered(e);
            }
          })
          .toList(growable: false)
        ..sort((a, b) => a.priority - b.priority);
    }
  }

  dynamic get nested => _nested;

  set nested(dynamic value) {
    _nested = value;
    _nestedParsers = _build(value);
  }

  void init(ParserStack ps) {
    parserStack = ps;
    _lLN = 0;
    _closed = false;
  }

  static Matcher? _findMatch(
    List<Matcher> matchers,
    int gLN,
    int lLN,
    String line,
  ) {
    for (final m in matchers) {
      if (m.matchLine(gLN, lLN, line)) {
        return m;
      }
    }
    return null;
  }

  bool parse(int gLN, String line) {
    if (_closed) {
      return false;
    }
    final usageLimit = this.usageLimit;

    for (final parser in _nestedParsers) {
      if (parser.enabled && (usageLimit == null || usageLimit > 0)) {
        parserStack!.pushParser(parser);
        if (parser.parse(gLN, line)) {
          return true;
        } else {
          parserStack!.popParser();
        }
      }
    }

    if (root) {
      parserStack!.lineSkipped();
      return true;
    }

    _lLN++;
    Matcher? m;
    if (_lLN == 1) {
      if (head.isNotEmpty) {
        m = _findMatch(head, gLN, _lLN, line);
      } else {
        m = _findMatch(body, gLN, _lLN, line);
      }
      if (m == null) {
        return false;
      }
      if (usageLimit != null) {
        this.usageLimit = usageLimit - 1;
      }
    } else {
      if (tail.isNotEmpty) {
        m = _findMatch(tail, gLN, _lLN, line);
        if (m != null) {
          _closed = true;
        }
      }
      m ??= _findMatch(body, gLN, _lLN, line);
      if (m == null) {
        if (!(tail.isNotEmpty || lineCount != null)) {
          return false;
        }
      }
    }

    if (lineCount != null && _lLN == lineCount) {
      _closed = true;
    }
    if (lineLimit != null && _lLN == lineLimit) {
      _closed = true;
    }

    if (m != null) {
      parserStack!.lineMatched();
    } else {
      parserStack!.lineSkipped();
    }
    _content.add(line);
    m?.handleMatch();

    return true;
  }

  bool tryParse(int gLN, String line) {
    final usageLimit = this.usageLimit;

    for (final parser in _nestedParsers) {
      if (parser.enabled && (usageLimit == null || usageLimit > 0)) {
        if (parser.tryParse(gLN, line)) {
          return true;
        }
      }
    }

    Matcher? m;
    if (head.isNotEmpty) {
      m = _findMatch(head, gLN, 1, line);
    } else {
      m = _findMatch(body, gLN, 1, line);
    }
    return m != null;
  }

  bool close() {
    if (_content.isNotEmpty) {
      action?.call(_content);
      _content.clear();
      return true;
    }
    return false;
  }

  void markClosed() {
    _closed = true;
  }
}

class Ordered implements LineBlock {
  int _index = 0;
  final List<LineBlock> _parsers;

  Ordered(this._parsers) {
    for (final p in _parsers) {
      p.usageLimit = null;
    }
  }

  final String _name = _generateName('OrderedParsers');

  @override
  String get name => _parsers.isEmpty ? _name : _parsers[_index].name;

  @override
  ParserStack? get parserStack =>
      _parsers.isEmpty ? null : _parsers[_index].parserStack;

  @override
  set parserStack(ParserStack? value) {
    for (final p in _parsers) {
      p.parserStack = value;
    }
  }

  @override
  List<Matcher> _head = const []; // not used
  @override
  List<Matcher> _body = const []; // not used
  @override
  List<Matcher> _tail = const []; // not used

  @override
  List<Matcher> get head => _parsers.isEmpty ? const [] : _parsers[_index].head;

  @override
  set head(dynamic value) {
    if (_index < _parsers.length) {
      _parsers[_index].head = value;
    }
  }

  @override
  List<Matcher> get body => _parsers.isEmpty ? const [] : _parsers[_index].body;

  @override
  set body(dynamic value) {
    if (_index < _parsers.length) {
      _parsers[_index].body = value;
    }
  }

  @override
  List<Matcher> get tail => _parsers.isEmpty ? const [] : _parsers[_index].tail;

  @override
  set tail(dynamic value) {
    if (_index < _parsers.length) {
      _parsers[_index].tail = value;
    }
  }

  @override
  bool get isOpenEnding => _parsers[_index].tail.isEmpty;

  @override
  dynamic _nested; // not used

  @override
  List<Matcher> get nested =>
      _parsers.isEmpty ? const [] : _parsers[_index].nested;

  @override
  set nested(dynamic value) {
    if (_index < _parsers.length) {
      _parsers[_index].nested = value;
    }
  }

  @override
  List<LineBlock> _nestedParsers = const []; // not used

  @override
  int get priority => _parsers.isEmpty ? 1 : _parsers[_index].priority;

  @override
  set priority(int value) {
    for (var p in _parsers) {
      p.priority = value;
    }
  }

  @override
  int? get lineCount => _parsers.isEmpty ? null : _parsers[_index].lineCount;

  @override
  set lineCount(int? value) {
    if (_index < _parsers.length) {
      _parsers[_index].lineCount = value;
    }
  }

  @override
  int? get lineLimit => _parsers.isEmpty ? null : _parsers[_index].lineLimit;

  @override
  set lineLimit(int? value) {
    if (_index < _parsers.length) {
      _parsers[_index].lineLimit = value;
    }
  }

  @override
  int? usageLimit; // not used

  @override
  bool root = false; // not used

  @override
  bool get enabled => _parsers.isEmpty ? true : _parsers[_index].enabled;

  @override
  set enabled(bool value) {
    for (var p in _parsers) {
      p.enabled = value;
    }
  }

  @override
  int _lLN = 0; // not used

  @override
  bool _closed = false; // not used

  @override
  final List<String> _content = const []; // not used

  @override
  ContentHandler? get action =>
      _parsers.isEmpty ? null : _parsers[_index].action;

  @override
  set action(ContentHandler? value) {
    if (_index < _parsers.length) {
      _parsers[_index].action = value;
    }
  }

  @override
  void init(ParserStack ps) {
    if (_index < _parsers.length) {
      _parsers[_index].init(ps);
    }
  }

  @override
  bool parse(int gLN, String line) {
    if (_index < _parsers.length) {
      return _parsers[_index].parse(gLN, line);
    }
    return false;
  }

  @override
  bool tryParse(int gLN, String line) {
    if (_index + 1 < _parsers.length) {
      return _parsers[_index + 1].tryParse(gLN, line);
    }
    return false;
  }

  @override
  bool close() {
    if (_index < _parsers.length) {
      if (_parsers[_index].close()) {
        _index++;
        return true;
      }
    }
    return false;
  }

  @override
  void markClosed() {
    if (_index < _parsers.length) {
      _parsers[_index].markClosed();
    }
  }
}

final Map<String, int> _counter = {};

String _generateName(String prefix) {
  final num = _counter[prefix] ?? 0;
  _counter[prefix] = num + 1;
  return '$prefix$num';
}

/// The depth of nesting is finite. You need to explicitly specify each layer.
/// Make it possible for infinite nesting?
/// TODO:
/// I have found what I want. Drop the parsing
/// Close the block right the way if we know it is closed.
/// Force closing from outside (?)

extension StreamListIntExt on Stream<List<int>> {
  Stream<String> lines() =>
      transform(utf8.decoder).transform(const LineSplitter());
}
