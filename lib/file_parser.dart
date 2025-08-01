import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logger/logger.dart';

const hex = '[\\da-fA-F]';
const space = '\\s';
const nonSpace = '\\S';
const number = '\\d';
const nonNumber = '\\S';
const lineStart = '^';
const lineEnd = '\$';

final _logger = Logger(level: Level.off);

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

class _DataSource {
  final buffer = <String>[];
  int _index = 0;
  int gLN = 1;
  bool done = false;
  Completer<bool> _newLineCompleter = Completer<bool>();

  bool get isEmpty => _index >= buffer.length;

  Completer<bool> getNewLine() {
    if (_newLineCompleter.isCompleted) {
      _newLineCompleter = Completer<bool>();
    }
    return _newLineCompleter;
  }

  (int, String) getNextLine() {
    assert(buffer.isNotEmpty);
    final v = (gLN, buffer[_index]);
    _index++;
    gLN++;
    return v;
  }

  void reverse(int lines) {
    _index -= lines;
    gLN -= lines;
    assert(_index >= 0);
  }

  void dropBuffer() {
    buffer.removeRange(0, _index);
    _index = 0;
  }
}

Future<void> _parseStream(Stream<String> source, LineBlock root) async {
  final dataSource = _DataSource();
  root._setDataSource(dataSource);
  final parsing = root._parse();
  await for (final line in source) {
    dataSource.buffer.add(line);
    dataSource.getNewLine().complete(true);
    // yield
    await Future.delayed(Duration.zero);
  }
  dataSource.done = true;
  dataSource.getNewLine().complete(false);
  (await parsing)!.call();
}

Future<void> parseStream(
  Stream<String> source, {
  required dynamic define,
}) async {
  final root = LineBlock(name: '__root__', nested: define);
  return _parseStream(source, root);
}

Future<void> parseFile(File file, {required dynamic define}) async {
  final root = LineBlock(name: '__root__', nested: define);
  return _parseStream(file.openRead().lines(), root);
}

Future<void> parseFileAt(String path, {required dynamic define}) async {
  final root = LineBlock(name: '__root__', nested: define);
  return _parseStream(File(path).openRead().lines(), root);
}

typedef MatchHandler =
    void Function(
      LineBlock kind,
      int globalLN,
      int localLN,
      String line,
      Object matchResult,
    );
typedef CommitFunction = void Function();
typedef ContentHandler =
    CommitFunction Function(List<String> lines, int occurance);

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

class LineBlock {
  final String name;

  final List<Matcher> _head;
  final List<Matcher> _body;
  final List<Matcher> _tail;

  final Object? _nested;

  // Used when in a set of [LineBlock]
  int priority; // smaller => higher

  // Specify that there should be [lineCount] lines in the block
  final int? lineCount;

  // Specify that there should be at most [usageLimit] such blocks
  int? usageLimit;

  // Specify that if we allow other lines been mixed in between this block when
  // there is an ending condition
  final bool strict;

  final ContentHandler? action;

  int _lLN = 0;
  int _sgLN = 0;
  final _blockLines = <String>[];
  final _nestedCommits = <CommitFunction>[];

  int _usageCount = 0;
  late final _DataSource _dataSource;

  void _setDataSource(_DataSource value) {
    _dataSource = value;
    if (_nested != null) {
      switch (_nested) {
        case LineBlock lineBlock:
          lineBlock._setDataSource(value);
        case List<LineBlock> lineBlocks:
          for (final lineBlock in lineBlocks) {
            lineBlock._setDataSource(value);
          }
        case Set<LineBlock> lineBlocks:
          for (final lineBlock in lineBlocks) {
            lineBlock._setDataSource(value);
          }
      }
    }
  }

