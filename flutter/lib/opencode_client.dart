/// OpenCode v2 — Flutter client for the local Node relay.
///
/// Three things live here:
///   1. [OpenCodeEvent]        — typed model for every SSE event opencode emits
///   2. [SessionInfo]          — a session row (title, model, cost, running…)
///   3. [OpenCodeRelayClient]  — every REST call the UI needs, plus the SSE feed
///
/// The relay's TLS edge (relay/Caddyfile) must be running on [kRelayUrl] before
/// this starts. On desktop that edge speaks QUIC and HTTP/2; see
/// [relay_transport_io.dart] for the negotiation.
///
/// Nothing in this file depends on Flutter widgets, so it can be unit-tested
/// with `flutter test` or reused from a CLI.

library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;

import 'relay_transport.dart';

// ─── Configuration ────────────────────────────────────────────────────────────

/// Web target: the browser talks straight to the plaintext relay.
const String _kRelayUrlWeb = 'http://127.0.0.1:3000';

/// Desktop target: the TLS edge, which terminates **QUIC on UDP 3443** and
/// **HTTP/2 on TCP 3443** and proxies to the relay on 3000 (see `relay/Caddyfile`).
/// `localhost`, not `127.0.0.1`, so SNI matches the edge's certificate.
const String _kRelayUrlDesktop = 'https://localhost:3443';

/// `--dart-define=RELAY_URL=...` overrides both, for pointing at a remote relay
/// or back at the plaintext `http://127.0.0.1:3000`.
const String _kRelayUrlOverride = String.fromEnvironment('RELAY_URL');

/// Where the relay (or its TLS edge) lives.
/// On an Android emulator use 10.0.2.2 instead of 127.0.0.1.
String get kRelayUrl => _kRelayUrlOverride.isNotEmpty
    ? _kRelayUrlOverride
    : (kIsWeb ? _kRelayUrlWeb : _kRelayUrlDesktop);


// ─── Typed event model ────────────────────────────────────────────────────────

/// Event types confirmed by live probing opencode v2.1.0.
///
/// Lifecycle order for a single prompt:
///   serverConnected → inboxEnqueued → executionStarted → instructionsUpdated
///   → inboxDelivered → stepStarted → textStarted / reasoningStarted
///   → textDelta (0..N) → textEnded → stepStreamed → stepEnded
///   → usageUpdated → executionSucceeded
///
/// Session-management events (created/renamed/deleted/model/agent) are emitted
/// whenever the corresponding REST call succeeds — they keep the UI in sync
/// even when the change came from another client.
enum OpenCodeEventType {
  serverConnected,
  sessionCreated,
  sessionUpdated,
  sessionRenamed,
  sessionDeleted,
  sessionArchived,
  sessionInboxEnqueued,
  sessionInboxDelivered,
  sessionInboxCancelled,
  sessionExecutionStarted,
  sessionExecutionSucceeded,
  sessionExecutionFailed,
  sessionExecutionInterrupted,
  sessionInstructionsUpdated,
  sessionStepStarted,
  sessionStepStreamed,
  sessionStepEnded,
  sessionTextStarted,
  sessionTextDelta,
  sessionTextEnded,
  sessionReasoningStarted,
  sessionReasoningDelta,
  sessionReasoningEnded,
  sessionUsageUpdated,
  sessionModelSelected,
  sessionAgentSelected,
  sessionCompactionStarted,
  sessionCompactionEnded,
  sessionCompactionFailed,
  projectUpdated,
  unknown,
}

class OpenCodeEvent {
  final OpenCodeEventType type;
  final Map<String, dynamic> raw;

  const OpenCodeEvent({required this.type, required this.raw});

  Map<String, dynamic>? get _data => raw['data'] as Map<String, dynamic>?;

  /// Every session-scoped event carries the session it belongs to.
  String? get sessionId => _data?['sessionID'] as String?;

  /// The streaming text token — only present on text delta events.
  String? get textDelta => _data?['delta'] as String?;

  /// The complete text — present on sessionTextEnded.
  String? get fullText => _data?['text'] as String?;

  /// Reasoning token — present on sessionReasoningDelta.
  String? get reasoningDelta => _data?['delta'] as String?;

  /// Token usage — present on sessionStepEnded and sessionUsageUpdated.
  Map<String, dynamic>? get tokens => _data?['tokens'] as Map<String, dynamic>?;

  /// New title — present on sessionRenamed.
  String? get title => _data?['title'] as String?;

  /// Selected model — present on sessionModelSelected.
  Map<String, dynamic>? get model => _data?['model'] as Map<String, dynamic>?;

