// Unit tests for the relay payload → Dart model mapping.
//
// These run without a relay or opencode instance: they pin the JSON shapes
// captured live from opencode v2.1.0 so a schema change shows up as a test
// failure rather than a blank transcript.

import 'package:flutter_test/flutter_test.dart';

import 'package:opencode_flutter_spike/opencode_client.dart';

void main() {
  group('SessionInfo', () {
    test('parses a session row from the relay', () {
      final s = SessionInfo.fromJson({
        'id': 'ses_123',
        'title': 'Fix CORS',
        'agent': 'assistant',
        'model': {'id': 'glm-5.3', 'providerID': 'camer-digital'},
        'directory': '/home/derick/projects/x',
        'cost': 0.0042,
        'created': 1792500000000,
        'updated': 1792500100000,
        'running': true,
      });

      expect(s.id, 'ses_123');
      expect(s.displayTitle, 'Fix CORS');
      expect(s.shortModel, 'glm-5.3');
      expect(s.cost, closeTo(0.0042, 1e-9));
      expect(s.running, isTrue);
    });

    test('untitled sessions show a friendly placeholder', () {
      final s = SessionInfo.fromJson({'id': 'ses_x', 'title': ''});
      expect(s.displayTitle, 'New session');
      expect(s.shortModel, 'default model');
    });
  });

  group('ChatMessage', () {
    test('parses a user message', () {
      final m = ChatMessage.fromJson({
        'id': 'msg_1',
        'role': 'user',
        'text': 'hello',
        'kind': 'user',
        'createdAt': 1792500000000,
      });

      expect(m.isUser, isTrue);
      expect(m.text, 'hello');
    });

    test('parses an assistant message with reasoning and tools', () {
      final m = ChatMessage.fromJson({
        'id': 'msg_2',
        'role': 'assistant',
        'text': 'All done.',
        'reasoning': 'First I checked the file.',
        'kind': 'assistant',
        'model': {'id': 'deepseek-v4.1-flash-free', 'providerID': 'opencode'},
        'cost': 0.001,
        'tokens': {'output': 42},
        'tools': [
          {
            'name': 'shell',
            'status': 'completed',
            'input': {'command': 'ls'},
            'output': 'file.txt',
          }
        ],
      });

      expect(m.isAssistant, isTrue);
      expect(m.text, 'All done.');
      expect(m.reasoning, contains('checked'));
      expect(m.modelId, 'deepseek-v4.1-flash-free');
      expect(m.outputTokens, 42);
      expect(m.tools.single.name, 'shell');
      expect(m.tools.single.isRunning, isFalse);
    });
  });

  group('OpenCodeEvent', () {
    test('parses a text delta with its session id', () {
      final e = OpenCodeEvent.fromJson(
        '{"id":"evt_1","type":"session.text.delta",'
        '"data":{"sessionID":"ses_1","delta":"word"}}',
      );

      expect(e.type, OpenCodeEventType.sessionTextDelta);
      expect(e.sessionId, 'ses_1');
      expect(e.textDelta, 'word');
      expect(e.isStreaming, isTrue);
    });

    test('parses execution lifecycle events', () {
      final started = OpenCodeEvent.fromJson(
        '{"type":"session.execution.started","data":{"sessionID":"ses_1"}}',
      );
      final interrupted = OpenCodeEvent.fromJson(
        '{"type":"session.execution.interrupted","data":{"sessionID":"ses_1"}}',
      );

      expect(started.type, OpenCodeEventType.sessionExecutionStarted);
      expect(interrupted.isInterrupted, isTrue);
    });

    test('parses session-management events used to sync the sidebar', () {
      final created = OpenCodeEvent.fromJson(
        '{"type":"session.created","data":{"sessionID":"ses_1","title":"hi"}}',
      );
      final renamed = OpenCodeEvent.fromJson(
        '{"type":"session.renamed","data":{"sessionID":"ses_1","title":"new"}}',
      );
      final model = OpenCodeEvent.fromJson(
        '{"type":"session.model.selected",'
        '"data":{"sessionID":"ses_1","model":{"id":"m","providerID":"p"}}}',
      );

      expect(created.type, OpenCodeEventType.sessionCreated);
      expect(renamed.title, 'new');
      expect(model.model?['id'], 'm');
    });

    test('malformed frames become unknown events instead of throwing', () {
      expect(OpenCodeEvent.fromJson('not json').type, OpenCodeEventType.unknown);
    });
  });
}
