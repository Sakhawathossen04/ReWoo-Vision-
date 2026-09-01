import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../download_page/config/constants.dart';
import '../models/message_models.dart';
import '../services/live_camera_service.dart';
import 'chat_bubble.dart';
import 'prompt_bar.dart';

class ChatUIBuilder {
  static PreferredSizeWidget buildCleanAppBar({
    required VoidCallback onNewChat,
    required VoidCallback onToggleSettings,
    required bool isResetting,
  }) {
    return AppBar(
      elevation: 0,
      backgroundColor: Colors.white,
      systemOverlayStyle: SystemUiOverlayStyle.dark,
      title: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset(
              appLogoAsset,
              width: 30,
              height: 30,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox(width: 30),
            ),
          ),
          const SizedBox(width: 10),
          const Text(
            'rewoo vision',
            style: TextStyle(
              color: Colors.black87,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
      actions: [
        Semantics(
          button: true,
          label: 'সেটিংস',
          hint: 'সেটিংস খুলতে দুইবার ট্যাপ করুন',
          child: IconButton(
            tooltip: 'সেটিংস',
            onPressed: onToggleSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  /// Video-call hero: the always-on live camera view with the mic status
  /// overlaid like a call UI. Everything is Bangla and TalkBack-friendly.
  static Widget buildVideoCallView({
    required LiveCameraService camera,
    required bool listening,
    required bool isRecording,
    required bool speechEnabled,
    required bool isGenerating,
    required bool isSpeaking,
    required String lastHeard,
    required VoidCallback onToggleListening,
    required VoidCallback? onStopRecording,
    required VoidCallback onRetryCamera,
  }) {
    return AnimatedBuilder(
      animation: camera,
      builder: (context, _) {
        final controller = camera.controller;
        final ready = camera.isReady;

        final statusText = isRecording
            ? 'ভিডিও রেকর্ড হচ্ছে… বন্ধ করতে বলুন: ভিডিও বন্ধ করো'
            : isGenerating
                ? 'ছবি বিশ্লেষণ হচ্ছে…'
                : isSpeaking
                    ? 'উত্তর বলা হচ্ছে…'
                    : listening
                        ? 'শুনছি… বলুন: সামনে কী আছে, এটা কী, ছবি তোলো'
                        : speechEnabled
                            ? 'ভয়েস অপেক্ষায় — চালু করতে মাইক চাপুন'
                            : 'ভয়েস কন্ট্রোল পাওয়া যায়নি';

        return Semantics(
          liveRegion: true,
          label: ready
              ? 'ক্যামেরা চালু আছে। $statusText'
              : 'ক্যামেরা চালু হচ্ছে। $statusText',
          child: Container(
            margin: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(22),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.12),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            clipBehavior: Clip.antiAlias,
            child: AspectRatio(
              aspectRatio: 3 / 4,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (ready)
                    CameraPreview(controller!)
                  else
                    Container(
                      color: const Color(0xFF101418),
                      alignment: Alignment.center,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (camera.lastError == null)
                            const CircularProgressIndicator(
                              color: Colors.white70,
                              strokeWidth: 2.5,
                            )
                          else
                            Icon(
                              Icons.videocam_off_outlined,
                              color: Colors.red.shade200,
                              size: 40,
                            ),
                          const SizedBox(height: 14),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Text(
                              camera.lastError == null
                                  ? 'ক্যামেরা চালু হচ্ছে…'
                                  : 'ক্যামেরা চালু করা যায়নি',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (camera.lastError != null) ...[
                            const SizedBox(height: 10),
                            TextButton.icon(
                              onPressed: onRetryCamera,
                              icon: const Icon(
                                Icons.refresh_rounded,
                                color: Colors.white,
                              ),
                              label: const Text(
                                'আবার চেষ্টা করুন',
                                style: TextStyle(color: Colors.white),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),

                  // top status pill (mic state, like a call banner)
                  Positioned(
                    top: 12,
                    left: 12,
                    right: 12,
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: isRecording
                                ? Colors.red.withOpacity(0.85)
                                : Colors.black.withOpacity(0.55),
                            borderRadius: BorderRadius.circular(30),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                isRecording
                                    ? Icons.fiber_manual_record
                                    : listening
                                        ? Icons.mic
                                        : Icons.mic_off,
                                size: 16,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 7),
                              Flexible(
                                child: Text(
                                  isRecording
                                      ? 'রেকর্ড হচ্ছে'
                                      : listening
                                          ? 'লাইভ — শুনছি'
                                          : 'মাইক বন্ধ',
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Spacer(),
                        // Mic toggle — same affordance as un/muting a call.
                        Material(
                          color: listening
                              ? Colors.black.withOpacity(0.55)
                              : Colors.red.shade600,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: speechEnabled ? onToggleListening : null,
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Icon(
                                listening ? Icons.mic : Icons.mic_off,
                                color: Colors.white,
                                size: 22,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // bottom status + last-heard caption
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (lastHeard.trim().isNotEmpty)
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.5),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              'শোনা হয়েছে: $lastHeard',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 11,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.6),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            statusText,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              height: 1.3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // stop button while recording
                  if (isRecording && onStopRecording != null)
                    Positioned(
                      right: 12,
                      bottom: 74,
                      child: Material(
                        color: Colors.red.shade600,
                        shape: const CircleBorder(),
                        elevation: 4,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: onStopRecording,
                          child: const Padding(
                            padding: EdgeInsets.all(14),
                            child: Icon(
                              Icons.stop_rounded,
                              color: Colors.white,
                              size: 30,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static Widget buildVoiceControlCard({
    required bool speechEnabled,
    required bool listening,
    required bool bengaliLocaleAvailable,
    required String lastHeard,
    required VoidCallback onToggleListening,
  }) {
    final title = !speechEnabled
        ? 'ভয়েস কন্ট্রোল পাওয়া যায়নি'
        : listening
        ? 'ভয়েস কন্ট্রোল সক্রিয়'
        : 'ভয়েস কন্ট্রোল অপেক্ষায়';

    final subtitle = !speechEnabled
        ? 'মাইক্রোফোন অনুমতি ও Google Speech Services পরীক্ষা করুন।'
        : !bengaliLocaleAvailable
        ? 'বাংলা স্পিচ লোকেল পাওয়া যায়নি। ফোনের ভয়েস ইনপুটে বাংলা চালু করুন।'
        : listening
        ? 'কমান্ড বলুন: “সামনে কী আছে”, “এটা কী”, “লেখাটা পড়ে শোনাও”।'
        : 'ভয়েস শোনা আবার চালু করতে নিচের বোতাম চাপুন।';

    return Semantics(
      liveRegion: true,
      label: '$title। $subtitle',
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: listening ? Colors.green.shade200 : Colors.orange.shade200,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 54,
              height: 54,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: listening ? Colors.green.shade50 : Colors.orange.shade50,
              ),
              child: Icon(
                listening ? Icons.hearing_rounded : Icons.hearing_disabled_rounded,
                color: listening ? Colors.green.shade700 : Colors.orange.shade700,
                size: 30,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Colors.grey.shade700,
                      height: 1.35,
                    ),
                  ),
                  if (lastHeard.trim().isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'শেষ শোনা: $lastHeard',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade500,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: listening ? 'ভয়েস বন্ধ করুন' : 'ভয়েস চালু করুন',
              onPressed: speechEnabled ? onToggleListening : null,
              icon: Icon(listening ? Icons.mic : Icons.mic_off),
            ),
          ],
        ),
      ),
    );
  }

  static Widget buildQuickActions({
    required bool disabled,
    required VoidCallback onDescribeFront,
    required VoidCallback onIdentifyObject,
    required VoidCallback onReadText,
  }) {
    Widget button(String label, IconData icon, VoidCallback onPressed) {
      return Expanded(
        child: SizedBox(
          height: 58,
          child: FilledButton.tonalIcon(
            onPressed: disabled ? null : onPressed,
            icon: Icon(icon),
            label: Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          button('সামনে দেখুন', Icons.visibility_outlined, onDescribeFront),
          const SizedBox(width: 8),
          button('এটা কী', Icons.center_focus_strong, onIdentifyObject),
          const SizedBox(width: 8),
          button('লেখা পড়ুন', Icons.text_snippet_outlined, onReadText),
        ],
      ),
    );
  }

  /// Red live banner shown while a voice-triggered video recording is
  /// running. Provides the manual stop button as a fallback for the voice
  /// command "ভিডিও বন্ধ করো".
  static Widget buildRecordingBanner({required VoidCallback onStop}) {
    return Semantics(
      liveRegion: true,
      label: 'ভিডিও রেকর্ড হচ্ছে। বন্ধ করতে বোতাম চাপুন।',
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.red.shade50,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.red.shade300),
        ),
        child: Row(
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.red.withOpacity(0.6),
                    blurRadius: 8,
                    spreadRadius: 2,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'ভিডিও রেকর্ড হচ্ছে… বন্ধ করতে বলুন: “ভিডিও বন্ধ করো”',
                style: TextStyle(
                  color: Colors.red.shade800,
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red.shade600,
                padding: const EdgeInsets.symmetric(horizontal: 14),
              ),
              onPressed: onStop,
              icon: const Icon(Icons.stop_rounded, size: 20),
              label: const Text('বন্ধ'),
            ),
          ],
        ),
      ),
    );
  }

  static Widget buildViewToggleButtons({
    required bool showMessages,
    required VoidCallback onToggleMessages,
    required VoidCallback onNewChat,
    required bool isResetting,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: isResetting ? null : onNewChat,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(isResetting ? 'অপেক্ষা করুন' : 'নতুন আলাপ'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: onToggleMessages,
              icon: Icon(
                showMessages
                    ? Icons.visibility_off_outlined
                    : Icons.history_rounded,
              ),
              label: Text(showMessages ? 'বার্তা লুকান' : 'সব বার্তা'),
            ),
          ),
        ],
      ),
    );
  }

  static Widget buildMessagesContainer(
    List<ChatMessage> messages,
    ScrollController scrollController,
  ) {
    return Expanded(
      child: Semantics(
        label: 'আলাপের বার্তাসমূহ',
        child: messages.isEmpty
            ? _emptyState()
            : ListView.builder(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                itemCount: messages.length,
                itemBuilder: (_, i) => ChatBubble(msg: messages[i]),
              ),
      ),
    );
  }

  static Widget buildLastAnswer(List<ChatMessage> messages) {
    ChatMessage? lastAi;
    for (final message in messages.reversed) {
      if (!message.isUser && message.text.trim().isNotEmpty) {
        lastAi = message;
        break;
      }
    }

    return Expanded(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
        child: lastAi == null
            ? _emptyState()
            : Semantics(
                liveRegion: true,
                label: 'শেষ উত্তর। ${lastAi.text}',
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.grey.shade200),
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'শেষ উত্তর',
                          style: TextStyle(
                            color: Colors.grey.shade600,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          lastAi.text,
                          style: const TextStyle(fontSize: 18, height: 1.45),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  static Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Text(
          'ভয়েস কমান্ড বলুন।\nযেমন: “সামনে কী আছে?”',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.grey.shade600,
            fontSize: 18,
            height: 1.5,
          ),
        ),
      ),
    );
  }

  static Widget buildPromptBarContainer({
    required GlobalKey<PromptBarState> promptBarKey,
    required Future<void> Function(String) onPromptWithPhoto,
    required Future<void> Function(String) onPromptTextOnly,
    required bool disabled,
    required bool speechEnabled,
    required bool listening,
    required VoidCallback onToggleListening,
    required bool isGenerating,
    required bool isSpeaking,
    Future<void> Function()? onStopTts,
  }) {
    if (isGenerating || isSpeaking) {
      return _buildStatusWidget(
        isGenerating: isGenerating,
        isSpeaking: isSpeaking,
        onStopTts: onStopTts,
      );
    }

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 8),
        title: const Text('টাচ/টাইপ ব্যাকআপ'),
        subtitle: const Text('ভয়েস কাজ না করলে এখানে টাইপ করে ব্যবহার করুন'),
        children: [
          PromptBar(
            key: promptBarKey,
            onPromptWithPhoto: onPromptWithPhoto,
            onPromptTextOnly: onPromptTextOnly,
            disabled: disabled,
            speechEnabled: speechEnabled,
            listening: listening,
            onToggleListening: onToggleListening,
            onStopTts: onStopTts,
          ),
        ],
      ),
    );
  }

  static Widget _buildStatusWidget({
    required bool isGenerating,
    required bool isSpeaking,
    Future<void> Function()? onStopTts,
  }) {
    final text = isGenerating
        ? (isSpeaking ? 'বিশ্লেষণ ও বলা হচ্ছে…' : 'ছবি বিশ্লেষণ হচ্ছে…')
        : 'উত্তর বলা হচ্ছে…';

    return Semantics(
      liveRegion: true,
      label: text,
      child: Container(
        color: Colors.white,
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                text,
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
            ),
            if (onStopTts != null)
              TextButton.icon(
                onPressed: onStopTts,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('চুপ করুন'),
              ),
          ],
        ),
      ),
    );
  }

  static Widget buildLoadingScreen() {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 22),
            Text(
              'Gemma প্রস্তুত হচ্ছে…',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}