  /// Selected agent — present on sessionAgentSelected.
  String? get agent => _data?['agent'] as String?;

  /// Convenience: the event's data payload.
  Map<String, dynamic>? get data => _data;

  /// True while the model is streaming tokens.
  bool get isStreaming =>
      type == OpenCodeEventType.sessionTextDelta ||
      type == OpenCodeEventType.sessionTextStarted;

  /// True when the full response is complete.
  bool get isComplete => type == OpenCodeEventType.sessionExecutionSucceeded;

  /// True when execution failed.
  bool get isFailed => type == OpenCodeEventType.sessionExecutionFailed;

  /// True when the execution was stopped with /interrupt.
  bool get isInterrupted =>
      type == OpenCodeEventType.sessionExecutionInterrupted;

  /// Parse a raw SSE `data:` line into a typed event.
  factory OpenCodeEvent.fromJson(String jsonStr) {
    try {
      final map = jsonDecode(jsonStr) as Map<String, dynamic>;
      final t = map['type'] as String? ?? '';
      final type = switch (t) {
        'server.connected'                 => OpenCodeEventType.serverConnected,
        'session.created'                  => OpenCodeEventType.sessionCreated,
        'session.updated'                  => OpenCodeEventType.sessionUpdated,
        'session.renamed'                  => OpenCodeEventType.sessionRenamed,
        'session.deleted'                  => OpenCodeEventType.sessionDeleted,
        'session.archived'                 => OpenCodeEventType.sessionArchived,
        'session.inbox.enqueued'           => OpenCodeEventType.sessionInboxEnqueued,
        'session.inbox.delivered'          => OpenCodeEventType.sessionInboxDelivered,
        'session.inbox.cancelled'          => OpenCodeEventType.sessionInboxCancelled,
        'session.execution.started'        => OpenCodeEventType.sessionExecutionStarted,
        'session.execution.succeeded'      => OpenCodeEventType.sessionExecutionSucceeded,
        'session.execution.failed'         => OpenCodeEventType.sessionExecutionFailed,
        'session.execution.interrupted'    => OpenCodeEventType.sessionExecutionInterrupted,
        'session.instructions.updated'     => OpenCodeEventType.sessionInstructionsUpdated,
        'session.step.started'             => OpenCodeEventType.sessionStepStarted,
        'session.step.streamed'            => OpenCodeEventType.sessionStepStreamed,
        'session.step.ended'               => OpenCodeEventType.sessionStepEnded,
        'session.text.started'             => OpenCodeEventType.sessionTextStarted,
        'session.text.delta'               => OpenCodeEventType.sessionTextDelta,
        'session.text.ended'               => OpenCodeEventType.sessionTextEnded,
        'session.reasoning.started'        => OpenCodeEventType.sessionReasoningStarted,
        'session.reasoning.delta'          => OpenCodeEventType.sessionReasoningDelta,
        'session.reasoning.ended'          => OpenCodeEventType.sessionReasoningEnded,
        'session.usage.updated'            => OpenCodeEventType.sessionUsageUpdated,
        'session.model.selected'           => OpenCodeEventType.sessionModelSelected,
        'session.agent.selected'           => OpenCodeEventType.sessionAgentSelected,
        'session.compaction.started'       => OpenCodeEventType.sessionCompactionStarted,
        'session.compaction.ended'         => OpenCodeEventType.sessionCompactionEnded,
        'session.compaction.failed'        => OpenCodeEventType.sessionCompactionFailed,
        'project.updated'                  => OpenCodeEventType.projectUpdated,
        _                                  => OpenCodeEventType.unknown,
      };
      return OpenCodeEvent(type: type, raw: map);
    } catch (_) {
      return OpenCodeEvent(type: OpenCodeEventType.unknown, raw: {'raw': jsonStr});
    }
  }

  @override
  String toString() => 'OpenCodeEvent(type: $type, raw: $raw)';
}

// ─── Data models ──────────────────────────────────────────────────────────────

class SessionInfo {
  final String id;
  final String title;
  final String? agent;
  final String? modelId;
  final String? providerID;
  final String? directory;
  final double cost;
  final int created;
  final int updated;
  final bool running;

  const SessionInfo({
    required this.id,
    required this.title,
    this.agent,
    this.modelId,
    this.providerID,
    this.directory,
    this.cost = 0,
    this.created = 0,
    this.updated = 0,
    this.running = false,
  });

