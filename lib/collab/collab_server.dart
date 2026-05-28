import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

typedef CollabMarkupListener = void Function(
  List<Map<String, dynamic>> markups,
);

typedef CollabTeamListener = void Function(
  Map<String, dynamic> teamPayload,
);

class _CollabClient {
  _CollabClient(this.socket);

  final WebSocket socket;
  String ownerId = '';
  String name = 'Guest';
  String teamKey = '';
  bool approved = false;
  bool pending = false;
  bool host = false;

  Map<String, dynamic> toPayload() {
    return {
      'ownerId': ownerId,
      'name': name,
      'teamKey': teamKey,
      'approved': approved,
      'pending': pending,
      'host': host,
    };
  }
}

class CollabServer {
  HttpServer? _server;
  final Map<WebSocket, _CollabClient> _clients = {};
  final List<Map<String, dynamic>> _markups = [];
  final Map<String, Map<String, dynamic>> _teams = {};
  final Set<CollabMarkupListener> _markupListeners = {};
  final Set<CollabTeamListener> _teamListeners = {};
  final Set<String> _lockedOutOwnerIds = {};
  Map<String, dynamic> _latestSnapshot = const {};

  final Random _random = Random.secure();
  String _pairingCode = '';
  String _fieldImageToken = '';
  String? _hostPassword;

  List<int>? _fieldImageBytes;
  String _fieldImageContentType = 'image/png';
  int _fieldImageVersion = 0;
  final String _hostTeamKey = '1591';

  int? get port => _server?.port;
  bool get isRunning => _server != null;
  int get fieldImageVersion => _fieldImageVersion;
  String get pairingCode => _pairingCode;

  void setFieldImage(List<int>? bytes, String contentType) {
    if (bytes == null || bytes.isEmpty) {
      _fieldImageBytes = null;
      _fieldImageVersion++;
      return;
    }

    _fieldImageBytes = List<int>.from(bytes);
    _fieldImageContentType = contentType;
    _fieldImageVersion++;
  }

  void addMarkupListener(CollabMarkupListener listener) {
    _markupListeners.add(listener);
    listener(markups);
  }

  void removeMarkupListener(CollabMarkupListener listener) {
    _markupListeners.remove(listener);
  }

  void addTeamListener(CollabTeamListener listener) {
    _teamListeners.add(listener);
    listener(_buildTeamPayload());
  }

  void removeTeamListener(CollabTeamListener listener) {
    _teamListeners.remove(listener);
  }

  List<Map<String, dynamic>> get markups {
    return List.unmodifiable(
      _markups.map((item) => Map<String, dynamic>.from(item)),
    );
  }

  Future<void> start({
    int preferredPort = 5815,
    Map<String, dynamic> initialSnapshot = const {},
    String hostPassword = '',
  }) async {
    if (_server != null) {
      publishSnapshot(initialSnapshot);
      return;
    }

    _pairingCode = (_random.nextInt(9000) + 1000).toString();
    _fieldImageToken = _randomToken();
    _hostPassword = hostPassword.trim();
    _lockedOutOwnerIds.clear();
    _teams.clear();
    _ensureHostTeam();
    _notifyTeamListeners(_buildTeamPayload());

    _latestSnapshot = initialSnapshot;
    _server = await _bind(preferredPort);
    unawaited(_serve());
  }

  String _randomToken() {
    final values = List<int>.generate(16, (_) => _random.nextInt(256));
    return base64Url.encode(values).replaceAll('=', '');
  }

  Future<HttpServer> _bind(int preferredPort) async {
    Object? lastError;

    for (int port = preferredPort; port < preferredPort + 20; port++) {
      try {
        return await HttpServer.bind(
          InternetAddress.anyIPv4,
          port,
          shared: true,
        );
      } catch (err) {
        lastError = err;
      }
    }

    throw StateError('Could not bind collaboration server: $lastError');
  }

  Future<void> stop() async {
    for (final client in List<_CollabClient>.of(_clients.values)) {
      await client.socket.close();
    }
    _clients.clear();
    _markups.clear();
    _teams.clear();
    _lockedOutOwnerIds.clear();
    _hostPassword = null;
    _notifyTeamListeners(_buildTeamPayload());
    _pairingCode = '';
    _fieldImageToken = '';
    _notifyMarkupListeners();

    await _server?.close(force: true);
    _server = null;
  }

  void publishSnapshot(Map<String, dynamic> snapshot) {
    _latestSnapshot = Map<String, dynamic>.from(snapshot)
      ..['fieldImageToken'] = _fieldImageToken
      ..['teams'] = _buildTeamPayload();

    _broadcastToApproved({
      'type': 'snapshot',
      'snapshot': _latestSnapshot,
    });
  }

