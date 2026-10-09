// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'screen_share.dart';

/// Borrows the existing renderer; leaving this view never ends the stream.
class ScreenShareFullscreen extends StatelessWidget {
  const ScreenShareFullscreen({
    required this.view,
    required this.title,
    required this.onExit,
    this.videoBuilder,
    super.key,
  });

  final ScreenView view;
  final String title;
  final VoidCallback onExit;
  @visibleForTesting
  final WidgetBuilder? videoBuilder;

  @override
  Widget build(BuildContext context) => Shortcuts(
    shortcuts: const {
      SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
    },
    child: Actions(
      actions: {
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            onExit();
            return null;
          },
        ),
      },
      child: Focus(
        autofocus: true,
        child: Material(
          color: Colors.black,
          child: SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: onExit,
                        tooltip: 'Exit fullscreen',
                        color: Colors.white,
                        icon: const Icon(Icons.fullscreen_exit),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: AnimatedBuilder(
                    animation: view,
                    builder: (context, _) => view.isClosed
                        ? const Center(
                            child: Icon(
                              Icons.stop_screen_share,
                              color: Colors.white54,
                            ),
                          )
                        : !view.hasVideo
                        ? const Center(child: CircularProgressIndicator())
                        : GestureDetector(
                            onDoubleTap: onExit,
                            child:
                                videoBuilder?.call(context) ??
                                RTCVideoView(
                                  view.renderer,
                                  objectFit: RTCVideoViewObjectFit
                                      .RTCVideoViewObjectFitContain,
                                ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