  factory SessionInfo.fromJson(Map<String, dynamic> j) {
    final model = j['model'] as Map?;
    return SessionInfo(
      id: j['id'] as String,
      title: (j['title'] as String?) ?? '',
      agent: j['agent'] as String?,
      modelId: model?['id'] as String?,
      providerID: model?['providerID'] as String?,
      directory: j['directory'] as String?,
      cost: (j['cost'] as num?)?.toDouble() ?? 0,
      created: (j['created'] as num?)?.toInt() ?? 0,
      updated: (j['updated'] as num?)?.toInt() ?? 0,
      running: j['running'] == true,
    );
  }

  SessionInfo copyWith({String? title, bool? running, double? cost, int? updated}) =>
      SessionInfo(
        id: id,
        title: title ?? this.title,
        agent: agent,
        modelId: modelId,
        providerID: providerID,
        directory: directory,
        cost: cost ?? this.cost,
        created: created,
        updated: updated ?? this.updated,
        running: running ?? this.running,
      );

  DateTime get updatedAt => DateTime.fromMillisecondsSinceEpoch(updated);

  /// What to render in the sidebar — opencode leaves the title empty until the
  /// first prompt auto-names the session.
  String get displayTitle => title.trim().isEmpty ? 'New session' : title;

  String get shortModel => modelId ?? 'default model';
}

/// One transcript entry. User messages only carry [text]; assistant messages
/// may also carry [reasoning] and [tools]. System entries are markers emitted
/// by opencode (model switch, compaction…).
class ChatMessage {
  final String id;
  final String role; // 'user' | 'assistant' | 'system'
  final String text;
  final String reasoning;
  final List<ToolCall> tools;
  final int createdAt;
  final String kind;
  final String? modelId;
  final double cost;
  final int? outputTokens;

  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    this.reasoning = '',
    this.tools = const [],
    this.createdAt = 0,
    this.kind = 'unknown',
    this.modelId,
    this.cost = 0,
    this.outputTokens,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> j) {
    final model = j['model'] as Map?;
    final tokens = j['tokens'] as Map?;
    return ChatMessage(
      id: j['id'] as String,
      role: (j['role'] as String?) ?? 'system',
      text: (j['text'] as String?) ?? '',
      reasoning: (j['reasoning'] as String?) ?? '',
      tools: ((j['tools'] as List?) ?? const [])
          .whereType<Map>()
          .map((t) => ToolCall.fromJson(t.cast<String, dynamic>()))
          .toList(),
      createdAt: (j['createdAt'] as num?)?.toInt() ?? 0,
      kind: (j['kind'] as String?) ?? 'unknown',
      modelId: model?['id'] as String?,
      cost: (j['cost'] as num?)?.toDouble() ?? 0,
      outputTokens: (tokens?['output'] as num?)?.toInt(),
    );
  }

  bool get isUser => role == 'user';
  bool get isAssistant => role == 'assistant';
  bool get isSystem => role == 'system';
}

class ToolCall {
  final String name;
  final String status;
  final Map<String, dynamic>? input;
  final dynamic output;

  const ToolCall({
    required this.name,
    required this.status,
    this.input,
    this.output,
  });

  factory ToolCall.fromJson(Map<String, dynamic> j) => ToolCall(
        name: (j['name'] as String?) ?? 'tool',
        status: (j['status'] as String?) ?? 'unknown',
        input: j['input'] as Map<String, dynamic>?,
        output: j['output'],
      );

  bool get isRunning => status == 'running' || status == 'pending';
}

class ModelInfo {
  final String id;
  final String providerID;
  final String name;
  final int? contextLimit;

  const ModelInfo({
    required this.id,
    required this.providerID,
    required this.name,
    this.contextLimit,
  });

  factory ModelInfo.fromJson(Map<String, dynamic> j) => ModelInfo(
        id: (j['id'] as String?) ?? '',
        providerID: (j['providerID'] as String?) ?? '',
        name: (j['name'] as String?) ?? (j['id'] as String?) ?? '',
        contextLimit: (j['contextLimit'] as num?)?.toInt(),
      );

  String get label => '$name  ($providerID/$id)';
}

class AgentInfo {
  final String id;
  final String name;
  final String? description;

  const AgentInfo({required this.id, required this.name, this.description});

  factory AgentInfo.fromJson(Map<String, dynamic> j) => AgentInfo(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? (j['id'] as String?) ?? '',
        description: j['description'] as String?,
      );
}

// ─── Relay client ─────────────────────────────────────────────────────────────

class OpenCodeRelayClient {
  final String baseUrl;

