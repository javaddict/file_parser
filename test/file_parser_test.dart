import 'dart:io';

import 'package:dart_cli/dart_cli.dart';
import 'package:file_parser/file_parser.dart';
import 'package:test/test.dart';

void main() {
  group('with head and tail:', () {
    final input = createTempFile()
      ..write('''
...
<< head1
   body1
   body1
   body1
<<<< nested_head1
     nested_body1
     nested_body1
     nested_body1
<<<< nested_tail1
<< tail1
...
<< head2
   body2
   body2
   ...
   body2
<<<< nested_head2
     nested_body2
     nested_body2
     ...
     nested_body2
<<<< nested_tail2
<< tail2
...
''');

    test('tightly coupled line block', () async {
      final output = <String>[];
      final nestedOutput = <String>[];
      await parseFile(
        File(input),
        define: LineBlock(
          tightlyCoupled: true,
          head: Pattern('head'),
          body: Pattern('body'),
          tail: Pattern('tail'),
          nested: LineBlock(
            tightlyCoupled: true,
            head: Pattern('nested_head'),
            body: Pattern('nested_body'),
            tail: Pattern('nested_tail'),
            action: (lines, _) {
              nestedOutput.addAll(lines);
            },
          ),
          action: (lines, _) {
            output.addAll(lines);
          },
        ),
      );
      expect(output, [
        '<< head1',
        '   body1',
        '   body1',
        '   body1',
        '<< tail1',
      ]);
      expect(nestedOutput, [
        '<<<< nested_head1',
        '     nested_body1',
        '     nested_body1',
        '     nested_body1',
        '<<<< nested_tail1',
      ]);
    });

    test('loosely coupled line block', () async {
      final output = <String>[];
      final nestedOutput = <String>[];
      await parseFile(
        File(input),
        define: LineBlock(
          head: Pattern('head'),
          body: Pattern('body'),
          tail: Pattern('tail'),
          nested: LineBlock(
            head: Pattern('nested_head'),
            body: Pattern('nested_body'),
            tail: Pattern('nested_tail'),
            action: (lines, _) {
              nestedOutput.addAll(lines);
            },
          ),
          action: (lines, _) {
            output.addAll(lines);
          },
        ),
      );
      expect(output, [
        '<< head1',
        '   body1',
        '   body1',
        '   body1',
        '<< tail1',
        '<< head2',
        '   body2',
        '   body2',
        '   body2',
        '<< tail2',
      ]);
      expect(nestedOutput, [
        '<<<< nested_head1',
        '     nested_body1',
        '     nested_body1',
        '     nested_body1',
        '<<<< nested_tail1',
        '<<<< nested_head2',
        '     nested_body2',
        '     nested_body2',
        '     nested_body2',
        '<<<< nested_tail2',
      ]);
    });
  });

  tearDownAll(() {
    deleteTempFiles();
  });
}