  Future<void> _serve() async {
    final server = _server;
    if (server == null) {
      return;
    }

    await for (final request in server) {
      try {
        if (request.uri.path == '/ws') {
          await _handleWebSocket(request);
        } else if (request.uri.path == '/field-image') {
          _writeFieldImage(request);
        } else if (request.uri.path == '/api/session') {
          _writeJson(request, {
            'running': isRunning,
          });
        } else {
          _writeHtml(request, _indexHtml);
        }
      } catch (_) {
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        } catch (_) {
          // The response may already be closed.
        }
      }
    }
  }

  Future<void> _handleWebSocket(HttpRequest request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    final client = _CollabClient(socket);
    _clients[socket] = client;

    _send(socket, {
      'type': 'lobby.ready',
      'hostTeamKey': _hostTeamKey,
    });

    socket.listen(
      (message) {
        if (message is! String) {
          return;
        }

        try {
          final decoded = jsonDecode(message);
          if (decoded is! Map<String, dynamic>) {
            return;
          }

          switch (decoded['type']) {
            case 'lobby.login':
              _handleLobbyLogin(client, decoded, request);
            case 'lobby.approve':
              _handleLobbyApprove(client, decoded);
            case 'lobby.deny':
              _handleLobbyDeny(client, decoded, lockOut: false);
            case 'lobby.kick':
              _handleLobbyKick(client, decoded, lockOut: false);
            case 'lobby.lockout':
              _handleLobbyKick(client, decoded, lockOut: true);
            case 'chat':
              if (client.approved) {
                _broadcastToApproved({
                  'type': 'chat',
                  'name': client.name,
                  'message': decoded['message'] ?? '',
                });
              }
            case 'markup.add':
              if (client.approved) {
                _handleMarkupAdd(client, decoded);
              }
            case 'markup.delete':
              if (client.approved) {
                _handleMarkupDelete(client, decoded);
              }
            case 'markup.clearOwner':
              if (client.approved) {
                _handleMarkupClearOwner(client, decoded);
              }
            case 'team.claim':
              if (client.approved) {
                _handleTeamClaim(client, decoded);
              }
            case 'team.color':
              if (client.approved) {
                _handleTeamColor(client, decoded);
              }
            case 'team.auto':
              if (client.approved) {
                _handleTeamAuto(client, decoded);
              }
            case 'team.clearAuto':
              if (client.approved) {
                _handleTeamClearAuto(client, decoded);
              }
            case 'team.lock':
              if (client.host && client.approved) {
                _handleTeamLock(decoded);
              }
          }
        } catch (_) {
          // Ignore malformed browser messages for now.
        }
      },
      onDone: () => _removeClient(socket),
      onError: (_) => _removeClient(socket),
    );
  }

  void _handleLobbyLogin(
    _CollabClient client,
    Map<String, dynamic> message,
    HttpRequest request,
  ) {
    final ownerId = _safeString(message['ownerId'], fallback: '');
    final name = _safeString(message['name'], fallback: 'Guest');
    final teamKey = _safeString(message['teamKey'], fallback: '');
    final pairingCode = _safeString(message['pairingCode'], fallback: '');
    final hostPassword = _safeString(message['hostPassword'], fallback: '');

    if (ownerId.isEmpty || teamKey.isEmpty || pairingCode != _pairingCode) {
      _send(client.socket, {
        'type': 'lobby.rejected',
        'message': 'Invalid pairing number.',
      });
      return;
    }

    if (_lockedOutOwnerIds.contains(ownerId)) {
      _send(client.socket, {
        'type': 'lobby.rejected',
        'message': 'This browser has been locked out of the session.',
      });
      return;
    }

    client.ownerId = ownerId;
    client.name = name;
    client.teamKey = teamKey;

    if (teamKey == _hostTeamKey) {
      if (_hostPassword == null || _hostPassword!.isEmpty) {
        _send(client.socket, {
          'type': 'lobby.rejected',
          'message':
              'Host password is not configured. Set it in the PathPlanner host app before starting the session.',
        });
        return;
      }

      if (hostPassword != _hostPassword) {
        _send(client.socket, {
          'type': 'lobby.rejected',
          'message': 'Incorrect host team password.',
        });
        return;
      }

      client.host = true;
      client.approved = true;
      client.pending = false;
      _claimTeamForClient(client);
      _sendInitialData(client);
      _broadcastLobbyState();
      return;
    }

    client.host = false;
    client.approved = false;
    client.pending = true;

    _send(client.socket, {
      'type': 'lobby.pending',
      'message': 'Waiting for a host team member to approve you.',
    });
    _broadcastLobbyState();
  }

  void _handleLobbyApprove(
    _CollabClient hostClient,
    Map<String, dynamic> message,
  ) {
    if (!hostClient.host || !hostClient.approved) {
      return;
    }

    final ownerId = _safeString(message['ownerId'], fallback: '');
    if (ownerId.isEmpty) {
      return;
    }

    for (final client in _clients.values) {
      if (client.ownerId == ownerId && client.pending) {
        client.pending = false;
        client.approved = true;
        _claimTeamForClient(client);
        _sendInitialData(client);
      }
    }

    _broadcastLobbyState();
  }

  void _handleLobbyDeny(
    _CollabClient hostClient,
    Map<String, dynamic> message, {
    required bool lockOut,
  }) {
    if (!hostClient.host || !hostClient.approved) {
      return;
    }

    final ownerId = _safeString(message['ownerId'], fallback: '');
    if (ownerId.isEmpty) {
      return;
    }

    if (lockOut) {
      _lockedOutOwnerIds.add(ownerId);
    }

    for (final client in List<_CollabClient>.of(_clients.values)) {
      if (client.ownerId == ownerId && client.pending) {
        _send(client.socket, {
          'type': 'lobby.rejected',
          'message': lockOut
              ? 'You have been locked out of this session.'
              : 'Your request to join was denied.',
        });
        unawaited(client.socket.close());
      }
    }

    _broadcastLobbyState();
  }

  void _handleLobbyKick(
    _CollabClient hostClient,
    Map<String, dynamic> message, {
    required bool lockOut,
  }) {
    if (!hostClient.host || !hostClient.approved) {
      return;
    }

    final ownerId = _safeString(message['ownerId'], fallback: '');
    if (ownerId.isEmpty || ownerId == hostClient.ownerId) {
      return;
    }

    if (lockOut) {
      _lockedOutOwnerIds.add(ownerId);
    }

    for (final client in List<_CollabClient>.of(_clients.values)) {
      if (client.ownerId == ownerId) {
        _clearOwnerClaims(ownerId);
        _send(client.socket, {
          'type': 'lobby.rejected',
          'message': lockOut
              ? 'You have been locked out of this session.'
              : 'You have been removed from this session.',
        });
        unawaited(client.socket.close());
      }
    }

    _broadcastTeamSnapshot();
    _broadcastLobbyState();
  }

  void _claimTeamForClient(_CollabClient client) {
    _clearOwnerClaims(client.ownerId, exceptTeamKey: client.teamKey);

    final team = _teamForKey(client.teamKey);
    team['claimed'] = true;
    team['claimedBy'] = client.host ? 'Host' : client.name;
    team['lastOwnerId'] = client.ownerId;

    if (client.host) {
      team['host'] = true;
    }

    _broadcastTeamSnapshot();
  }

  void _clearOwnerClaims(String ownerId, {String? exceptTeamKey}) {
    for (final key in List<String>.of(_teams.keys)) {
      if (key == exceptTeamKey) {
        continue;
      }

      final team = _teams[key];
      if (team == null || team['lastOwnerId'] != ownerId) {
        continue;
      }

      final locked = team['locked'] == true;
      final host = team['host'] == true;

      if (locked || host) {
        team.remove('lastOwnerId');
        team.remove('claimedBy');
        team.remove('claimed');
        team.remove('auto');
      } else {
        _teams.remove(key);
      }
    }
  }

  void _sendInitialData(_CollabClient client) {
    _send(client.socket, {
      'type': 'lobby.approved',
      'client': client.toPayload(),
    });
    _send(client.socket, {
      'type': 'snapshot',
      'snapshot': _latestSnapshot,
    });
    _send(client.socket, {
      'type': 'markup.snapshot',
      'markups': _markups,
    });
    _send(client.socket, {
      'type': 'team.snapshot',
      ..._buildTeamPayload(),
    });
    _send(client.socket, {
      'type': 'lobby.state',
      ..._buildLobbyPayload(),
    });
  }

  void _broadcastLobbyState() {
    _broadcastToHosts({
      'type': 'lobby.state',
      ..._buildLobbyPayload(),
    });
  }

  Map<String, dynamic> _buildLobbyPayload() {
    final pending = <Map<String, dynamic>>[];
    final approved = <Map<String, dynamic>>[];

    for (final client in _clients.values) {
      if (client.pending) {
        pending.add(client.toPayload());
      } else if (client.approved) {
        approved.add(client.toPayload());
      }
    }

    return {
      'pending': pending,
      'approved': approved,
    };
  }

  void _handleTeamClaim(
    _CollabClient client,
    Map<String, dynamic> message,
  ) {
    final key = _safeString(message['teamKey'], fallback: '');
    if (key.isEmpty || key == _hostTeamKey) {
      return;
    }

    client.teamKey = key;
    _claimTeamForClient(client);
    _broadcastLobbyState();
  }

  void _handleTeamColor(
    _CollabClient client,
    Map<String, dynamic> message,
  ) {
    final key = _safeString(message['teamKey'], fallback: '');
    final color = message['color'];

    if (key.isEmpty || color is! String || color.isEmpty) {
      return;
    }

    final team = _teamForKey(key);
    if (team['locked'] == true || team['lastOwnerId'] != client.ownerId) {
      return;
    }

    team['color'] = color;
    _broadcastTeamSnapshot();
  }

  void _handleTeamAuto(
    _CollabClient client,
    Map<String, dynamic> message,
  ) {
    final key = _safeString(message['teamKey'], fallback: '');
    final auto = message['auto'];

    if (key.isEmpty || auto is! Map<String, dynamic>) {
      return;
    }

    final team = _teamForKey(key);
    if (team['locked'] == true ||
        _hostTeamKey == key ||
        team['lastOwnerId'] != client.ownerId) {
      return;
    }

    team['auto'] = auto;
    team['claimedBy'] = client.name;
    team['claimed'] = true;
    _broadcastTeamSnapshot();
  }

  void _handleTeamClearAuto(
    _CollabClient client,
    Map<String, dynamic> message,
  ) {
    final key = _safeString(message['teamKey'], fallback: '');

    if (key.isEmpty) {
      return;
    }

    final team = _teamForKey(key);
    if (team['locked'] == true ||
        _hostTeamKey == key ||
        team['lastOwnerId'] != client.ownerId) {
      return;
    }

    team.remove('auto');
    _broadcastTeamSnapshot();
  }

  void _handleTeamLock(Map<String, dynamic> message) {
    final key = _safeString(message['teamKey'], fallback: '');

    if (key.isEmpty) {
      return;
    }

    final team = _teamForKey(key);
    team['locked'] = message['locked'] == true;
    _broadcastTeamSnapshot();
  }

  void _ensureHostTeam() {
    final team = _teamForKey(_hostTeamKey);
    team['claimed'] = true;
    team['claimedBy'] = 'Host';
    team['host'] = true;
  }

  Map<String, dynamic> _teamForKey(String key) {
    return _teams.putIfAbsent(key, () => {
          'key': key,
          'locked': false,
        });
  }

  String _safeString(Object? value, {required String fallback}) {
    if (value is String && value.trim().isNotEmpty) {
      return value.trim();
    }

    return fallback;
  }

  Map<String, dynamic> _buildTeamPayload() {
    return {
      'hostTeamKey': _hostTeamKey,
      'teams': _teams.values.map((item) => Map<String, dynamic>.from(item)).toList(),
    };
  }

  void _broadcastTeamSnapshot() {
    final payload = _buildTeamPayload();

    _latestSnapshot = Map<String, dynamic>.from(_latestSnapshot)
      ..['teams'] = payload;

    _notifyTeamListeners(payload);
    _broadcastToApproved({
      'type': 'team.snapshot',
      ...payload,
    });
    _broadcastToApproved({
      'type': 'snapshot',
      'snapshot': _latestSnapshot,
    });
  }

  void _notifyTeamListeners(Map<String, dynamic> payload) {
    final snapshot = Map<String, dynamic>.from(payload);

    for (final listener in List<CollabTeamListener>.of(_teamListeners)) {
      listener(snapshot);
    }
  }

  void _handleMarkupAdd(
    _CollabClient client,
    Map<String, dynamic> message,
  ) {
    final entity = message['entity'];
    if (entity is! Map<String, dynamic>) {
      return;
    }

    final id = entity['id'];
    final ownerId = entity['ownerId'];
    final points = entity['points'];

    if (id is! String ||
        ownerId is! String ||
        ownerId != client.ownerId ||
        points is! List ||
        points.length < 2) {
      return;
    }

    _markups.removeWhere((item) => item['id'] == id);
    _markups.add(entity);
    _notifyMarkupListeners();

    _broadcastToApproved({
      'type': 'markup.add',
      'entity': entity,
    });
  }

  void _handleMarkupDelete(
    _CollabClient client,
    Map<String, dynamic> message,
  ) {
    final id = message['id'];
    final ownerId = message['ownerId'];

    if (id is! String || ownerId is! String || ownerId != client.ownerId) {
      return;
    }

    final canDelete = _markups.any(
      (item) => item['id'] == id && item['ownerId'] == ownerId,
    );

    if (!canDelete) {
      return;
    }

    _markups.removeWhere(
      (item) => item['id'] == id && item['ownerId'] == ownerId,
    );
    _notifyMarkupListeners();

    _broadcastToApproved({
      'type': 'markup.delete',
      'id': id,
    });
  }

  void _handleMarkupClearOwner(
    _CollabClient client,
    Map<String, dynamic> message,
  ) {
    final ownerId = message['ownerId'];
    if (ownerId is! String || ownerId != client.ownerId) {
      return;
    }

    _markups.removeWhere((item) => item['ownerId'] == ownerId);
    _notifyMarkupListeners();

    _broadcastToApproved({
      'type': 'markup.clearOwner',
      'ownerId': ownerId,
    });
  }

  void _notifyMarkupListeners() {
    final snapshot = markups;

    for (final listener in List<CollabMarkupListener>.of(_markupListeners)) {
      listener(snapshot);
    }
  }

  void _send(WebSocket socket, Map<String, dynamic> message) {
    if (socket.readyState == WebSocket.open) {
      socket.add(jsonEncode(message));
    }
  }

  void _broadcastToApproved(Map<String, dynamic> message) {
    for (final client in List<_CollabClient>.of(_clients.values)) {
      if (client.approved && client.socket.readyState == WebSocket.open) {
        _send(client.socket, message);
      }
    }
  }

  void _broadcastToHosts(Map<String, dynamic> message) {
    for (final client in List<_CollabClient>.of(_clients.values)) {
      if (client.approved &&
          client.host &&
          client.socket.readyState == WebSocket.open) {
        _send(client.socket, message);
      }
    }
  }

  void _removeClient(WebSocket socket) {
    _clients.remove(socket);
    _broadcastLobbyState();
  }

  void _writeJson(HttpRequest request, Map<String, dynamic> data) {
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(data));
    unawaited(request.response.close());
  }

  void _writeFieldImage(HttpRequest request) {
    final token = request.uri.queryParameters['token'];
    if (token != _fieldImageToken || token == null || token.isEmpty) {
      request.response.statusCode = HttpStatus.forbidden;
      unawaited(request.response.close());
      return;
    }

    final bytes = _fieldImageBytes;
    if (bytes == null || bytes.isEmpty) {
      request.response.statusCode = HttpStatus.notFound;
      unawaited(request.response.close());
      return;
    }

    request.response.headers.set(
      HttpHeaders.contentTypeHeader,
      _fieldImageContentType,
    );
    request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    request.response.add(bytes);
    unawaited(request.response.close());
  }

  void _writeHtml(HttpRequest request, String html) {
    request.response.headers.contentType = ContentType.html;
    request.response.write(html);
    unawaited(request.response.close());
  }
}