  LineBlock({
    String? name,
    dynamic head = const <Matcher>[],
    dynamic body = const <Matcher>[],
    dynamic tail = const <Matcher>[],
    this.priority = 1,
    this.lineCount,
    this.usageLimit,
    this.strict = false,
    this.action,
    Object? nested,
  }) : name = name ?? _generateName('Parser'),
       _head = _toList(head),
       _body = _toList(body),
       _tail = _toList(tail),
       _nested = nested {
    if (nested != null &&
        !(nested is LineBlock ||
            nested is List<LineBlock> ||
            nested is Set<LineBlock>)) {
      throw ArgumentError(
        '"nested" must be a LineBlock, List<LineBlock>, or Set<LineBlock>',
      );
    }
    if (_tail.isNotEmpty && lineCount != null) {
      throw ArgumentError(
        '"tail" and "lineCount" cannot be specified at the same time',
      );
    }
    for (final matcher in _head) {
      matcher.parser = this;
    }
    for (final matcher in _body) {
      matcher.parser = this;
    }
    for (final matcher in _tail) {
      matcher.parser = this;
    }
    if (_nested != null && _nested is List<LineBlock>) {
      final lineBlocks = _nested;
      for (final lineBlock in lineBlocks) {
        lineBlock.usageLimit ??= 1;
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

  bool get _usable => usageLimit == null || _usageCount < usageLimit!;

  bool get _hasEndingCondition => _tail.isNotEmpty || lineCount != null;

  CommitFunction _getCommit() {
    final myCommit = action?.call(_blockLines.toList(), _usageCount + 1);
    final nestedCommits = _nestedCommits.toList();
    return () {
      for (final nestedCommit in nestedCommits) {
        nestedCommit();
      }
      myCommit?.call();
      _usageCount++;
    };
  }

  void _reset() {
    _lLN = 0;
    _blockLines.clear();
    _nestedCommits.clear();
  }

  Future<CommitFunction?> _parse() async {
    _sgLN = _dataSource.gLN;
    while (true) {
      if (_dataSource.isEmpty) {
        if (_dataSource.done || !await _dataSource.getNewLine().future) {
          if (_hasEndingCondition) {
            _dataSource.reverse(_dataSource.gLN - _sgLN);
            _reset();
            return null;
          } else {
            final commit = _getCommit();
            _reset();
            return commit;
          }
        }
      }

      while (!_dataSource.isEmpty) {
        switch (await _parseNextLine()) {
          case _NextMove.expectMore:
            _logger.d('$name expecting more');
            continue;
          case _NextMove.dropBufferThenExpectMore:
            _logger.d('$name dropping buffer then expecting more');
            _dataSource.dropBuffer();
            continue;
          case _NextMove.stopWithSuccess:
            _logger.d('$name stopped with success');
            final commit = _getCommit();
            _reset();
            return commit;
          case _NextMove.stopWithSuccessExceptTheLastLine:
            _logger.d('$name stopped with success except the last line');
            _dataSource.reverse(1);
            final commit = _getCommit();
            _reset();
            return commit;
          case _NextMove.stopWithFailure:
            _logger.d('$name stopped with failure');
            _dataSource.reverse(_dataSource.gLN - _sgLN);
            _reset();
            return null;
        }
      }
    }
  }

  Future<_NextMove> _parseNextLine() async {
    if (_nested != null) {
      if (_nested is LineBlock) {
        final lineBlock = _nested;
        if (lineBlock._usable) {
          _logger.d('$name trying ${lineBlock.name}');
          final cf = await lineBlock._parse();
          if (cf != null) {
            _nestedCommits.add(cf);
            return name == '__root__'
                ? _NextMove.dropBufferThenExpectMore
                : _NextMove.expectMore;
          }
        }
      } else if (_nested is Set<LineBlock>) {
        final lineBlocks = _nested.toList()
          ..sort((a, b) => a.priority.compareTo(b.priority));
        for (final lineBlock in lineBlocks) {
          if (lineBlock._usable) {
            _logger.d('$name trying ${lineBlock.name}');
            final cf = await lineBlock._parse();
            if (cf != null) {
              _nestedCommits.add(cf);
              return name == '__root__'
                  ? _NextMove.dropBufferThenExpectMore
                  : _NextMove.expectMore;
            }
          }
        }
      } else if (_nested is List<LineBlock>) {
        final lineBlocks = _nested;
        for (final lineBlock in lineBlocks) {
          if (lineBlock._usable) {
            _logger.d('$name trying ${lineBlock.name}');
            final cf = await lineBlock._parse();
            if (cf != null) {
              _nestedCommits.add(cf);
              return name == '__root__'
                  ? _NextMove.dropBufferThenExpectMore
                  : _NextMove.expectMore;
            } else {
              break;
            }
          }
        }
      }
    }

    final (gLN, line) = _dataSource.getNextLine();

    _lLN++;
    Matcher? m;
    _logger.d('$name parsing $gLN $_lLN "$line"');
    if (_lLN == 1) {
      if (_head.isNotEmpty) {
        m = _findMatch(_head, gLN, _lLN, line);
      } else {
        m = _findMatch(_body, gLN, _lLN, line);
      }
      if (m == null) {
        if (name == '__root__') {
          return _NextMove.expectMore;
        }
        return _NextMove.stopWithFailure;
      }
    } else {
      if (_tail.isNotEmpty) {
        m = _findMatch(_tail, gLN, _lLN, line);
        if (m != null) {
          _blockLines.add(line);
          m.handleMatch();
          return _NextMove.stopWithSuccess;
        }
      }
      m ??= _findMatch(_body, gLN, _lLN, line);
      if (m == null) {
        if (_hasEndingCondition) {
          if (strict) {
            return _NextMove.stopWithFailure;
          } else {
            return _NextMove.expectMore;
          }
        } else {
          if (name == '__root__') {
            return _NextMove.expectMore;
          }
          return _NextMove.stopWithSuccessExceptTheLastLine;
        }
      }
    }

    _blockLines.add(line);
    m.handleMatch();

    if (lineCount != null) {
      if (_lLN == lineCount) {
        return _NextMove.stopWithSuccess;
      }
    }
    return _NextMove.expectMore;
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

extension _StreamListIntExt on Stream<List<int>> {
  Stream<String> lines() =>
      transform(utf8.decoder).transform(const LineSplitter());
}

enum _NextMove {
  expectMore,
  dropBufferThenExpectMore,
  stopWithSuccess,
  stopWithSuccessExceptTheLastLine,
  stopWithFailure,
}