  // The transport is negotiated once, lazily, on the first request: QUIC if the
  // edge answers over UDP, otherwise HTTP/2. See relay_transport_io.dart.
  RelayTransport? _transport;
  Future<RelayTransport>? _negotiating;

  /// Negotiated protocol, available after the first request completes.
  String? get protocol => _transport?.label;

  /// True when QUIC was unavailable and the app fell back to HTTP/2.
  bool get usingFallback => _transport?.isFallback ?? false;

  OpenCodeRelayClient({String? baseUrl}) : baseUrl = (baseUrl ?? kRelayUrl);

  Future<RelayTransport> _connection() async {
    final ready = _transport;
    if (ready != null) return ready;
    // Share one in-flight negotiation between concurrent callers, and forget a
    // failed one so a later request can retry once the edge is up.
    final existing = _negotiating;
    if (existing != null) return existing;

    final pending = createRelayTransport(Uri.parse(baseUrl));
    _negotiating = pending;
    try {
      final transport = await pending;
      _transport = transport;
      return transport;
    } catch (_) {
      _negotiating = null;
      rethrow;
    }
  }

  // ── HTTP plumbing ──────────────────────────────────────────────────────────

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Future<dynamic> _send(String method, String path,
      {Map<String, dynamic>? body, Map<String, String>? query}) async {
    final transport = await _connection();
    final req = http.Request(method, _uri(path, query));
    req.headers['Accept'] = 'application/json';
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }

    final res = await transport.client.send(req);