const String _indexHtml = r'''
<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <title>PathPlanner Auto Collaboration</title>
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <style>
    :root {
      color-scheme: dark;
      font-family: system-ui, -apple-system, Segoe UI, sans-serif;
      background: #101114;
      color: #f3f3f3;
    }
    body { margin: 0; padding: 18px; background: #101114; }
    header { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 14px; }
    h1 { font-size: 20px; margin: 0; }
    h2 { margin-top: 0; font-size: 17px; }
    h3 { margin: 12px 0 6px; font-size: 14px; }
    .status { padding: 6px 10px; border-radius: 999px; background: #30323a; font-size: 13px; }
    .grid { display: grid; grid-template-columns: minmax(0, 2fr) minmax(350px, 1fr); gap: 14px; }
    .stack { display: grid; gap: 14px; }
    .card { background: #1b1d22; border: 1px solid #30323a; border-radius: 14px; padding: 14px; box-shadow: 0 6px 20px rgba(0,0,0,0.22); }
    .row { padding: 10px 0 12px; border-bottom: 1px solid #30323a; }
    .row:last-child { border-bottom: none; }
    .muted { color: #aeb4c0; font-size: 13px; }
    .pill { display: inline-flex; align-items: center; gap: 6px; padding: 4px 8px; border-radius: 999px; background: #30323a; font-size: 12px; margin: 2px 4px 2px 0; }
    .dot { width: 10px; height: 10px; border-radius: 999px; background: var(--dot, #8cc4ff); }
    input, button, select { border-radius: 10px; border: 1px solid #3a3d47; background: #101114; color: #f3f3f3; padding: 10px; font: inherit; }
    input[type="range"] { padding: 0; }
    input[type="file"] { max-width: 100%; }
    button { cursor: pointer; background: #2c65d8; border-color: #2c65d8; }
    button.secondary { background: #30323a; border-color: #3a3d47; }
    button.danger { background: #8d2b34; border-color: #8d2b34; }
    button.active { outline: 2px solid #f0c84b; }
    button:disabled { opacity: 0.45; cursor: not-allowed; }
    button:hover:not(:disabled) { filter: brightness(1.1); }
    .toolbar { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin-bottom: 10px; }
    .chat-log { height: 220px; overflow: auto; border: 1px solid #30323a; border-radius: 10px; padding: 8px; background: #111217; margin-bottom: 8px; }
    .chat-line { margin-bottom: 8px; font-size: 14px; }
    .timeline { position: relative; height: 20px; background: #101114; border: 1px solid #30323a; border-radius: 999px; overflow: hidden; margin-top: 8px; }
    .timeline-segment { position: absolute; top: 0; bottom: 0; min-width: 3px; border-right: 1px solid rgba(0,0,0,0.28); }
    .timeline-segment.drive { opacity: 0.96; }
    .timeline-segment.hold { background: #f0c84b; }
    .timeline-segment.slow { background: #c77dff; }
    .timeline-empty { position: absolute; top: 0; bottom: 0; background: rgba(255,255,255,0.07); }
    .legend { display: flex; flex-wrap: wrap; gap: 12px; margin-top: 12px; margin-bottom: 8px; font-size: 13px; color: #c8ced8; }
    .legend-item { display: inline-flex; align-items: center; gap: 6px; }
    .legend-box { width: 18px; height: 10px; border-radius: 99px; }
    .segments { margin-top: 6px; display: flex; flex-wrap: wrap; gap: 5px; }
    .segment-chip { font-size: 12px; padding: 3px 7px; border-radius: 999px; background: #30323a; color: #d7dce6; }
    .segment-chip.hold { background: #6a5721; }
    .segment-chip.slow { background: #50346a; }
    .field-wrap { position: relative; width: 100%; aspect-ratio: var(--field-aspect, 1.7); min-height: 320px; border-radius: 12px; overflow: hidden; border: 1px solid #30323a; background: #111217; }
    #fieldCanvas { width: 100%; height: 100%; touch-action: none; display: block; cursor: none; }
    .scrub-row { display: grid; grid-template-columns: auto 1fr auto; gap: 10px; align-items: center; }
    .side-section { border: 1px solid #30323a; border-radius: 12px; padding: 10px; margin-bottom: 12px; background: #15171c; }
    .form-grid { display: grid; gap: 8px; }
    .team-row { border-top: 1px solid #30323a; padding: 8px 0; }
    .team-row:first-child { border-top: 0; }
    .team-title { display: flex; align-items: center; justify-content: space-between; gap: 8px; }
    .team-actions { display: flex; flex-wrap: wrap; gap: 6px; margin-top: 6px; }
    .small-btn { padding: 6px 8px; font-size: 12px; }
    .login-overlay { position: fixed; inset: 0; background: rgba(0,0,0,0.72); z-index: 99; display: flex; align-items: center; justify-content: center; padding: 18px; }
    .login-card { width: min(460px, 100%); background: #1b1d22; border: 1px solid #30323a; border-radius: 18px; padding: 18px; box-shadow: 0 16px 50px rgba(0,0,0,0.45); }
    .hidden { display: none !important; }
    @media (max-width: 900px) { .grid { grid-template-columns: 1fr; } }
  </style>
</head>
<body>
  <div id="loginOverlay" class="login-overlay">
    <div class="login-card">
      <h2>Join Collaboration Session</h2>
      <div class="muted">Enter your name, team number, and the host's 4 digit pairing number. You will wait in the lobby until a host team member approves you.</div>
      <br />
      <div class="form-grid">
        <input id="loginName" placeholder="Your name" />
        <input id="loginTeam" placeholder="Team number, ex: 191 or 190-2" />
        <div id="loginTeamLookup" class="muted">Enter a Battlecry team number.</div>
        <input id="loginPairing" placeholder="4 digit pairing number" maxlength="4" />
        <input id="loginHostPassword" type="password" class="hidden" placeholder="1591 host password" />
        <div id="loginHostNote" class="muted hidden">1591 members need the host password. The 1591 password is configured in the PathPlanner host app before the session starts.</div>
        <button id="loginJoin">Join Lobby</button>
        <div id="loginStatus" class="muted"></div>
      </div>
    </div>
  </div>

  <header>
    <div>
      <h1>PathPlanner Auto Collaboration</h1>
      <div class="muted">Data is only sent after lobby approval.</div>
    </div>
    <div id="status" class="status">Connecting...</div>
  </header>

  <div class="grid">
    <div class="stack">
      <main class="card">
        <h2>Field / Markup</h2>
        <div class="toolbar">
          <button id="playPause" class="secondary">Pause</button>
          <span id="fieldTimeLabel" class="muted">0.00s</span>
          <button id="drawMode" class="secondary active">Draw</button>
          <button id="eraseMode" class="secondary">Erase</button>
          <label class="muted">Color <input id="markupColor" type="color" value="#ff4fd8" style="padding:2px; width:46px;" /></label>
          <label class="muted">Width
            <select id="markupWidth">
              <option value="3">Thin</option>
              <option value="5" selected>Normal</option>
              <option value="8">Thick</option>
            </select>
          </label>
          <button id="clearMarkup" class="danger">Clear</button>
        </div>
        <div class="scrub-row">
          <span class="muted">0</span>
          <input id="fieldTime" type="range" min="0" max="0" step="0.01" value="0" />
          <span id="fieldTotalLabel" class="muted">0.00s</span>
        </div>
        <br />
        <div id="fieldWrap" class="field-wrap">
          <canvas id="fieldCanvas"></canvas>
        </div>
      </main>

      <main class="card">
        <h2>Active Match</h2>
        <div id="summary" class="muted">Join the lobby to load session data.</div>
        <div class="legend">
          <span class="legend-item"><span id="driveLegend" class="legend-box"></span>Driving</span>
          <span class="legend-item"><span class="legend-box" style="background:#f0c84b"></span>Hold wait</span>
          <span class="legend-item"><span class="legend-box" style="background:#c77dff"></span>Slow zone</span>
          <span class="legend-item"><span class="legend-box" style="background:rgba(255,255,255,0.15)"></span>Finished</span>
        </div>
        <div id="autos"></div>
      </main>
    </div>

    <aside class="card">
      <h2>Teams</h2>

      <div id="hostLobby" class="side-section hidden">
        <h3>Host Lobby</h3>
        <div class="muted">Approve, kick, or lock people out of this browser session.</div>
        <div id="pendingList"></div>
        <div id="approvedList"></div>
      </div>

      <div class="side-section">
        <h3>Your Team</h3>
        <div class="form-grid">
          <input id="teamInput" placeholder="Team number, ex: 191 or 190-2" />
          <div id="teamLookup" class="muted">Enter a Battlecry team number.</div>
          <button id="claimTeam">Switch Team</button>
          <label class="muted">Overlay Color <input id="teamColor" type="color" value="#4f8cff" style="padding:2px; width:54px;" /></label>
          <input id="autoFiles" type="file" accept=".auto,.path" multiple />
          <div class="muted">Select one .auto plus all referenced .path files, or select a folder below.</div>
          <input id="autoFolderFiles" type="file" webkitdirectory directory multiple />
          <select id="autoSelect" disabled><option value="">No .auto files selected</option></select>
          <button id="uploadAuto">Upload PathPlanner Auto</button>
          <button id="clearTeamAuto" class="danger">Clear Uploaded Auto</button>
          <div id="teamStatus" class="muted">Join the lobby first.</div>
        </div>
      </div>

      <div class="side-section">
        <h3>Claimed Teams</h3>
        <div id="teamList"></div>
      </div>

      <h2>Session Chat</h2>
      <input id="name" placeholder="Your team/name" value="Guest" />
      <br /><br />
      <div id="chat" class="chat-log"></div>
      <div style="display:flex; gap:8px;">
        <input id="message" placeholder="Message" style="flex:1;" />
        <button id="send">Send</button>
      </div>
    </aside>
  </div>

  <script>
    const TEAM_LIST = [{"key":"48","teamNumber":"48","colorLookup":48,"name":"Team E.L.I.T.E."},{"key":"126","teamNumber":"126","colorLookup":126,"name":"Gael Force"},{"key":"131","teamNumber":"131","colorLookup":131,"name":"CHAOS"},{"key":"151","teamNumber":"151","colorLookup":151,"name":"Tough Techs"},{"key":"157","teamNumber":"157","colorLookup":157,"name":"Aztechs"},{"key":"166","teamNumber":"166","colorLookup":166,"name":"Chop Shop"},{"key":"173","teamNumber":"173","colorLookup":173,"name":"Rage Robotics"},{"key":"190","teamNumber":"190","colorLookup":190,"name":"Gompei & the HERD"},{"key":"190-2","teamNumber":"190-2","colorLookup":190,"name":"Chompei & the HERD"},{"key":"238","teamNumber":"238","colorLookup":238,"name":"Crusaders"},{"key":"271","teamNumber":"271","colorLookup":271,"name":"Mechanical Marauders"},{"key":"467","teamNumber":"467","colorLookup":467,"name":"Center of Mass"},{"key":"516","teamNumber":"516","colorLookup":694,"name":"StuyPlus"},{"key":"694","teamNumber":"694","colorLookup":694,"name":"Stuypulse"},{"key":"1155","teamNumber":"1155","colorLookup":1155,"name":"SciBorgs"},{"key":"1277","teamNumber":"1277","colorLookup":1277,"name":"Robotomies"},{"key":"1474","teamNumber":"1474","colorLookup":1474,"name":"Tewksbury Titans"},{"key":"1591","teamNumber":"1591","colorLookup":1591,"name":"Greece Gladiators"},{"key":"1729","teamNumber":"1729","colorLookup":1729,"name":"Team Inconceivable!"},{"key":"1735","teamNumber":"1735","colorLookup":1735,"name":"Green Reapers"},{"key":"1768","teamNumber":"1768","colorLookup":1768,"name":"Nashoba Robotics"},{"key":"1922","teamNumber":"1922","colorLookup":1922,"name":"Oz-Ram"},{"key":"2262","teamNumber":"2262","colorLookup":2262,"name":"RoboPanthers"},{"key":"2265","teamNumber":"2265","colorLookup":2265,"name":"FeMaidens"},{"key":"2342","teamNumber":"2342","colorLookup":2342,"name":"Phoenix"},{"key":"2370","teamNumber":"2370","colorLookup":2370,"name":"iBOTs"},{"key":"2423","teamNumber":"2423","colorLookup":2423,"name":"The KwarQs"},{"key":"3461","teamNumber":"3461","colorLookup":3461,"name":"Operation PEACCE Robotics"},{"key":"4122","teamNumber":"4122","colorLookup":4122,"name":"Ossining"},{"key":"4176","teamNumber":"4176","colorLookup":4176,"name":"Iron Tigers"},{"key":"4546","teamNumber":"4546","colorLookup":4546,"name":"Shockwave"},{"key":"4575","teamNumber":"4575","colorLookup":4575,"name":"Gemini"},{"key":"5494","teamNumber":"5494","colorLookup":5494,"name":"Bizarbots"},{"key":"5735","teamNumber":"5735","colorLookup":5735,"name":"Control Freaks"},{"key":"5813","teamNumber":"5813","colorLookup":5813,"name":"Morpheus"},{"key":"6153","teamNumber":"6153","colorLookup":6153,"name":"Blue Crew"},{"key":"6731","teamNumber":"6731","colorLookup":6731,"name":"Record Robotics"},{"key":"6933","teamNumber":"6933","colorLookup":6933,"name":"Archytas"},{"key":"7153","teamNumber":"7153","colorLookup":7153,"name":"Aetos Dios"},{"key":"8085","teamNumber":"8085","colorLookup":8085,"name":"MOJO"},{"key":"8544","teamNumber":"8544","colorLookup":8544,"name":"Reinforcement"},{"key":"8567","teamNumber":"8567","colorLookup":8567,"name":"Team Ultraviolet"},{"key":"8708","teamNumber":"8708","colorLookup":8708,"name":"Ov3R1y K0mp13X"},{"key":"8724","teamNumber":"8724","colorLookup":8724,"name":"Mayhem"},{"key":"10063","teamNumber":"10063","colorLookup":10063,"name":"SCRAP"},{"key":"10262","teamNumber":"10262","colorLookup":10262,"name":"Bionic Buzzers"},{"key":"10910","teamNumber":"10910","colorLookup":10910,"name":"The Outlaws"},{"key":"11175","teamNumber":"11175","colorLookup":11175,"name":"Tidal Shock"}];

    const statusEl = document.getElementById('status');
    const summaryEl = document.getElementById('summary');
    const autosEl = document.getElementById('autos');
    const chatEl = document.getElementById('chat');
    const nameEl = document.getElementById('name');
    const messageEl = document.getElementById('message');
    const sendEl = document.getElementById('send');
    const driveLegendEl = document.getElementById('driveLegend');

    const loginOverlayEl = document.getElementById('loginOverlay');
    const loginNameEl = document.getElementById('loginName');
    const loginTeamEl = document.getElementById('loginTeam');
    const loginTeamLookupEl = document.getElementById('loginTeamLookup');
    const loginPairingEl = document.getElementById('loginPairing');
    const loginHostPasswordEl = document.getElementById('loginHostPassword');
    const loginHostNoteEl = document.getElementById('loginHostNote');
    const loginJoinEl = document.getElementById('loginJoin');
    const loginStatusEl = document.getElementById('loginStatus');

    const fieldCanvas = document.getElementById('fieldCanvas');
    const fieldCtx = fieldCanvas.getContext('2d');
    const fieldWrapEl = document.getElementById('fieldWrap');
    const playPauseEl = document.getElementById('playPause');
    const fieldTimeEl = document.getElementById('fieldTime');
    const fieldTimeLabelEl = document.getElementById('fieldTimeLabel');
    const fieldTotalLabelEl = document.getElementById('fieldTotalLabel');

    const drawModeEl = document.getElementById('drawMode');
    const eraseModeEl = document.getElementById('eraseMode');
    const colorEl = document.getElementById('markupColor');
    const widthEl = document.getElementById('markupWidth');
    const clearEl = document.getElementById('clearMarkup');

    const hostLobbyEl = document.getElementById('hostLobby');
    const pendingListEl = document.getElementById('pendingList');
    const approvedListEl = document.getElementById('approvedList');
    const teamInputEl = document.getElementById('teamInput');
    const teamLookupEl = document.getElementById('teamLookup');
    const claimTeamEl = document.getElementById('claimTeam');
    const teamColorEl = document.getElementById('teamColor');
    const autoFilesEl = document.getElementById('autoFiles');
    const autoFolderFilesEl = document.getElementById('autoFolderFiles');
    const autoSelectEl = document.getElementById('autoSelect');
    const uploadAutoEl = document.getElementById('uploadAuto');
    const clearTeamAutoEl = document.getElementById('clearTeamAuto');
    const teamStatusEl = document.getElementById('teamStatus');
    const teamListEl = document.getElementById('teamList');

    const CLIENT_ID_KEY = 'pathplannerCollabClientId';
    let clientId = sessionStorage.getItem(CLIENT_ID_KEY);
    if (!clientId) {
      clientId = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
      sessionStorage.setItem(CLIENT_ID_KEY, clientId);
    }

    loginNameEl.value = localStorage.getItem('pathplannerCollabName') || '';
    loginTeamEl.value = sessionStorage.getItem('pathplannerCollabTeamKey') || '';
    loginHostPasswordEl.value = localStorage.getItem('pathplannerCollab1591Password') || '';

    const fieldImage = new Image();
    let fieldImageVersion = null;
    let fieldImageToken = '';
    fieldImage.onload = () => renderFieldPreview();

    let ws;
    let approved = false;
    let isHost = false;
    let latestSnapshot = null;
    let fieldGeometry = null;
    let teamStates = new Map();
    let hostTeamKey = '1591';
    let selectedTeamKey = sessionStorage.getItem('pathplannerCollabTeamKey') || '';
    let claimedTeamKey = sessionStorage.getItem('pathplannerCollabClaimedTeamKey') || '';
    let frcColorMap = new Map();

    let playheadSeconds = 0;
    let playing = true;
    let lastFrameMs = null;

    let mode = 'draw';
    let markups = [];
    let activeEntity = null;
    let drawing = false;
    let erasing = false;
    let erasedThisGesture = new Set();
    let cursorPoint = null;

    function initTeams() {
      teamInputEl.value = selectedTeamKey;
      refreshLoginTeam();
      refreshTeamInputs();
      renderTeamPanel();
      fetchTeamColors();
    }

    function normalizeTeamKey(raw) {
      const value = String(raw || '').trim();
      if (!value) return '';

      if (value.includes('-')) {
        const [first, second] = value.split('-');
        const number = Number(first);
        return Number.isFinite(number) ? `${number}-${second.trim()}` : value;
      }

      const number = Number(value);
      return Number.isFinite(number) ? String(number) : value;
    }

    function teamDef(teamKey) {
      return TEAM_LIST.find((team) => team.key === teamKey);
    }

    function teamLabel(teamKey) {
      const team = teamDef(teamKey);
      return team ? `${team.teamNumber} - ${team.name}` : '';
    }

    function refreshLoginTeam() {
      const teamKey = normalizeTeamKey(loginTeamEl.value);
      const def = teamDef(teamKey);
      loginTeamLookupEl.textContent = def
        ? teamLabel(teamKey)
        : (teamKey ? `Team ${teamKey} is not on the Battlecry list.` : 'Enter a Battlecry team number.');

      const isHostTeam = teamKey === hostTeamKey;
      loginHostPasswordEl.classList.toggle('hidden', !isHostTeam);
      loginHostNoteEl.classList.toggle('hidden', !isHostTeam);
      loginJoinEl.disabled = !def;
    }

    function refreshTeamInputs() {
      selectedTeamKey = normalizeTeamKey(teamInputEl.value);
      const def = teamDef(selectedTeamKey);
      const state = teamStates.get(selectedTeamKey) || {};
      const locked = state.locked === true || hostTeamKey === selectedTeamKey;

      if (def) {
        teamLookupEl.textContent = teamLabel(selectedTeamKey);
        if (!state.color && document.activeElement !== teamColorEl) {
          teamColorEl.value = teamPrimaryColor(selectedTeamKey);
        } else if (state.color && document.activeElement !== teamColorEl) {
          teamColorEl.value = state.color;
        }
      } else {
        teamLookupEl.textContent = selectedTeamKey
          ? `Team ${selectedTeamKey} is not on the Battlecry list.`
          : 'Enter a Battlecry team number.';
      }

      const canUseTeam = approved && Boolean(def) && claimedTeamKey === selectedTeamKey && !locked && !isHost;
      claimTeamEl.disabled = !approved || !def || isHost || selectedTeamKey === claimedTeamKey;
      uploadAutoEl.disabled = !canUseTeam;
      clearTeamAutoEl.disabled = !canUseTeam;
      teamColorEl.disabled = !canUseTeam;

      if (!approved) {
        teamStatusEl.textContent = 'Join the lobby first.';
      } else if (isHost) {
        teamStatusEl.textContent = 'Host team privileges active.';
      } else if (def) {
        teamStatusEl.textContent = claimedTeamKey === selectedTeamKey
          ? `Claimed ${teamLabel(selectedTeamKey)}${locked ? ' (Child Lock)' : ''}`
          : `Switch to ${teamLabel(selectedTeamKey)}. Your old team will be removed from claimed teams.`;
      } else {
        teamStatusEl.textContent = 'Enter a valid Battlecry team number.';
      }
    }

    async function fetchTeamColors() {
      const lookupTeams = [...new Set(TEAM_LIST.map((team) => team.colorLookup))];
      const query = lookupTeams.map((team) => `team=${team}`).join('&');

      try {
        const response = await fetch(`https://api.frc-colors.com/v1/team?${query}`);
        if (!response.ok) throw new Error(`HTTP ${response.status}`);

        const data = await response.json();
        const teams = data.teams || {};

        for (const [number, value] of Object.entries(teams)) {
          const color = value?.colors?.primaryHex;
          if (typeof color === 'string' && color.startsWith('#')) {
            frcColorMap.set(String(number), color);
          }
        }

        refreshTeamInputs();
        renderTeamPanel();
      } catch (err) {
        teamStatusEl.textContent = 'Could not fetch frc.colors colors. Using fallback colors.';
      }
    }

    function teamPrimaryColor(teamKey) {
      const team = teamDef(teamKey);
      if (!team) return '#4f8cff';

      return frcColorMap.get(String(team.colorLookup)) || fallbackTeamColor(teamKey);
    }

    function fallbackTeamColor(teamKey) {
      const colors = ['#4f8cff', '#ff4fd8', '#f0c84b', '#42d392', '#ff7a45', '#c77dff', '#45d6ff'];
      const text = String(teamKey || '0');
      let hash = 0;
      for (let i = 0; i < text.length; i++) {
        hash = ((hash << 5) - hash + text.charCodeAt(i)) | 0;
      }
      return colors[Math.abs(hash) % colors.length];
    }

    function connect() {
      ws = new WebSocket(`ws://${location.host}/ws`);

      ws.onopen = () => {
        statusEl.textContent = 'Connected, login required';
      };

      ws.onclose = () => {
        approved = false;
        statusEl.textContent = 'Disconnected, retrying...';
        loginOverlayEl.classList.remove('hidden');
        setTimeout(connect, 1000);
      };

      ws.onmessage = (event) => {
        const msg = JSON.parse(event.data);

        if (msg.type === 'lobby.ready') {
          hostTeamKey = msg.hostTeamKey || '1591';
          refreshLoginTeam();
        } else if (msg.type === 'lobby.pending') {
          loginStatusEl.textContent = msg.message || 'Waiting for host approval.';
          statusEl.textContent = 'Waiting in lobby';
        } else if (msg.type === 'lobby.rejected') {
          approved = false;
          loginOverlayEl.classList.remove('hidden');
          loginStatusEl.textContent = msg.message || 'Rejected.';
          statusEl.textContent = 'Not in session';
        } else if (msg.type === 'lobby.approved') {
          approved = true;
          isHost = msg.client?.host === true;
          claimedTeamKey = msg.client?.teamKey || claimedTeamKey;
          selectedTeamKey = claimedTeamKey;
          teamInputEl.value = claimedTeamKey;
          sessionStorage.setItem('pathplannerCollabClaimedTeamKey', claimedTeamKey);
          sessionStorage.setItem('pathplannerCollabTeamKey', claimedTeamKey);
          loginOverlayEl.classList.add('hidden');
          statusEl.textContent = isHost ? 'Host approved' : 'Approved';
          refreshTeamInputs();
          renderTeamPanel();
        } else if (msg.type === 'lobby.state') {
          renderLobbyState(msg);
        } else if (msg.type === 'snapshot') {
          renderSnapshot(msg.snapshot || {});
          if (msg.snapshot?.teams) {
            applyTeamPayload(msg.snapshot.teams);
          }
        } else if (msg.type === 'team.snapshot') {
          applyTeamPayload(msg);
        } else if (msg.type === 'markup.snapshot') {
          markups = Array.isArray(msg.markups) ? msg.markups : [];
          renderFieldPreview();
        } else if (msg.type === 'markup.add') {
          markups = markups.filter((item) => item.id !== msg.entity.id);
          markups.push(msg.entity);
          renderFieldPreview();
        } else if (msg.type === 'markup.delete') {
          markups = markups.filter((item) => item.id !== msg.id);
          renderFieldPreview();
        } else if (msg.type === 'markup.clearOwner') {
          markups = markups.filter((item) => item.ownerId !== msg.ownerId);
          renderFieldPreview();
        } else if (msg.type === 'chat') {
          addChat(`${msg.name}: ${msg.message}`);
        }
      };
    }

    function renderLobbyState(state) {
      hostLobbyEl.classList.toggle('hidden', !isHost);
      if (!isHost) return;

      pendingListEl.innerHTML = '<h3>Pending</h3>';
      const pending = state.pending || [];
      if (pending.length === 0) {
        pendingListEl.innerHTML += '<div class="muted">No pending users.</div>';
      }

      for (const client of pending) {
        pendingListEl.appendChild(buildLobbyClientRow(client, true));
      }

      approvedListEl.innerHTML = '<h3>Approved</h3>';
      const approvedClients = state.approved || [];
      if (approvedClients.length === 0) {
        approvedListEl.innerHTML += '<div class="muted">No approved users.</div>';
      }

      for (const client of approvedClients) {
        approvedListEl.appendChild(buildLobbyClientRow(client, false));
      }
    }

    function buildLobbyClientRow(client, pending) {
      const row = document.createElement('div');
      row.className = 'team-row';

      const label = teamLabel(client.teamKey) || client.teamKey;
      row.innerHTML = `<div><b>${escapeHtml(client.name || 'Guest')}</b></div><div class="muted">${escapeHtml(label)}</div>`;

      const actions = document.createElement('div');
      actions.className = 'team-actions';

      if (pending) {
        const approve = document.createElement('button');
        approve.className = 'small-btn';
        approve.textContent = 'Approve';
        approve.onclick = () => send({type: 'lobby.approve', ownerId: client.ownerId});
        actions.appendChild(approve);

        const deny = document.createElement('button');
        deny.className = 'secondary small-btn';
        deny.textContent = 'Deny';
        deny.onclick = () => send({type: 'lobby.deny', ownerId: client.ownerId});
        actions.appendChild(deny);
      } else if (!client.host) {
        const kick = document.createElement('button');
        kick.className = 'secondary small-btn';
        kick.textContent = 'Kick';
        kick.onclick = () => send({type: 'lobby.kick', ownerId: client.ownerId});
        actions.appendChild(kick);
      }

      if (!client.host) {
        const lockout = document.createElement('button');
        lockout.className = 'danger small-btn';
        lockout.textContent = 'Lock Out';
        lockout.onclick = () => send({type: 'lobby.lockout', ownerId: client.ownerId});
        actions.appendChild(lockout);
      }

      row.appendChild(actions);
      return row;
    }

    function applyTeamPayload(payload) {
      hostTeamKey = payload.hostTeamKey || '1591';
      teamStates = new Map();

      for (const team of payload.teams || []) {
        if (team?.key) {
          teamStates.set(team.key, team);
        }
      }

      refreshLoginTeam();
      refreshTeamInputs();
      renderTeamPanel();
      renderFieldPreview();
    }

    function renderTeamPanel() {
      teamListEl.innerHTML = '';
      const claimedRows = [];

      for (const team of TEAM_LIST) {
        const state = teamStates.get(team.key);
        const hasClaim = state?.claimed || state?.claimedBy || state?.auto || hostTeamKey === team.key;

        if (hasClaim) {
          claimedRows.push({team, state: state || {}});
        }
      }

      if (claimedRows.length === 0) {
        teamListEl.innerHTML = '<div class="muted">No teams claimed yet.</div>';
        return;
      }

      for (const {team, state} of claimedRows) {
        const color = state.color || teamPrimaryColor(team.key);
        const locked = state.locked === true || hostTeamKey === team.key;
        const row = document.createElement('div');
        row.className = 'team-row';

        const title = document.createElement('div');
        title.className = 'team-title';
        title.innerHTML = `
          <div>
            <span class="pill"><span class="dot" style="--dot:${color}"></span>${team.teamNumber}</span>
            ${escapeHtml(team.name)}
          </div>
          <span class="muted">${locked ? 'Child Lock' : ''}</span>
        `;
        row.appendChild(title);

        const auto = state.auto;
        const info = document.createElement('div');
        info.className = 'muted';
        const claimedBy = state.claimedBy ? `Claimed by ${state.claimedBy}` : 'Claimed';
        info.textContent = auto
          ? `${claimedBy} • ${auto.name || 'Uploaded auto'} • ${Number(auto.totalSeconds || 0).toFixed(2)}s`
          : (hostTeamKey === team.key ? 'Host auto team' : claimedBy);
        row.appendChild(info);

        if (isHost) {
          const actions = document.createElement('div');
          actions.className = 'team-actions';
          const lockButton = document.createElement('button');
          lockButton.className = 'secondary small-btn';
          lockButton.textContent = state.locked ? 'Unlock' : 'Child Lock';
          lockButton.disabled = hostTeamKey === team.key;
          lockButton.onclick = () => send({
            type: 'team.lock',
            teamKey: team.key,
            locked: !state.locked,
          });
          actions.appendChild(lockButton);
          row.appendChild(actions);
        }

        teamListEl.appendChild(row);
      }
    }

    function renderSnapshot(snapshot) {
      latestSnapshot = snapshot;
      fieldImageToken = snapshot.fieldImageToken || fieldImageToken;
      const total = totalTimelineSeconds();
      const autos = snapshot.autos || [];
      const segmentCount = autos.reduce((sum, auto) => {
        return sum + (Array.isArray(auto.segments) ? auto.segments.length : 0);
      }, 0);

      fieldGeometry = snapshot.fieldGeometry || fieldGeometry;

      const fieldAspectRatio = Number(snapshot.fieldAspectRatio || 0);
      if (fieldAspectRatio > 0) {
        fieldWrapEl.style.aspectRatio = `${fieldAspectRatio}`;
        setTimeout(resizeCanvas, 0);
      }

      const nextImageVersion = snapshot.fieldImageVersion ?? null;
      if (nextImageVersion !== fieldImageVersion || fieldImage.src === '') {
        fieldImageVersion = nextImageVersion;
        fieldImage.src = `/field-image?token=${encodeURIComponent(fieldImageToken)}&v=${fieldImageVersion ?? Date.now()}`;
      }

      fieldTimeEl.max = total.toFixed(2);
      fieldTotalLabelEl.textContent = `${total.toFixed(2)}s`;
      if (playheadSeconds > total) {
        playheadSeconds = total;
      }

      summaryEl.textContent = `Timeline: ${total.toFixed(2)}s • host segments: ${segmentCount}`;
      autosEl.innerHTML = '';

      if (autos.length > 0) {
        driveLegendEl.style.background = autos[0].color || '#8cc4ff';
      }

      for (const auto of autos) {
        addAutoSummaryRow(auto, total, auto.color || '#8cc4ff');
      }

      for (const team of TEAM_LIST) {
        const state = teamStates.get(team.key);
        if (!state?.auto) continue;
        addAutoSummaryRow({
          ...state.auto,
          role: `Team ${team.teamNumber}`,
          active: true,
          color: state.color || teamPrimaryColor(team.key),
          waitCount: 0,
        }, total, state.color || teamPrimaryColor(team.key));
      }

      renderFieldPreview();
    }

    function addAutoSummaryRow(auto, total, color) {
      const row = document.createElement('div');
      row.className = 'row';

      const active = auto.active ? 'Active' : 'Bench';

      const title = document.createElement('div');
      title.innerHTML = `<span class="pill"><span class="dot" style="--dot:${color}"></span>${active}</span> ${escapeHtml(auto.name || 'Auto')}`;
      row.appendChild(title);

      const details = document.createElement('div');
      details.className = 'muted';
      const segments = Array.isArray(auto.segments) ? auto.segments : [];
      const samples = Array.isArray(auto.samples) ? auto.samples : [];
      details.textContent = `${auto.role || ''} • ${Number(auto.totalSeconds || 0).toFixed(2)}s • ${Number(auto.waitCount || 0)} wait(s) • ${segments.length} segment(s) • ${samples.length} sample(s)`;
      row.appendChild(details);

      row.appendChild(buildTimeline(auto, total, color));
      row.appendChild(buildSegmentChips(segments));
      autosEl.appendChild(row);
    }

    function totalTimelineSeconds() {
      let total = Number(latestSnapshot?.totalSeconds || 0);
      for (const state of teamStates.values()) {
        if (state?.auto?.totalSeconds) {
          total = Math.max(total, Number(state.auto.totalSeconds || 0));
        }
      }
      return total;
    }

    function buildTimeline(auto, totalSeconds, color) {
      const timeline = document.createElement('div');
      timeline.className = 'timeline';

      let segments = Array.isArray(auto.segments) ? auto.segments.slice() : [];
      if (segments.length === 0 && Number(auto.totalSeconds || 0) > 0) {
        segments = [{
          startSeconds: 0,
          durationSeconds: Number(auto.totalSeconds || 0),
          type: 'drive',
          label: 'Driving',
        }];
      }

      for (const segment of segments) {
        const start = Number(segment.startSeconds || 0);
        const duration = Number(segment.durationSeconds || 0);
        if (!totalSeconds || duration <= 0) continue;

        const el = document.createElement('div');
        const type = segment.type || (segment.isPause ? 'hold' : 'drive');
        el.className = `timeline-segment ${type}`;
        el.style.left = `${clamp((start / totalSeconds) * 100, 0, 100)}%`;
        el.style.width = `${clamp((duration / totalSeconds) * 100, 0.75, 100)}%`;

        if (type === 'drive') {
          el.style.background = color;
        }

        const end = start + duration;
        el.title = `${segment.label || type}: ${start.toFixed(2)}s to ${end.toFixed(2)}s`;
        timeline.appendChild(el);
      }

      const autoTotal = Number(auto.totalSeconds || 0);
      if (totalSeconds > autoTotal) {
        const empty = document.createElement('div');
        empty.className = 'timeline-empty';
        empty.style.left = `${clamp((autoTotal / totalSeconds) * 100, 0, 100)}%`;
        empty.style.width = `${clamp(((totalSeconds - autoTotal) / totalSeconds) * 100, 0, 100)}%`;
        empty.title = 'Finished, holding final pose';
        timeline.appendChild(empty);
      }

      return timeline;
    }

    function buildSegmentChips(segments) {
      const wrapper = document.createElement('div');
      wrapper.className = 'segments';

      for (const segment of segments || []) {
        const type = segment.type || 'drive';
        if (type === 'drive') continue;

        const chip = document.createElement('span');
        chip.className = `segment-chip ${type}`;
        chip.textContent = `${segment.label || type}: ${Number(segment.durationSeconds || 0).toFixed(2)}s`;
        wrapper.appendChild(chip);
      }

      return wrapper;
    }

    function renderFieldPreview() {
      const rect = fieldCanvas.getBoundingClientRect();
      fieldCtx.clearRect(0, 0, rect.width, rect.height);

      drawFieldBackground(fieldCtx, rect);
      drawMarkups(fieldCtx, rect, false);
      drawAutoPaths(fieldCtx, rect);
      drawRobots(fieldCtx, rect);

      if (activeEntity) {
        drawEntity(fieldCtx, activeEntity, rect, 1.0);
      }

      drawToolPreview(fieldCtx, rect);

      fieldTimeEl.value = playheadSeconds.toFixed(2);
      fieldTimeLabelEl.textContent = `${playheadSeconds.toFixed(2)}s`;
    }

    function drawFieldBackground(context, rect) {
      if (fieldImage.complete && fieldImage.naturalWidth > 0) {
        context.drawImage(fieldImage, 0, 0, rect.width, rect.height);
        return;
      }

      context.save();
      context.fillStyle = '#111217';
      context.fillRect(0, 0, rect.width, rect.height);
      context.strokeStyle = 'rgba(255,255,255,0.05)';
      context.lineWidth = 1;
      for (let x = 0; x <= rect.width; x += 40) {
        context.beginPath();
        context.moveTo(x, 0);
        context.lineTo(x, rect.height);
        context.stroke();
      }
      for (let y = 0; y <= rect.height; y += 40) {
        context.beginPath();
        context.moveTo(0, y);
        context.lineTo(rect.width, y);
        context.stroke();
      }
      context.restore();
    }

    function allDrawableAutos() {
      const autos = [];
      for (const auto of latestSnapshot?.autos || []) {
        if (auto.active) {
          autos.push({...auto, color: auto.color || '#8cc4ff'});
        }
      }

      for (const team of TEAM_LIST) {
        const state = teamStates.get(team.key);
        if (state?.auto) {
          autos.push({
            ...state.auto,
            active: true,
            role: `Team ${team.teamNumber}`,
            color: state.color || teamPrimaryColor(team.key),
          });
        }
      }

      return autos;
    }

    function drawAutoPaths(context, rect) {
      for (const auto of allDrawableAutos()) {
        const samples = Array.isArray(auto.samples) ? auto.samples : [];
        if (samples.length < 2) continue;

        context.save();
        context.globalAlpha = auto.role === 'Host' ? 0.65 : 0.42;
        context.strokeStyle = auto.color || '#8cc4ff';
        context.lineWidth = auto.role === 'Host' ? 3 : 2;
        context.beginPath();

        samples.forEach((sample, index) => {
          const x = Number(sample.x || 0) * rect.width;
          const y = Number(sample.y || 0) * rect.height;
          if (index === 0) {
            context.moveTo(x, y);
          } else {
            context.lineTo(x, y);
          }
        });

        context.stroke();
        context.restore();
      }
    }

    function drawRobots(context, rect) {
      for (const auto of allDrawableAutos()) {
        const sample = sampleAtTime(auto.samples || [], playheadSeconds);
        if (!sample) continue;

        const x = Number(sample.x || 0) * rect.width;
        const y = Number(sample.y || 0) * rect.height;
        const theta = Number(sample.theta || 0);
        const color = auto.color || '#8cc4ff';

        drawRobot(context, x, y, theta, color, auto.role === 'Host');
      }
    }

    function drawRobot(context, x, y, theta, color, isHostRobot) {
      const width = isHostRobot ? 28 : 24;
      const length = isHostRobot ? 34 : 30;

      context.save();
      context.translate(x, y);
      context.rotate(-theta);
      context.strokeStyle = color;
      context.fillStyle = isHostRobot ? 'rgba(255,255,255,0.15)' : 'rgba(255,255,255,0.08)';
      context.lineWidth = isHostRobot ? 3 : 2;
      context.beginPath();
      roundedRect(context, -length / 2, -width / 2, length, width, 4);
      context.fill();
      context.stroke();

      context.fillStyle = color;
      context.beginPath();
      context.arc(length / 2 - 5, 0, 4, 0, Math.PI * 2);
      context.fill();
      context.restore();
    }

    function roundedRect(context, x, y, width, height, radius) {
      context.moveTo(x + radius, y);
      context.lineTo(x + width - radius, y);
      context.quadraticCurveTo(x + width, y, x + width, y + radius);
      context.lineTo(x + width, y + height - radius);
      context.quadraticCurveTo(x + width, y + height, x + width - radius, y + height);
      context.lineTo(x + radius, y + height);
      context.quadraticCurveTo(x, y + height, x, y + height - radius);
      context.lineTo(x, y + radius);
      context.quadraticCurveTo(x, y, x + radius, y);
    }

    function sampleAtTime(samples, timeSeconds) {
      if (!Array.isArray(samples) || samples.length === 0) {
        return null;
      }

      if (timeSeconds <= Number(samples[0].t || 0)) {
        return samples[0];
      }

      for (let i = 1; i < samples.length; i++) {
        const prev = samples[i - 1];
        const next = samples[i];
        const t0 = Number(prev.t || 0);
        const t1 = Number(next.t || 0);

        if (timeSeconds <= t1) {
          const pct = t1 <= t0 ? 0 : clamp((timeSeconds - t0) / (t1 - t0), 0, 1);
          return {
            t: timeSeconds,
            x: lerp(Number(prev.x || 0), Number(next.x || 0), pct),
            y: lerp(Number(prev.y || 0), Number(next.y || 0), pct),
            theta: lerpAngle(Number(prev.theta || 0), Number(next.theta || 0), pct),
          };
        }
      }

      return samples[samples.length - 1];
    }

    function lerp(a, b, pct) {
      return a + ((b - a) * pct);
    }

    function lerpAngle(a, b, pct) {
      let delta = b - a;
      while (delta > Math.PI) delta -= Math.PI * 2;
      while (delta < -Math.PI) delta += Math.PI * 2;
      return a + delta * pct;
    }

        function allUploadFiles() {
      return [
        ...Array.from(autoFilesEl?.files || []),
        ...Array.from(autoFolderFilesEl?.files || []),
      ];
    }

    function fileKey(file) {
      return file.webkitRelativePath || file.name;
    }

    function refreshAutoSelect() {
      if (!autoSelectEl) {
        return;
      }

      const files = allUploadFiles();
      const autoFiles = files.filter((file) => file.name.toLowerCase().endsWith('.auto'));

      autoSelectEl.innerHTML = '';

      if (autoFiles.length === 0) {
        const option = document.createElement('option');
        option.value = '';
        option.textContent = 'No .auto files selected';
        autoSelectEl.appendChild(option);
        autoSelectEl.disabled = true;
        return;
      }

      for (const file of autoFiles) {
        const option = document.createElement('option');
        option.value = fileKey(file);
        option.textContent = file.webkitRelativePath || file.name;
        autoSelectEl.appendChild(option);
      }

      autoSelectEl.disabled = autoFiles.length <= 1;
    }

    function parsePathPlannerJson(text) {
      const attempts = [
        text,
        text.replace(/\\\s*(\r?\n)/g, '$1'),
        text
          .replace(/\\\s*(\r?\n)/g, '$1')
          .replace(/,\s*([}\]])/g, '$1'),
      ];

      let lastError = null;
      for (const attempt of attempts) {
        try {
          return JSON.parse(attempt);
        } catch (err) {
          lastError = err;
        }
      }

      throw lastError || new Error('Invalid JSON');
    }

    async function uploadTeamAuto() {
      const teamKey = claimedTeamKey;
      const state = teamStates.get(teamKey) || {};
      if (!teamKey || teamKey !== normalizeTeamKey(teamInputEl.value)) {
        teamStatusEl.textContent = 'Claim this team before uploading.';
        return;
      }

      if (state.locked || hostTeamKey === teamKey) {
        teamStatusEl.textContent = 'This team is Child Locked.';
        return;
      }

      const files = allUploadFiles();
      const autoFiles = files.filter((file) => file.name.toLowerCase().endsWith('.auto'));
      const pathFiles = files.filter((file) => file.name.toLowerCase().endsWith('.path'));

      if (autoFiles.length === 0) {
        teamStatusEl.textContent = 'Select a folder containing autos/ and paths/, or select one .auto plus its referenced .path files.';
        return;
      }

      const selectedAutoKey = autoSelectEl?.value || '';
      const autoFile = autoFiles.find((file) => fileKey(file) === selectedAutoKey) || autoFiles[0];

      try {
        const autoJson = parsePathPlannerJson(await autoFile.text());
        const pathMap = new Map();

        for (const file of pathFiles) {
          const name = stripExtension(file.name);
          pathMap.set(name, parsePathPlannerJson(await file.text()));
        }

        const imported = buildImportedAuto(autoFile.name, autoJson, pathMap);

        if (!imported.samples || imported.samples.length === 0) {
          const foundPaths = imported.pathNames?.length
            ? imported.pathNames.join(', ')
            : 'none found in .auto';

          const missing = imported.missingPaths?.length
            ? imported.missingPaths.join(', ')
            : 'none';

          teamStatusEl.textContent =
            `0 samples. Auto paths found: ${foundPaths}. Missing path files: ${missing}. ` +
            'Select the project/deploy/pathplanner folder or include all referenced .path files.';
          return;
        }

        send({
          type: 'team.auto',
          teamKey,
          ownerId: clientId,
          name: nameEl.value || 'Guest',
          auto: imported,
        });

        const missingNote = imported.missingPaths?.length
          ? ` Missing paths ignored: ${imported.missingPaths.join(', ')}`
          : '';

        teamStatusEl.textContent =
          `Uploaded ${imported.name} with ${imported.samples.length} samples.${missingNote}`;
      } catch (err) {
        teamStatusEl.textContent = `Could not import auto: ${err.message || err}`;
      }
    }

        function buildImportedAuto(filename, autoJson, pathMap) {
      const pathNames = findPathNames(autoJson);
      const missing = [];
      const samples = [];
      let t = 0;
      let lastPoint = null;

      for (const pathName of pathNames) {
        const path = pathMap.get(pathName);
        if (!path) {
          missing.push(pathName);
          continue;
        }

        const anchors = readPathAnchors(path);
        if (anchors.length < 2) {
          continue;
        }

        for (const anchor of anchors) {
          const point = normalizeFieldPoint(anchor.x, anchor.y);
          if (lastPoint) {
            const distance = Math.hypot(point.xMeters - lastPoint.xMeters, point.yMeters - lastPoint.yMeters);
            t += Math.max(0.05, distance / 4.0);
          }

          samples.push({
            t,
            x: point.x,
            y: point.y,
            theta: 0,
          });
          lastPoint = point;
        }
      }

      for (let i = 1; i < samples.length; i++) {
        const prev = samples[i - 1];
        const next = samples[i];
        next.theta = Math.atan2(prev.y - next.y, next.x - prev.x);
      }

      if (samples.length > 1) {
        samples[0].theta = samples[1].theta;
      }

      const totalSeconds = samples.length > 0 ? samples[samples.length - 1].t : 0;
      return {
        name: stripExtension(filename),
        totalSeconds,
        nativeSeconds: totalSeconds,
        waitCount: 0,
        missingPaths: missing,
        pathNames,
        samples,
        segments: totalSeconds > 0 ? [{
          startSeconds: 0,
          durationSeconds: totalSeconds,
          label: 'Imported',
          type: 'drive',
          isPause: false,
        }] : [],
      };
    }

    function findPathNames(value) {
      const names = [];

      function visit(node) {
        if (Array.isArray(node)) {
          node.forEach(visit);
          return;
        }

        if (!node || typeof node !== 'object') {
          return;
        }

        for (const [key, val] of Object.entries(node)) {
          const lower = key.toLowerCase();
          if (
            typeof val === 'string' &&
            (lower === 'pathname' || lower === 'path' || lower === 'path_name')
          ) {
            if (!names.includes(val)) names.push(val);
          } else {
            visit(val);
          }
        }
      }

      visit(value);
      return names;
    }

    function readPathAnchors(pathJson) {
      const waypoints = Array.isArray(pathJson.waypoints) ? pathJson.waypoints : [];
      const anchors = [];

      for (const waypoint of waypoints) {
        const anchor = waypoint.anchor || waypoint.anchorPoint || waypoint.position;
        if (anchor && typeof anchor.x === 'number' && typeof anchor.y === 'number') {
          anchors.push({x: anchor.x, y: anchor.y});
        }
      }

      return anchors;
    }

    function normalizeFieldPoint(xMeters, yMeters) {
      const geometry = fieldGeometry || {};
      const pixelsPerMeter = Number(geometry.pixelsPerMeter || 200);
      const marginMeters = Number(geometry.marginMeters || 0);
      const widthPixels = Number(geometry.widthPixels || 1);
      const heightPixels = Number(geometry.heightPixels || 1);

      const xPixels = (xMeters + marginMeters) * pixelsPerMeter;
      const yPixels = heightPixels - ((yMeters + marginMeters) * pixelsPerMeter);

      return {
        x: clamp(xPixels / widthPixels, 0, 1),
        y: clamp(yPixels / heightPixels, 0, 1),
        xMeters,
        yMeters,
      };
    }

    function stripExtension(filename) {
      return filename.replace(/\.[^/.]+$/, '');
    }

    function setMode(nextMode) {
      mode = nextMode;
      drawModeEl.classList.toggle('active', mode === 'draw');
      eraseModeEl.classList.toggle('active', mode === 'erase');
      renderFieldPreview();
    }

    function resizeCanvas() {
      const rect = fieldCanvas.getBoundingClientRect();
      const scale = window.devicePixelRatio || 1;
      fieldCanvas.width = Math.max(1, Math.floor(rect.width * scale));
      fieldCanvas.height = Math.max(1, Math.floor(rect.height * scale));
      fieldCtx.setTransform(scale, 0, 0, scale, 0, 0);
      renderFieldPreview();
    }

    function canvasPoint(event) {
      const rect = fieldCanvas.getBoundingClientRect();
      return {
        x: clamp((event.clientX - rect.left) / rect.width, 0, 1),
        y: clamp((event.clientY - rect.top) / rect.height, 0, 1),
      };
    }

    function drawMarkups(context, rect, useOwnershipAlpha) {
      for (const entity of markups) {
        const alpha = useOwnershipAlpha
          ? (entity.ownerId === clientId ? 1.0 : 0.55)
          : 0.95;
        drawEntity(context, entity, rect, alpha);
      }
    }

    function drawEntity(context, entity, rect, alpha) {
      const points = Array.isArray(entity.points) ? entity.points : [];
      if (points.length < 2) return;

      context.save();
      context.lineJoin = 'round';
      context.lineCap = 'round';
      context.strokeStyle = entity.color || '#ff4fd8';
      context.lineWidth = Number(entity.width || 5);
      context.globalAlpha = alpha;
      context.beginPath();
      context.moveTo(points[0].x * rect.width, points[0].y * rect.height);

      for (const point of points.slice(1)) {
        context.lineTo(point.x * rect.width, point.y * rect.height);
      }

      context.stroke();
      context.restore();
    }

    function drawToolPreview(context, rect) {
      if (!cursorPoint) return;

      const width = Number(widthEl.value || 5);
      const x = cursorPoint.x * rect.width;
      const y = cursorPoint.y * rect.height;

      context.save();
      context.lineWidth = 2;
      context.strokeStyle = mode === 'erase' ? '#ffffff' : colorEl.value;
      context.fillStyle = mode === 'erase'
        ? 'rgba(255,255,255,0.12)'
        : `${colorEl.value}33`;

      if (mode === 'erase') {
        const size = Math.max(8, width * 3);
        context.strokeRect(x - size / 2, y - size / 2, size, size);
        context.fillRect(x - size / 2, y - size / 2, size, size);
      } else {
        const radius = Math.max(4, width * 1.5);
        context.beginPath();
        context.arc(x, y, radius, 0, Math.PI * 2);
        context.fill();
        context.stroke();
      }

      context.restore();
    }

    function sendMarkupAdd(entity) {
      send({ type: 'markup.add', entity });
    }

    function sendMarkupDelete(id) {
      send({ type: 'markup.delete', id, ownerId: clientId });
    }

    function sendMarkupClear() {
      send({ type: 'markup.clearOwner', ownerId: clientId });
    }

    function send(message) {
      if (!ws || ws.readyState !== WebSocket.OPEN) return;
      ws.send(JSON.stringify(message));
    }

    function eraseAtPoint(point) {
      const id = nearestOwnedEntityId(point);
      if (!id || erasedThisGesture.has(id)) {
        return;
      }

      erasedThisGesture.add(id);
      sendMarkupDelete(id);
    }

    function nearestOwnedEntityId(point) {
      let best = null;
      let bestDistance = Infinity;

      for (const entity of markups) {
        if (entity.ownerId !== clientId) {
          continue;
        }

        const points = Array.isArray(entity.points) ? entity.points : [];

        for (let i = 1; i < points.length; i++) {
          const distance = distanceToSegment(point, points[i - 1], points[i]);
          if (distance < bestDistance) {
            bestDistance = distance;
            best = entity.id;
          }
        }
      }

      return bestDistance < 0.025 ? best : null;
    }

    function distanceToSegment(p, a, b) {
      const dx = b.x - a.x;
      const dy = b.y - a.y;
      const lenSq = dx * dx + dy * dy;

      if (lenSq === 0) {
        return Math.hypot(p.x - a.x, p.y - a.y);
      }

      const t = clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq, 0, 1);
      const x = a.x + t * dx;
      const y = a.y + t * dy;
      return Math.hypot(p.x - x, p.y - y);
    }

    fieldCanvas.addEventListener('pointerenter', (event) => {
      cursorPoint = canvasPoint(event);
      renderFieldPreview();
    });

    fieldCanvas.addEventListener('pointerleave', () => {
      cursorPoint = null;
      renderFieldPreview();
    });

    fieldCanvas.addEventListener('pointerdown', (event) => {
      fieldCanvas.setPointerCapture(event.pointerId);
      const point = canvasPoint(event);
      cursorPoint = point;

      if (mode === 'erase') {
        erasing = true;
        erasedThisGesture = new Set();
        eraseAtPoint(point);
        renderFieldPreview();
        return;
      }

      drawing = true;
      activeEntity = {
        id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
        type: 'path',
        ownerId: clientId,
        ownerName: nameEl.value || 'Guest',
        color: colorEl.value,
        width: Number(widthEl.value || 5),
        points: [point],
      };
      renderFieldPreview();
    });

    fieldCanvas.addEventListener('pointermove', (event) => {
      const point = canvasPoint(event);
      cursorPoint = point;

      if (mode === 'erase' && erasing) {
        eraseAtPoint(point);
        renderFieldPreview();
        return;
      }

      if (!drawing || !activeEntity) {
        renderFieldPreview();
        return;
      }

      const last = activeEntity.points[activeEntity.points.length - 1];
      if (Math.hypot(point.x - last.x, point.y - last.y) < 0.004) {
        return;
      }

      activeEntity.points.push(point);
      renderFieldPreview();
    });

    fieldCanvas.addEventListener('pointerup', () => {
      if (mode === 'erase') {
        erasing = false;
        erasedThisGesture = new Set();
        renderFieldPreview();
        return;
      }

      if (!drawing || !activeEntity) return;

      drawing = false;
      if (activeEntity.points.length >= 2) {
        sendMarkupAdd(activeEntity);
      }
      activeEntity = null;
      renderFieldPreview();
    });

    fieldCanvas.addEventListener('pointercancel', () => {
      drawing = false;
      erasing = false;
      erasedThisGesture = new Set();
      activeEntity = null;
      renderFieldPreview();
    });

    loginTeamEl.oninput = refreshLoginTeam;

    loginJoinEl.onclick = () => {
      const teamKey = normalizeTeamKey(loginTeamEl.value);
      const def = teamDef(teamKey);
      if (!def) {
        refreshLoginTeam();
        return;
      }

      const name = loginNameEl.value.trim() || 'Guest';
      localStorage.setItem('pathplannerCollabName', name);
      sessionStorage.setItem('pathplannerCollabTeamKey', teamKey);
      if (teamKey === hostTeamKey && loginHostPasswordEl.value) {
        localStorage.setItem('pathplannerCollab1591Password', loginHostPasswordEl.value);
      }

      loginStatusEl.textContent = 'Requesting lobby access...';
      nameEl.value = name;

      send({
        type: 'lobby.login',
        ownerId: clientId,
        name,
        teamKey,
        pairingCode: loginPairingEl.value.trim(),
        hostPassword: loginHostPasswordEl.value,
      });
    };

    teamInputEl.oninput = () => {
      selectedTeamKey = normalizeTeamKey(teamInputEl.value);
      sessionStorage.setItem('pathplannerCollabTeamKey', selectedTeamKey);
      refreshTeamInputs();
    };

    claimTeamEl.onclick = () => {
      selectedTeamKey = normalizeTeamKey(teamInputEl.value);
      const def = teamDef(selectedTeamKey);
      if (!def || isHost) {
        refreshTeamInputs();
        return;
      }

      claimedTeamKey = selectedTeamKey;
      sessionStorage.setItem('pathplannerCollabTeamKey', selectedTeamKey);
      sessionStorage.setItem('pathplannerCollabClaimedTeamKey', claimedTeamKey);
      send({
        type: 'team.claim',
        teamKey: claimedTeamKey,
      });
      refreshTeamInputs();
      renderTeamPanel();
    };

    teamColorEl.oninput = () => {
      if (!claimedTeamKey || claimedTeamKey !== normalizeTeamKey(teamInputEl.value)) return;
      send({
        type: 'team.color',
        teamKey: claimedTeamKey,
        color: teamColorEl.value,
      });
    };

    autoFilesEl.onchange = refreshAutoSelect;
    autoFolderFilesEl.onchange = refreshAutoSelect;
    uploadAutoEl.onclick = uploadTeamAuto;

    clearTeamAutoEl.onclick = () => {
      if (!claimedTeamKey || claimedTeamKey !== normalizeTeamKey(teamInputEl.value)) return;
      send({
        type: 'team.clearAuto',
        teamKey: claimedTeamKey,
      });
    };

    clearEl.onclick = () => {
      if (confirm('Clear only your drawings from this session?')) {
        sendMarkupClear();
      }
    };

    drawModeEl.onclick = () => setMode('draw');
    eraseModeEl.onclick = () => setMode('erase');
    colorEl.oninput = renderFieldPreview;
    widthEl.onchange = renderFieldPreview;

    playPauseEl.onclick = () => {
      playing = !playing;
      playPauseEl.textContent = playing ? 'Pause' : 'Play';
    };

    fieldTimeEl.oninput = () => {
      playheadSeconds = Number(fieldTimeEl.value || 0);
      renderFieldPreview();
    };

    function animate(nowMs) {
      if (lastFrameMs == null) {
        lastFrameMs = nowMs;
      }

      const total = totalTimelineSeconds();
      if (playing && total > 0) {
        const dt = (nowMs - lastFrameMs) / 1000.0;
        playheadSeconds += dt;
        if (playheadSeconds > total) {
          playheadSeconds = 0;
        }
        renderFieldPreview();
      }

      lastFrameMs = nowMs;
      requestAnimationFrame(animate);
    }

    function clamp(value, min, max) {
      return Math.max(min, Math.min(max, value));
    }

    function addChat(text) {
      const div = document.createElement('div');
      div.className = 'chat-line';
      div.textContent = text;
      chatEl.appendChild(div);
      chatEl.scrollTop = chatEl.scrollHeight;
    }

    function sendChat() {
      const message = messageEl.value.trim();
      if (!message || !ws || ws.readyState !== WebSocket.OPEN || !approved) {
        return;
      }

      ws.send(JSON.stringify({
        type: 'chat',
        message,
      }));
      messageEl.value = '';
    }

    function escapeHtml(text) {
      return String(text)
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#039;');
    }

    sendEl.onclick = sendChat;
    messageEl.onkeydown = (event) => {
      if (event.key === 'Enter') sendChat();
    };

    window.addEventListener('resize', resizeCanvas);
    initTeams();
    setTimeout(resizeCanvas, 0);
    setMode('draw');
    connect();
    requestAnimationFrame(animate);
  </script>
</body>
</html>

''';
