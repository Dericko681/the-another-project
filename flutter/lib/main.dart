/// OpenCode v2 Flutter spike — session-aware client
///
/// The app now drives opencode, not just a single hard-coded session:
///
///   • list / create / select sessions          (sidebar)
///   • rename, fork, delete, compact            (session menu)
///   • send a prompt into the selected session  (composer)
///   • stop a running execution                 (stop button)
///   • switch model and agent per session       (app-bar menus)
///   • live transcript rebuilt from the relay's
///     normalised message history + SSE deltas
///
/// The relay (relay/index.js) must be running before this app starts.

library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'opencode_client.dart';

// ─── App shell ────────────────────────────────────────────────────────────────

void main() => runApp(const OpenCodeSpikeApp());

class OpenCodeSpikeApp extends StatelessWidget {
  const OpenCodeSpikeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenCode Spike',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF7C4DFF),
      ),
      home: const OpenCodeSpikePage(),
    );
  }
}

class OpenCodeSpikePage extends StatefulWidget {
  const OpenCodeSpikePage({super.key});

  @override
  State<OpenCodeSpikePage> createState() => _OpenCodeSpikePageState();
}

class _OpenCodeSpikePageState extends State<OpenCodeSpikePage> {
  final _client = OpenCodeRelayClient();
  final _input = TextEditingController();
  final _scroll = ScrollController();

  StreamSubscription<OpenCodeEvent>? _sub;
  Timer? _sessionsRefresh;

  // ── Session state ─────────────────────────────────────────────────────────
  List<SessionInfo> _sessions = [];
  String? _sessionId;
  List<ChatMessage> _messages = [];
  List<ModelInfo> _models = [];
  List<AgentInfo> _agents = [];
  ModelInfo? _model;
  AgentInfo? _agent;

  // ── Live turn state ───────────────────────────────────────────────────────
  String _liveText = '';
  String _liveReasoning = '';
  bool _running = false;
  bool _sending = false;
  String _status = 'connecting…';
  String? _error;

  /// Negotiated transport, e.g. `QUIC · HTTP/3`. Null until the first request.
  String? _protocol;

  SessionInfo? get _current {
    for (final s in _sessions) {
      if (s.id == _sessionId) return s;
    }
    return null;
  }

  bool get _busy => _running || _sending;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _sub = _client.eventStream().listen(_onEvent, onError: _onStreamError);
    _bootstrap();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _sessionsRefresh?.cancel();
    _client.dispose();
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      await _client.health();
      final meta = await _client.loadModels();
      final agents = await _client.loadAgents();

      if (!mounted) return;
      setState(() {
        _models = meta.models;
        _agents = agents;
        _agent = agents.where((a) => a.id == 'assistant').firstOrNull ??
            (agents.isEmpty ? null : agents.first);
        _model = meta.defaultModel;
        // health() was the first request, so the transport is negotiated now.
        _protocol = _client.protocol;
        _status = 'connected';
      });

      await _refreshSessions();

