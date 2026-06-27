// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Extracts an 11-character YouTube video id from a raw id or any common URL
/// form (watch?v=, youtu.be/, /embed/, /shorts/, /live/, /v/). Returns null if
/// nothing valid is found.
String? parseYoutubeId(String input) {
  final trimmed = input.trim();
  if (_validId(trimmed) != null) return trimmed;
  Uri uri;
  try {
    uri = Uri.parse(trimmed);
  } catch (_) {
    return null;
  }
  if (uri.host.contains('youtu.be')) {
    return uri.pathSegments.isEmpty ? null : _validId(uri.pathSegments.first);
  }
  if (uri.host.contains('youtube.com')) {
    final v = uri.queryParameters['v'];
    if (v != null) return _validId(v);
    final segs = uri.pathSegments;
    if (segs.length >= 2 &&
        const {'embed', 'shorts', 'live', 'v'}.contains(segs.first)) {
      return _validId(segs[1]);
    }
  }
  return null;
}

String? _validId(String s) =>
    RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(s) ? s : null;

/// Asks for a YouTube URL/id and returns the raw text (null if cancelled).
/// The caller parses it with [parseYoutubeId] so it can show its own error.
Future<String?> showYoutubeStartDialog(BuildContext context) async {
  final field = TextEditingController();
  final raw = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Start a YouTube video'),
      content: TextField(
        controller: field,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'YouTube URL or video ID',
          hintText: 'https://youtu.be/…',
        ),
        onSubmitted: (_) => Navigator.of(ctx).pop(field.text),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(field.text),
          child: const Text('Start'),
        ),
      ],
    ),
  );
  field.dispose();
  return raw;
}

/// Imperative handle to the embedded YouTube player — the app calls these to
/// drive playback (host actions, or applying the host's state as a follower).
class WatchPartyController {
  InAppWebViewController? _web;
  bool _ready = false;

  /// Fires once the embedded player is ready to accept commands.
  void Function()? onReady;

  /// Fires on playback state changes from the player: (isPlaying, positionSecs).
  void Function(bool playing, double position)? onStateChange;

  bool get isReady => _ready;

  void _attach(InAppWebViewController web) => _web = web;
  void _markReady() {
    _ready = true;
    onReady?.call();
  }

  Future<void> load(String videoId, {double start = 0}) async =>
      _web?.evaluateJavascript(source: 'ytLoad("$videoId", $start);');
  Future<void> play() async => _web?.evaluateJavascript(source: 'ytPlay();');
  Future<void> pause() async => _web?.evaluateJavascript(source: 'ytPause();');
  Future<void> seek(double seconds) async =>
      _web?.evaluateJavascript(source: 'ytSeek($seconds);');
  Future<void> setMuted(bool muted) async =>
      _web?.evaluateJavascript(source: 'ytMute($muted);');

  Future<double> currentTime() async {
    final r = await _web?.evaluateJavascript(source: 'ytTime();');
    return (r as num?)?.toDouble() ?? 0;
  }

  Future<double> duration() async {
    final r = await _web?.evaluateJavascript(source: 'ytDuration();');
    return (r as num?)?.toDouble() ?? 0;
  }
}