    final text = await res.stream.bytesToString();

    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw OpenCodeApiException(
        '${req.method} $path failed (${res.statusCode})',
        status: res.statusCode,
        details: text,
      );
    }
    if (text.isEmpty) return null;
    return jsonDecode(text);
  }

  // ── Sessions ───────────────────────────────────────────────────────────────

  /// GET /sessions — newest first.
  Future<List<SessionInfo>> listSessions({int limit = 100, String? search}) async {
    final json = await _send('GET', '/sessions', query: {
      'limit': '$limit',
      if (search != null && search.isNotEmpty) 'search': search,
    }) as Map<String, dynamic>;
    return ((json['sessions'] as List?) ?? const [])
        .whereType<Map>()
        .map((s) => SessionInfo.fromJson(s.cast<String, dynamic>()))
        .toList();
  }

  /// POST /sessions — create a session and return it.
  Future<SessionInfo> createSession({
    String? title,
    String? agent,
    String? providerID,
    String? modelID,
    String? directory,
  }) async {
    final json = await _send('POST', '/sessions', body: {
      if (title != null && title.isNotEmpty) 'title': title,
      if (agent != null) 'agent': agent,
      if (providerID != null && modelID != null)
        'model': {
          'id': modelID,
          'providerID': providerID,
          'variant': 'default',
        },
      if (directory != null) 'directory': directory,
    }) as Map<String, dynamic>;
    return SessionInfo.fromJson(json['session'] as Map<String, dynamic>);
  }

  /// PATCH /sessions/:id — rename.
  Future<void> renameSession(String sessionId, String title) =>
      _send('PATCH', '/sessions/$sessionId', body: {'title': title});

  /// DELETE /sessions/:id.
  Future<void> deleteSession(String sessionId) =>
      _send('DELETE', '/sessions/$sessionId');

  /// GET /sessions/:id/messages — normalised transcript.
  Future<List<ChatMessage>> loadMessages(String sessionId, {int limit = 200}) async {
    final json = await _send('GET', '/sessions/$sessionId/messages',
        query: {'limit': '$limit'}) as Map<String, dynamic>;
    return ((json['messages'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => ChatMessage.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  // ── Prompting ──────────────────────────────────────────────────────────────

  /// POST /sessions/:id/prompt.
  ///
  /// `providerID`/`modelID`/`agent` are applied as a switch before the prompt,
  /// because opencode's prompt payload itself does not accept them.
  Future<void> sendPrompt(
    String text, {
    required String sessionId,
    String? providerID,
    String? modelID,
    String? agent,
  }) =>
      _send('POST', '/sessions/$sessionId/prompt', body: {
        'prompt': text,
        if (providerID != null && modelID != null) ...{
          'providerID': providerID,
          'modelID': modelID,
        },
        if (agent != null) 'agent': agent,
      });

  /// POST /sessions/:id/interrupt — stop a running execution.
  Future<void> interrupt(String sessionId) =>
      _send('POST', '/sessions/$sessionId/interrupt', body: const {});

  /// POST /sessions/:id/command — run a slash-command (e.g. `compact`).
  Future<void> runCommand(String sessionId, String name, {String? text}) =>
      _send('POST', '/sessions/$sessionId/command',
          body: {'name': name, if (text != null && text.isNotEmpty) 'text': text});

  /// POST /sessions/:id/fork — branch the transcript; returns the new session.
  Future<SessionInfo> forkSession(String sessionId) async {
    final json = await _send('POST', '/sessions/$sessionId/fork',
        body: const {}) as Map<String, dynamic>;
    return SessionInfo.fromJson(json['session'] as Map<String, dynamic>);
  }

  /// POST /sessions/:id/compact — summarise the context.
  Future<void> compactSession(String sessionId) =>
      _send('POST', '/sessions/$sessionId/compact', body: const {});

  /// POST /sessions/:id/model.
  Future<void> setModel(String sessionId,
          {required String providerID, required String modelID}) =>
      _send('POST', '/sessions/$sessionId/model', body: {
        'providerID': providerID,
        'modelID': modelID,
      });

  /// POST /sessions/:id/agent.
  Future<void> setAgent(String sessionId, String agent) =>
      _send('POST', '/sessions/$sessionId/agent', body: {'agent': agent});

  // ── Metadata ───────────────────────────────────────────────────────────────

  /// GET /models — available models plus opencode's current default.
  Future<({List<ModelInfo> models, ModelInfo? defaultModel})> loadModels() async {
    final json = await _send('GET', '/models') as Map<String, dynamic>;
    final models = ((json['models'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => ModelInfo.fromJson(m.cast<String, dynamic>()))
        .toList();
    final def = json['default'] as Map?;
    return (
      models: models,
      defaultModel: def == null ? null : ModelInfo.fromJson(def.cast<String, dynamic>()),
    );
  }

  /// GET /agents.
  Future<List<AgentInfo>> loadAgents() async {
    final json = await _send('GET', '/agents') as Map<String, dynamic>;
    return ((json['agents'] as List?) ?? const [])
        .whereType<Map>()
        .map((a) => AgentInfo.fromJson(a.cast<String, dynamic>()))
        .toList();
  }

  /// GET /health.
  Future<Map<String, dynamic>> health() async =>
      await _send('GET', '/health') as Map<String, dynamic>;

  // ── Event stream ───────────────────────────────────────────────────────────

  /// GET /stream — continuous Server-Sent Events.
  ///
  /// Returns a broadcast [Stream<OpenCodeEvent>].
  /// The stream reconnects automatically if the relay drops the connection.
  Stream<OpenCodeEvent> eventStream() {
    // Use a StreamController so we can handle reconnects transparently.
    late StreamController<OpenCodeEvent> controller;
    bool cancelled = false;

    Future<void> connect() async {
      while (!cancelled) {
        try {
          final request = http.Request('GET', Uri.parse('$baseUrl/stream'));
          request.headers['Accept'] = 'text/event-stream';
          request.headers['Cache-Control'] = 'no-cache';

          final transport = await _connection();
          final response = await transport.client.send(request);

          if (response.statusCode != 200) {
            throw Exception('SSE endpoint returned ${response.statusCode}');
          }

          // SSE frames are UTF-8 text lines separated by \n\n.
          // We buffer incomplete lines across chunks.
          final buffer = StringBuffer();

          await for (final chunk in response.stream.transform(utf8.decoder)) {
            buffer.write(chunk);
            final raw = buffer.toString();
            // Process all complete frames (terminated by \n\n)
            final frames = raw.split('\n\n');
            // Last element may be an incomplete frame — keep it in the buffer
            buffer
              ..clear()
              ..write(frames.last);

            for (final frame in frames.sublist(0, frames.length - 1)) {
              for (final line in frame.split('\n')) {
                if (line.startsWith('data: ')) {
                  final payload = line.substring(6).trim();
                  if (payload.isEmpty || payload == '[DONE]') continue;
                  controller.add(OpenCodeEvent.fromJson(payload));
                }
              }
            }
          }
        } catch (e) {
          if (!cancelled) {
            controller.addError(e);
            // Brief back-off before reconnect
            await Future.delayed(const Duration(seconds: 2));
          }
        }
      }
    }

    controller = StreamController<OpenCodeEvent>.broadcast(
      onListen: () { cancelled = false; connect(); },
      onCancel: () { cancelled = true; },
    );

    return controller.stream;
  }

  void dispose() => _transport?.close();
}

class OpenCodeApiException implements Exception {
  final String message;
  final int status;
  final String details;

  const OpenCodeApiException(this.message, {required this.status, this.details = ''});

  @override
  String toString() => '$message${details.isEmpty ? '' : ' — $details'}';
}