      if (_sessions.isEmpty) {
        await _newSession(switchTo: true);
      } else {
        await _selectSession(_sessions.first.id);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Relay unreachable at $kRelayUrl — start scripts/relay.sh\n$e';
          _status = 'offline';
        });
      }
    }
  }

  // ── SSE handling ──────────────────────────────────────────────────────────

  void _onStreamError(Object e) {
    if (!mounted) return;
    setState(() => _status = 'stream error: $e');
  }

  void _onEvent(OpenCodeEvent e) {
    if (!mounted) return;
    final sid = e.sessionId;
    final isCurrent = sid == null || sid == _sessionId;

    switch (e.type) {
      // ── live transcript for the selected session ──────────────────────────
      case OpenCodeEventType.sessionTextDelta:
        if (isCurrent && (e.textDelta?.isNotEmpty ?? false)) {
          setState(() {
            _liveText += e.textDelta!;
            _running = true;
          });
          _scrollToBottom();
        }

      case OpenCodeEventType.sessionTextEnded:
        if (isCurrent && (e.fullText?.isNotEmpty ?? false)) {
          setState(() {
            // Ground truth beats accumulated deltas (covers reconnects).
            if (_liveText != e.fullText) _liveText = e.fullText!;
          });
          _scrollToBottom();
        }

      case OpenCodeEventType.sessionReasoningDelta:
        if (isCurrent && (e.reasoningDelta?.isNotEmpty ?? false)) {
          setState(() => _liveReasoning += e.reasoningDelta!);
        }

      case OpenCodeEventType.sessionExecutionStarted:
        if (isCurrent) {
          setState(() {
            _running = true;
            _status = 'model is thinking…';
          });
        }
        _markRunning(sid, true);
        _scheduleSessionsRefresh();

      case OpenCodeEventType.sessionStepStarted:
        if (isCurrent) {
          final model = (e.data?['model'] as Map?)?['id'] ?? 'model';
          setState(() => _status = 'streaming from $model…');
        }

      case OpenCodeEventType.sessionInboxEnqueued:
        if (isCurrent) setState(() => _status = 'prompt queued…');

      case OpenCodeEventType.sessionExecutionSucceeded:
        _finishTurn(sid, status: 'done');

      case OpenCodeEventType.sessionExecutionFailed:
        _finishTurn(sid, status: 'execution failed');

      case OpenCodeEventType.sessionExecutionInterrupted:
        _finishTurn(sid, status: 'stopped');

      // ── session list bookkeeping ──────────────────────────────────────────
      case OpenCodeEventType.sessionCreated:
      case OpenCodeEventType.sessionDeleted:
      case OpenCodeEventType.sessionRenamed:
      case OpenCodeEventType.sessionUpdated:
      case OpenCodeEventType.sessionArchived:
        _scheduleSessionsRefresh();

      case OpenCodeEventType.sessionModelSelected:
        if (isCurrent && e.model != null) {
          setState(() => _model = ModelInfo(
                id: (e.model!['id'] as String?) ?? '',
                providerID: (e.model!['providerID'] as String?) ?? '',
                name: (e.model!['id'] as String?) ?? '',
              ));
        }
        _scheduleSessionsRefresh();

      case OpenCodeEventType.sessionAgentSelected:
        if (isCurrent && e.agent != null) {
          setState(() {
            _agent = _agents.where((a) => a.id == e.agent).firstOrNull;
            _status = 'agent → ${e.agent}';
          });
        }
        _scheduleSessionsRefresh();

      case OpenCodeEventType.sessionUsageUpdated:
        _scheduleSessionsRefresh();

      default:
        break;
    }
  }

  void _markRunning(String? sid, bool running) {
    if (sid == null) return;
    final i = _sessions.indexWhere((s) => s.id == sid);
    if (i == -1) return;
    if (_sessions[i].running == running) return;
    setState(() => _sessions[i] = _sessions[i].copyWith(running: running));
  }

  /// A turn ended: clear the live buffer and reload the authoritative transcript.
  Future<void> _finishTurn(String? sid, {required String status}) async {
    final isCurrent = sid == null || sid == _sessionId;

    if (isCurrent) {
      setState(() {
        _running = false;
        _sending = false;
        _status = status;
      });
      // Small delay so opencode has persisted the final assistant message.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (mounted) await _loadMessages(clearLive: true);
    } else {
      _markRunning(sid, false);
    }
    _scheduleSessionsRefresh();
  }

  void _scheduleSessionsRefresh() {
    _sessionsRefresh?.cancel();
    _sessionsRefresh = Timer(const Duration(milliseconds: 350), _refreshSessions);
  }

  // ── Session operations ────────────────────────────────────────────────────

  Future<void> _refreshSessions() async {
    try {
      final sessions = await _client.listSessions();
      if (!mounted) return;
      setState(() => _sessions = sessions);

      // If the selected session vanished (deleted elsewhere), fall back.
      if (_sessionId != null && !sessions.any((s) => s.id == _sessionId)) {
        if (sessions.isEmpty) {
          await _newSession(switchTo: true);
        } else {
          await _selectSession(sessions.first.id);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _status = 'session list failed: $e');
    }
  }

  Future<void> _selectSession(String id) async {
    if (id == _sessionId) return;
    setState(() {
      _sessionId = id;
      _messages = [];
      _liveText = '';
      _liveReasoning = '';
      _running = false;
      _sending = false;
      _status = 'loading transcript…';
    });

    final s = _sessions.where((x) => x.id == id).firstOrNull;
    if (s != null) {
      final m = _models.where((x) => x.id == s.modelId).firstOrNull;
      if (m != null) _model = m;
      final a = _agents.where((x) => x.id == (s.agent ?? '')).firstOrNull;
      if (a != null) _agent = a;
    }

    await _loadMessages(clearLive: false);
    if (mounted) setState(() => _status = 'ready');
    _scrollToBottom();
  }

  Future<void> _loadMessages({bool clearLive = false}) async {
    final id = _sessionId;
    if (id == null) return;
    try {
      final messages = await _client.loadMessages(id);
      if (!mounted) return;
      setState(() {
        _messages = messages;
        if (clearLive) {
          _liveText = '';
          _liveReasoning = '';
        }
      });
      _scrollToBottom();
    } catch (e) {
      if (mounted) setState(() => _status = 'transcript failed: $e');
    }
  }

  Future<void> _newSession({bool switchTo = true}) async {
    try {
      final session = await _client.createSession(
        agent: _agent?.id,
        providerID: _model?.providerID,
        modelID: _model?.id,
      );
      await _refreshSessions();
      if (switchTo) {
        setState(() => _sessionId = null); // force _selectSession to run
        await _selectSession(session.id);
      }
      if (mounted) setState(() => _status = 'new session');
    } catch (e) {
      if (mounted) setState(() => _error = 'create session failed: $e');
    }
  }

  Future<void> _renameCurrent() async {
    final current = _current;
    if (current == null) return;

    final controller = TextEditingController(text: current.title);
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename session'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Title'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (title == null || title.trim().isEmpty) return;
    try {
      await _client.renameSession(current.id, title.trim());
      await _refreshSessions();
    } catch (e) {
      if (mounted) setState(() => _error = 'rename failed: $e');
    }
  }

  Future<void> _deleteSession(SessionInfo session) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete session?'),
        content: Text(
          '"${session.displayTitle}" and its transcript will be removed from opencode.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await _client.deleteSession(session.id);
      if (session.id == _sessionId) {
        setState(() {
          _sessionId = null;
          _messages = [];
          _liveText = '';
          _liveReasoning = '';
        });
      }
      await _refreshSessions();

      // Deleting the selected session falls back to the newest remaining one
      // (or a fresh session if that was the last one).
      if (_sessionId == null) {
        if (_sessions.isNotEmpty) {
          await _selectSession(_sessions.first.id);
        } else {
          await _newSession(switchTo: true);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'delete failed: $e');
    }
  }

  Future<void> _forkSession(SessionInfo session) async {
    try {
      final forked = await _client.forkSession(session.id);
      await _refreshSessions();
      await _selectSession(forked.id);
      if (mounted) setState(() => _status = 'forked from ${session.displayTitle}');
    } catch (e) {
      if (mounted) setState(() => _error = 'fork failed: $e');
    }
  }

  Future<void> _compactSession() async {
    final id = _sessionId;
    if (id == null) return;
    try {
      await _client.compactSession(id);
      if (mounted) setState(() => _status = 'compacting context…');
    } catch (e) {
      if (mounted) setState(() => _error = 'compact failed: $e');
    }
  }

  // ── Prompting ─────────────────────────────────────────────────────────────

  Future<void> _send() async {
    final text = _input.text.trim();
    if (text.isEmpty || _busy) return;

    var id = _sessionId;
    setState(() {
      _sending = true;
      _error = null;
      _status = 'sending…';
    });
    _input.clear();

    try {
      if (id == null) {
        final session = await _client.createSession(
          agent: _agent?.id,
          providerID: _model?.providerID,
          modelID: _model?.id,
        );
        id = session.id;
        if (mounted) setState(() => _sessionId = id);
        await _refreshSessions();
      }

      // Optimistic echo — the transcript reload at turn end replaces it.
      if (mounted) {
        setState(() {
          _messages = [
            ..._messages,
            ChatMessage(
              id: 'local-${DateTime.now().microsecondsSinceEpoch}',
              role: 'user',
              text: text,
              createdAt: DateTime.now().millisecondsSinceEpoch,
              kind: 'user',
            ),
          ];
          _liveText = '';
          _liveReasoning = '';
        });
        _scrollToBottom();
      }

      await _client.sendPrompt(
        text,
        sessionId: id,
        providerID: _model?.providerID,
        modelID: _model?.id,
        agent: _agent?.id,
      );

      if (mounted) {
        setState(() {
          _running = true;
          _sending = false;
          _status = 'waiting for model…';
        });
      }
      _markRunning(id, true);
      _scheduleSessionsRefresh();
    } catch (e) {
      if (mounted) {
        setState(() {
          _sending = false;
          _running = false;
          _status = 'error';
          _error = '$e';
        });
      }
    }
  }

  Future<void> _interrupt() async {
    final id = _sessionId;
    if (id == null) return;
    try {
      await _client.interrupt(id);
      if (mounted) setState(() => _status = 'stopping…');
    } catch (e) {
      if (mounted) setState(() => _error = 'interrupt failed: $e');
    }
  }

  Future<void> _pickModel(ModelInfo m) async {
    setState(() => _model = m);
    final id = _sessionId;
    if (id == null) return;
    try {
      await _client.setModel(id, providerID: m.providerID, modelID: m.id);
      if (mounted) setState(() => _status = 'model → ${m.id}');
    } catch (e) {
      if (mounted) setState(() => _error = 'model switch failed: $e');
    }
  }

  Future<void> _pickAgent(AgentInfo a) async {
    setState(() => _agent = a);
    final id = _sessionId;
    if (id == null) return;
    try {
      await _client.setAgent(id, a.id);
      if (mounted) setState(() => _status = 'agent → ${a.id}');
    } catch (e) {
      if (mounted) setState(() => _error = 'agent switch failed: $e');
    }
  }

  // ── Scrolling ─────────────────────────────────────────────────────────────

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;

    final main = Column(
      children: [
        if (_error != null) _ErrorBanner(
          message: _error!,
          onDismiss: () => setState(() => _error = null),
        ),
        Expanded(child: _buildTranscript(context)),
        const Divider(height: 1),
        _buildComposer(context),
      ],
    );

    return Scaffold(
      appBar: _buildAppBar(context, showMenuButton: !wide),
      drawer: wide
          ? null
          : Drawer(width: 320, child: _buildSidebar(context, inDrawer: true)),
      body: wide
          ? Row(
              children: [
                SizedBox(width: 320, child: _buildSidebar(context)),
                const VerticalDivider(width: 1),
                Expanded(child: main),
              ],
            )
          : main,
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, {required bool showMenuButton}) {
    final current = _current;
    return AppBar(
      leading: showMenuButton
          ? Builder(
              builder: (ctx) => IconButton(
                icon: const Icon(Icons.menu),
                tooltip: 'Sessions',
                onPressed: () => Scaffold.of(ctx).openDrawer(),
              ),
            )
          : null,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            current?.displayTitle ?? 'OpenCode v2',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 16),
          ),
          Text(
            _status,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.amber, fontSize: 11),
          ),
        ],
      ),
      actions: [
        if (_protocol != null)
          _ProtocolChip(
            label: _protocol!,
            fallback: _client.usingFallback,
          ),
        if (_busy)
          IconButton(
            icon: const Icon(Icons.stop_circle_outlined, color: Colors.redAccent),
            tooltip: 'Stop execution',
            onPressed: _interrupt,
          ),
        _buildModelMenu(),
        _buildAgentMenu(),
        PopupMenuButton<String>(
          tooltip: 'Session actions',
          enabled: _sessionId != null,
          onSelected: (value) {
            switch (value) {
              case 'rename':
                _renameCurrent();
              case 'fork':
                final s = _current;
                if (s != null) _forkSession(s);
              case 'compact':
                _compactSession();
              case 'delete':
                final s = _current;
                if (s != null) _deleteSession(s);
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'rename', child: Text('Rename…')),
            PopupMenuItem(value: 'fork', child: Text('Fork session')),
            PopupMenuItem(value: 'compact', child: Text('Compact context')),
            PopupMenuDivider(),
            PopupMenuItem(value: 'delete', child: Text('Delete session')),
          ],
        ),
      ],
    );
  }

  Widget _buildModelMenu() {
    final label = _model?.id ?? _current?.shortModel ?? 'model';
    return PopupMenuButton<ModelInfo>(
      tooltip: 'Switch model',
      onSelected: _pickModel,
      itemBuilder: (_) {
        if (_models.isEmpty) {
          return const [PopupMenuItem(enabled: false, child: Text('No models'))];
        }
        return _models.map((m) {
          final selected = m.id == _model?.id;
          return PopupMenuItem(
            value: m,
            child: Row(
              children: [
                Icon(selected ? Icons.check : Icons.circle_outlined,
                    size: 16, color: selected ? Colors.amber : Colors.white24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(m.name, overflow: TextOverflow.ellipsis),
                ),
                Text(m.providerID,
                    style: const TextStyle(fontSize: 11, color: Colors.white38)),
              ],
            ),
          );
        }).toList();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            const Icon(Icons.memory, size: 16),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 130),
              child: Text(label, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAgentMenu() {
    return PopupMenuButton<AgentInfo>(
      tooltip: 'Switch agent',
      onSelected: _pickAgent,
      itemBuilder: (_) {
        if (_agents.isEmpty) {
          return const [PopupMenuItem(enabled: false, child: Text('No agents'))];
        }
        return _agents.map((a) {
          final selected = a.id == _agent?.id;
          return PopupMenuItem(
            value: a,
            child: Row(
              children: [
                Icon(selected ? Icons.check : Icons.circle_outlined,
                    size: 16, color: selected ? Colors.amber : Colors.white24),
                const SizedBox(width: 8),
                Text(a.name),
              ],
            ),
          );
        }).toList();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            const Icon(Icons.smart_toy_outlined, size: 16),
            const SizedBox(width: 4),
            Text(_agent?.name ?? 'agent', style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebar(BuildContext context, {bool inDrawer = false}) {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text('Sessions', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh',
                  onPressed: _refreshSessions,
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: 'New session',
                  onPressed: () async {
                    if (inDrawer) Navigator.of(context).pop();
                    await _newSession();
                  },
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _sessions.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No sessions yet.\nTap + to create one.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white38),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: _sessions.length,
                    itemBuilder: (context, i) => _SessionTile(
                      session: _sessions[i],
                      selected: _sessions[i].id == _sessionId,
                      onTap: () {
                        if (inDrawer) Navigator.of(context).pop();
                        _selectSession(_sessions[i].id);
                      },
                      onRename: () {
                        if (inDrawer) Navigator.of(context).pop();
                        _selectSession(_sessions[i].id).then((_) => _renameCurrent());
                      },
                      onFork: () {
                        if (inDrawer) Navigator.of(context).pop();
                        _forkSession(_sessions[i]);
                      },
                      onDelete: () {
                        if (inDrawer) Navigator.of(context).pop();
                        _deleteSession(_sessions[i]);
                      },
                    ),
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _sessionId == null ? 'no session selected' : _sessionId!,
              style: const TextStyle(fontSize: 10, color: Colors.white30),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTranscript(BuildContext context) {
    // Hide opencode's 'idle' markers; keep compaction/model-switch breadcrumbs.
    final showable = _messages
        .where((m) => !(m.isSystem && m.kind == 'idle'))
        .toList();

    final liveVisible = _liveText.isNotEmpty || _liveReasoning.isNotEmpty || _running;

    if (showable.isEmpty && !liveVisible) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Pick a session on the left, or create a new one, then type a prompt.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38),
          ),
        ),
      );
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      itemCount: showable.length + (liveVisible ? 1 : 0),
      itemBuilder: (context, i) {
        if (i < showable.length) {
          return _MessageTile(message: showable[i]);
        }
        return _MessageTile(
          message: ChatMessage(
            id: 'live',
            role: 'assistant',
            text: _liveText,
            reasoning: _liveReasoning,
            createdAt: DateTime.now().millisecondsSinceEpoch,
            kind: 'assistant',
            modelId: _model?.id ?? _current?.modelId,
          ),
          streaming: _running,
        );
      },
    );
  }

  Widget _buildComposer(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              decoration: InputDecoration(
                hintText: _sessionId == null
                    ? 'New session will be created…'
                    : 'Prompt ${_current?.displayTitle ?? ''}…',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              minLines: 1,
              maxLines: 6,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _send,
            icon: Icon(_busy ? Icons.hourglass_top : Icons.send),
            label: Text(_busy ? 'Busy' : 'Send'),
          ),
        ],
      ),
    );
  }
}