// A minimal page hosting the official IFrame Player API with native controls
// hidden (controls:0) — playback is driven entirely through the JS bridge, so
// followers can't fight the host. Loaded with a youtube.com base URL so the API
// gets a valid origin.
const String _kPlayerHtml = '''
<!DOCTYPE html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1, user-scalable=no">
<style>html,body{margin:0;padding:0;background:#000;height:100%;overflow:hidden}#p{width:100%;height:100%}</style>
</head><body>
<div id="p"></div>
<script>
var player=null;
function post(ev,data){ if(window.flutter_inappwebview){ window.flutter_inappwebview.callHandler('yt', ev, data||{}); } }
function onYouTubeIframeAPIReady(){
  player = new YT.Player('p', {
    width:'100%', height:'100%',
    playerVars:{controls:0, rel:0, modestbranding:1, playsinline:1, disablekb:1, fs:0, iv_load_policy:3},
    events:{
      'onReady':function(){ post('ready',{}); },
      'onStateChange':function(e){ post('state',{state:e.data, time:(player&&player.getCurrentTime)?player.getCurrentTime():0}); }
    }
  });
}
function ytLoad(id,start){ if(player&&player.loadVideoById){ player.loadVideoById({videoId:id,startSeconds:start||0}); } }
function ytPlay(){ if(player&&player.playVideo) player.playVideo(); }
function ytPause(){ if(player&&player.pauseVideo) player.pauseVideo(); }
function ytSeek(t){ if(player&&player.seekTo) player.seekTo(t,true); }
function ytMute(m){ if(player){ if(m){if(player.mute)player.mute();}else{if(player.unMute)player.unMute();} } }
function ytTime(){ return (player&&player.getCurrentTime)?player.getCurrentTime():0; }
function ytDuration(){ return (player&&player.getDuration)?player.getDuration():0; }
(function(){ var t=document.createElement('script'); t.src='https://www.youtube.com/iframe_api'; document.head.appendChild(t); })();
</script>
</body></html>
''';

/// The embedded YouTube player. [videoId]/[muted] are reconciled declaratively;
/// play/pause/seek are issued imperatively through [controller]. On first ready
/// it loads [videoId] at [startSeconds] and matches [startPlaying] — so a member
/// joining an in-progress party catches up.
class WatchPartyPlayer extends StatefulWidget {
  const WatchPartyPlayer({
    super.key,
    required this.controller,
    required this.videoId,
    required this.startSeconds,
    required this.startPlaying,
    required this.muted,
  });

  final WatchPartyController controller;
  final String videoId;
  final double startSeconds;
  final bool startPlaying;
  final bool muted;

  @override
  State<WatchPartyPlayer> createState() => _WatchPartyPlayerState();
}

class _WatchPartyPlayerState extends State<WatchPartyPlayer> {
  @override
  void didUpdateWidget(WatchPartyPlayer old) {
    super.didUpdateWidget(old);
    if (!widget.controller.isReady) return;
    if (old.videoId != widget.videoId) {
      widget.controller.load(widget.videoId, start: widget.startSeconds);
    }
    if (old.muted != widget.muted) {
      widget.controller.setMuted(widget.muted);
    }
  }

  @override
  Widget build(BuildContext context) {
    return InAppWebView(
      initialData: InAppWebViewInitialData(
        data: _kPlayerHtml,
        baseUrl: WebUri('https://www.youtube.com'),
      ),
      initialSettings: InAppWebViewSettings(
        mediaPlaybackRequiresUserGesture: false,
        transparentBackground: true,
        javaScriptCanOpenWindowsAutomatically: false,
      ),
      shouldOverrideUrlLoading: (controller, action) async =>
          NavigationActionPolicy.CANCEL, // lock to the player page
      onWebViewCreated: (web) {
        widget.controller._attach(web);
        web.addJavaScriptHandler(
          handlerName: 'yt',
          callback: (args) {
            final ev = args.isNotEmpty ? args[0] as String? : null;
            final data = (args.length > 1 && args[1] is Map)
                ? args[1] as Map
                : const <dynamic, dynamic>{};
            if (ev == 'ready') {
              widget.controller._markReady();
              widget.controller.load(
                widget.videoId,
                start: widget.startSeconds,
              );
              widget.controller.setMuted(widget.muted);
              if (widget.startPlaying) {
                widget.controller.play();
              } else {
                widget.controller.pause();
              }
            } else if (ev == 'state') {
              // YT states: 1 playing, 2 paused, 3 buffering. Treat buffering as
              // playing so a seek doesn't read as a pause and ripple to viewers.
              final state = (data['state'] as num?)?.toInt() ?? -1;
              final time = (data['time'] as num?)?.toDouble() ?? 0;
              widget.controller.onStateChange?.call(
                state == 1 || state == 3,
                time,
              );
            }
            return null;
          },
        );
      },
    );
  }
}
