import 'dart:io';

import 'package:dart_cli/dart_cli.dart';
import 'package:file_parser/file_parser.dart';
import 'package:test/test.dart';

void main() {
  group('with head and tail:', () {
    final input = createTempFile()
      ..write('''
...
<< outer_head1
   outer_body1
   outer_body1
   outer_body1
<<<< inner_head1
     inner_body1
     inner_body1
     inner_body1
<<<< inner_tail1
<< outer_tail1
...
<< outer_head2
   outer_body2
   outer_body2
   ...
   outer_body2
<<<< inner_head2
     inner_body2
     inner_body2
     ...
     inner_body2
<<<< inner_tail2
<< outer_tail2
...
''');

    test('strictly defined line block', () async {
      final output = <String>[];
      final nestedOutput = <String>[];
      await parseFile(
        File(input),
        define: LineBlock(
          strict: true,
          head: Pattern('outer_head'),
          body: Pattern('outer_body'),
          tail: Pattern('outer_tail'),
          nested: LineBlock(
            strict: true,
            head: Pattern('inner_head'),
            body: Pattern('inner_body'),
            tail: Pattern('inner_tail'),
            action: (lines, _) =>
                () => nestedOutput.addAll(lines),
          ),
          action: (lines, _) =>
              () => output.addAll(lines),
        ),
      );
      expect(output, [
        '<< outer_head1',
        '   outer_body1',
        '   outer_body1',
        '   outer_body1',
        '<< outer_tail1',
      ]);
      expect(nestedOutput, [
        '<<<< inner_head1',
        '     inner_body1',
        '     inner_body1',
        '     inner_body1',
        '<<<< inner_tail1',
      ]);
    });

    test('loosely defined line block', () async {
      final output = <String>[];
      final nestedOutput = <String>[];
      await parseFile(
        File(input),
        define: LineBlock(
          head: Pattern('outer_head'),
          body: Pattern('outer_body'),
          tail: Pattern('outer_tail'),
          nested: LineBlock(
            strict: true,
            head: Pattern('inner_head'),
            body: Pattern('inner_body'),
            tail: Pattern('inner_tail'),
            action: (lines, _) =>
                () => nestedOutput.addAll(lines),
          ),
          action: (lines, _) =>
              () => output.addAll(lines),
        ),
      );
      expect(output, [
        '<< outer_head1',
        '   outer_body1',
        '   outer_body1',
        '   outer_body1',
        '<< outer_tail1',
        '<< outer_head2',
        '   outer_body2',
        '   outer_body2',
        '   outer_body2',
        '<< outer_tail2',
      ]);
      expect(nestedOutput, [
        '<<<< inner_head1',
        '     inner_body1',
        '     inner_body1',
        '     inner_body1',
        '<<<< inner_tail1',
      ]);
    });
  });

  group('nested should be nested', () {
    test('outer should match before inner can match', () async {
      final input = createTempFile()
        ..write('''
...
<< outer_head1
   outer_body1
   outer_body1
   outer_body1
<<<< inner_head1
     inner_body1
     inner_body1
     inner_body1
<<<< inner_tail1
   ...
<< outer_tail1
...
<< outer_head2
   outer_body2
   outer_body2
   outer_body2
<<<< inner_head2
     inner_body2
     inner_body2
     inner_body2
<<<< inner_tail2
<< outer_tail2
...
''');
      final output = <String>[];
      final nestedOutput = <String>[];
      await parseFile(
        File(input),
        define: LineBlock(
          strict: true,
          head: Pattern('outer_head'),
          body: Pattern('outer_body'),
          tail: Pattern('outer_tail'),
          nested: LineBlock(
            head: Pattern('inner_head'),
            body: Pattern('inner_body'),
            tail: Pattern('inner_tail'),
            action: (lines, _) =>
                () => nestedOutput.addAll(lines),
          ),
          action: (lines, _) =>
              () => output.addAll(lines),
        ),
      );
      expect(output, [
        '<< outer_head2',
        '   outer_body2',
        '   outer_body2',
        '   outer_body2',
        '<< outer_tail2',
      ]);
      expect(nestedOutput, [
        '<<<< inner_head2',
        '     inner_body2',
        '     inner_body2',
        '     inner_body2',
        '<<<< inner_tail2',
      ]);
    });

    test('headless outer', () async {
      final input = createTempFile()
        ..write('''
...
<<<< inner_head1
     inner_body1
     inner_body1
     inner_body1
<<<< inner_tail1
   outer_body1
   outer_body1
   outer_body1
   outer_body1
<< outer_tail1
...
''');
      final output = <String>[];
      final nestedOutput = <String>[];
      await parseFile(
        File(input),
        define: LineBlock(
          strict: true,
          body: Pattern('outer_body'),
          tail: Pattern('outer_tail'),
          nested: LineBlock(
            head: Pattern('inner_head'),
            body: Pattern('inner_body'),
            tail: Pattern('inner_tail'),
            action: (lines, _) =>
                () => nestedOutput.addAll(lines),
          ),
          action: (lines, _) =>
              () => output.addAll(lines),
        ),
      );
      expect(output, [
        '   outer_body1',
        '   outer_body1',
        '   outer_body1',
        '   outer_body1',
        '<< outer_tail1',
      ]);
      expect(nestedOutput, [
        '<<<< inner_head1',
        '     inner_body1',
        '     inner_body1',
        '     inner_body1',
        '<<<< inner_tail1',
      ]);
    });

    test('fallback in the middle', () async {
      final input = createTempFile()
        ..write('''
...
<< outer_head1
   outer_body1
   outer_body1
   outer_body1
<<<< inner_head1
     inner_body1
     inner_body1
     inner_body1
<<<< inner_tail1
   ...
<< outer_tail1
...
''');
      final output = <String>[];
      final nestedOutput = <String>[];
      await parseFile(
        File(input),
        define: {
          LineBlock(
            priority: 1,
            strict: true,
            head: Pattern('outer_head'),
            body: Pattern('outer_body'),
            tail: Pattern('outer_tail'),
            nested: LineBlock(
              head: Pattern('inner_head'),
              body: Pattern('inner_body'),
              tail: Pattern('inner_tail'),
              action: (lines, _) =>
                  () => nestedOutput.addAll(lines),
            ),
            action: (lines, _) =>
                () => output.addAll(lines),
          ),
          LineBlock(
            priority: 2,
            head: Pattern('outer_head'),
            body: Pattern('outer_body'),
            tail: Pattern('outer_tail'),
            action: (lines, _) =>
                () => output.addAll(lines),
          ),
        },
      );
      expect(output, [
        '<< outer_head1',
        '   outer_body1',
        '   outer_body1',
        '   outer_body1',
        '<< outer_tail1',
      ]);
      expect(nestedOutput, []);
    });

    test('fallback in the middle 2', () async {
      final input = createTempFile()
        ..write('''
...
<< outer_head1
   outer_body1
   outer_body1
   outer_body1
<<<< inner_head1
     inner_body1
     inner_body1
     inner_body1
<<<< inner_tail1
''');
      final output = <String>[];
      final nestedOutput = <String>[];
      await parseFile(
        File(input),
        define: {
          LineBlock(
            priority: 1,
            head: Pattern('outer_head'),
            body: Pattern('outer_body'),
            tail: Pattern('outer_tail'),
            nested: LineBlock(
              head: Pattern('inner_head'),
              body: Pattern('inner_body'),
              tail: Pattern('inner_tail'),
              action: (lines, _) =>
                  () => nestedOutput.addAll(lines),
            ),
            action: (lines, _) =>
                () => output.addAll(lines),
          ),
          LineBlock(
            priority: 2,
            head: Pattern('outer_head'),
            body: Pattern('outer_body'),
            action: (lines, _) =>
                () => output.addAll(lines),
          ),
        },
      );
      expect(output, [
        '<< outer_head1',
        '   outer_body1',
        '   outer_body1',
        '   outer_body1',
      ]);
      expect(nestedOutput, []);
    });
  });

  tearDownAll(() {
    deleteTempFiles();
  });
}