// ─── Sidebar tile ─────────────────────────────────────────────────────────────

class _SessionTile extends StatelessWidget {
  final SessionInfo session;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onFork;
  final VoidCallback onDelete;

  const _SessionTile({
    required this.session,
    required this.selected,
    required this.onTap,
    required this.onRename,
    required this.onFork,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      color: selected ? scheme.primaryContainer.withOpacity(0.35) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 9, 4, 9),
          child: Row(
            children: [
              // running indicator
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: session.running
                      ? Colors.amber
                      : (selected ? scheme.primary : Colors.white24),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.displayTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_relativeTime(session.updatedAt)} · ${session.shortModel}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10, color: Colors.white38),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Session actions',
                padding: EdgeInsets.zero,
                iconSize: 18,
                onSelected: (v) {
                  switch (v) {
                    case 'rename':
                      onRename();
                    case 'fork':
                      onFork();
                    case 'delete':
                      onDelete();
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'rename', child: Text('Rename…')),
                  PopupMenuItem(value: 'fork', child: Text('Fork')),
                  PopupMenuDivider(),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _relativeTime(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';
  }
}

// ─── Transcript tile ──────────────────────────────────────────────────────────

class _MessageTile extends StatelessWidget {
  final ChatMessage message;
  final bool streaming;

  const _MessageTile({required this.message, this.streaming = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (message.isSystem) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Text(
            '— ${message.text} —',
            style: const TextStyle(fontSize: 11, color: Colors.white30),
          ),
        ),
      );
    }

    if (message.isUser) {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12, left: 48),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: scheme.primaryContainer.withOpacity(0.45),
            borderRadius: BorderRadius.circular(12),
          ),
          child: SelectableText(
            message.text,
            style: const TextStyle(fontSize: 13, height: 1.4),
          ),
        ),
      );
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14, right: 24),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withOpacity(0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: streaming ? Colors.amber.withOpacity(0.4) : Colors.transparent,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.smart_toy_outlined,
                  size: 14, color: streaming ? Colors.amber : Colors.white38),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  message.modelId == null ? 'assistant' : 'assistant · ${message.modelId}',
                  style: const TextStyle(fontSize: 11, color: Colors.white38),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (message.cost > 0)
                Text('\$${message.cost.toStringAsFixed(4)}',
                    style: const TextStyle(fontSize: 10, color: Colors.white30)),
              if (streaming) ...[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.amber),
                ),
              ],
            ],
          ),
          if (message.reasoning.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            _ReasoningBlock(text: message.reasoning),
          ],
          if (message.text.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(
              message.text,
              style: const TextStyle(fontSize: 13, height: 1.45, fontFamily: 'monospace'),
            ),
          ],
          if (message.tools.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: message.tools
                  .map((t) => _ToolChip(tool: t))
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReasoningBlock extends StatelessWidget {
  final String text;

  const _ReasoningBlock({required this.text});

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        dense: true,
        title: const Text(
          'reasoning',
          style: TextStyle(fontSize: 11, color: Colors.white38),
        ),
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SelectableText(
              text,
              style: const TextStyle(
                fontSize: 11,
                height: 1.4,
                color: Colors.white54,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolChip extends StatelessWidget {
  final ToolCall tool;

  const _ToolChip({required this.tool});

  @override
  Widget build(BuildContext context) {
    final color = switch (tool.status) {
      'completed' => Colors.greenAccent,
      'error' => Colors.redAccent,
      'running' => Colors.amber,
      _ => Colors.white38,
    };

    return Tooltip(
      message: _tooltip(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black26,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withOpacity(0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.build_outlined, size: 12, color: color),
            const SizedBox(width: 5),
            Text(tool.name, style: TextStyle(fontSize: 10, color: color)),
          ],
        ),
      ),
    );
  }

  String _tooltip() {
    final input = tool.input;
    final command = input?['command'] ?? input?['filePath'] ?? input?['path'] ?? input?['query'];
    return [
      '${tool.name} · ${tool.status}',
      if (command != null) '$command',
    ].join('\n');
  }
}

// ─── Protocol chip ────────────────────────────────────────────────────────────

class _ProtocolChip extends StatelessWidget {
  final String label;
  final bool fallback;

  const _ProtocolChip({required this.label, required this.fallback});

  @override
  Widget build(BuildContext context) {
    // QUIC is the point of this app's transport, so make a downgrade obvious
    // rather than hiding it.
    final color = fallback ? Colors.orangeAccent : Colors.greenAccent;

    return Center(
      child: Tooltip(
        message: fallback
            ? 'HTTP/3 was unavailable — running on HTTP/2'
            : 'Connected over QUIC (HTTP/3)',
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black26,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color.withOpacity(0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(fallback ? Icons.swap_horiz : Icons.bolt,
                  size: 12, color: color),
              const SizedBox(width: 5),
              Text(label, style: TextStyle(fontSize: 10, color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Error banner ─────────────────────────────────────────────────────────────

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;

  const _ErrorBanner({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.red.shade900.withOpacity(0.45),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            const Icon(Icons.error_outline, size: 16, color: Colors.redAccent),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                message,
                style: const TextStyle(fontSize: 11, color: Colors.white70),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              tooltip: 'Dismiss',
              onPressed: onDismiss,
            ),
          ],
        ),
      ),
    );
  }
}
