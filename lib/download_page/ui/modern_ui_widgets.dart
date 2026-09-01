// download_page/ui/modern_ui_widgets.dart

import 'package:flutter/material.dart';
import '../models/enums.dart';
import '../models/models.dart';

class ModernUIWidgets {
  /// Creates a reusable gradient button with consistent styling and disabled states
  static Widget _buildGradientButton({
    required VoidCallback? onPressed,
    required String text,
    required IconData icon,
    List<Color>? gradientColors,
    bool isSecondary = false,
    double? width,
  }) {
    // Default gradient colors based on button type
    final colors =
        gradientColors ??
        (isSecondary
            ? [Colors.grey[400]!, Colors.grey[500]!]
            : [const Color(0xFF2196F3), const Color(0xFF1976D2)]);

    return Container(
      width: width,
      height: 56,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          // Disable gradient when button is disabled
          colors: onPressed != null
              ? colors
              : [Colors.grey[300]!, Colors.grey[400]!],
        ),
        borderRadius: BorderRadius.circular(12),
        // Add shadow only when button is enabled
        boxShadow: onPressed != null
            ? [
                BoxShadow(
                  color: colors[0].withOpacity(0.3),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: Colors.white, size: 20),
                const SizedBox(width: 8),
                Text(
                  text,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Dynamic icon that changes based on download status with smooth animations
  static Widget buildDownloadIcon(
    DownloadStatus status,
    DownloadProgress? progress,
  ) {
    Widget iconWidget;
    Color iconColor = const Color(0xFF2196F3);

    switch (status) {
      case DownloadStatus.notStarted:
      case DownloadStatus.cancelled:
      case DownloadStatus.failed:
        iconWidget = Icon(Icons.download_rounded, size: 80, color: iconColor);
        break;
      case DownloadStatus.checkingAccess:
      case DownloadStatus.authenticating:
        iconWidget = SizedBox(
          width: 80,
          height: 80,
          child: CircularProgressIndicator(
            strokeWidth: 4,
            valueColor: AlwaysStoppedAnimation<Color>(iconColor),
          ),
        );
        break;
      case DownloadStatus.downloading:
      case DownloadStatus.paused:
        iconWidget = Icon(
          status == DownloadStatus.paused
              ? Icons.pause_rounded
              : Icons.download_rounded,
          size: 80,
          color: iconColor,
        );
        break;
      case DownloadStatus.completed:
        iconWidget = Container(
          width: 80,
          height: 80,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [Color(0xFF4CAF50), Color(0xFF2E7D32)],
            ),
          ),
          child: const Icon(Icons.check_rounded, size: 40, color: Colors.white),
        );
        break;
      case DownloadStatus.awaitingLicenseAcceptance:
        iconWidget = Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              colors: [Colors.orange[400]!, Colors.orange[600]!],
            ),
          ),
          child: const Icon(
            Icons.assignment_rounded,
            size: 40,
            color: Colors.white,
          ),
        );
        break;
    }

    // Smooth transition between different icons
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      child: iconWidget,
    );
  }

  /// Status-aware message with dynamic content and progress percentage
  static Widget buildStatusMessage(
    DownloadStatus status,
    DownloadProgress? progress,
    List<String> errorMessages,
  ) {
    String title;
    String subtitle;
    Color textColor = Colors.grey[800]!;

    switch (status) {
      case DownloadStatus.notStarted:
        title = "AI মডেল ডাউনলোড প্রস্তুত";
        subtitle =
            "ডাউনলোড বোতাম চাপুন। প্রথমবার প্রয়োজন হলে একবার Hugging Face লগইন করতে হবে — পরবর্তীতে সব স্বয়ংক্রিয়। প্রায় ৪ GB খালি জায়গা রাখুন।";
        break;
      case DownloadStatus.checkingAccess:
        title = "অ্যাক্সেস পরীক্ষা হচ্ছে";
        subtitle = "মডেল ও প্রয়োজনীয় অনুমতি যাচাই করা হচ্ছে…";
        break;
      case DownloadStatus.authenticating:
        title = "স্বয়ংক্রিয় যাচাই হচ্ছে";
        subtitle = "মডেলের অনুমতি নিশ্চিত করা হচ্ছে… কিছুক্ষণ অপেক্ষা করুন।";
        break;
      case DownloadStatus.awaitingLicenseAcceptance:
        title = "অনুমতি যাচাই হচ্ছে";
        subtitle =
            "ডাউনলোড চালিয়ে যেতে Hugging Face-এ মডেলের লাইসেন্স পড়ে গ্রহণ করুন।";
        break;
      case DownloadStatus.downloading:
        title = "মডেল ডাউনলোড হচ্ছে";
        subtitle =
            "ব্যাকগ্রাউন্ডে ডাউনলোড চলতে থাকবে — আপনি অন্য অ্যাপ ব্যবহার করতে পারেন। নোটিফিকেশনে অগ্রগতি দেখা যাবে।";
        break;
      case DownloadStatus.paused:
        title = "ডাউনলোড বিরতিতে আছে";
        subtitle =
            "ডাউনলোড থামানো আছে। আবার চালু করতে রিজিউম চাপুন।";
        break;
      case DownloadStatus.completed:
        title = "মডেল ডাউনলোড সম্পন্ন";
        subtitle =
            "AI মডেল প্রস্তুত। এখন মূল ভিশন AI অফলাইনে ব্যবহার করা যাবে।";
        break;
      case DownloadStatus.failed:
        title = "ডাউনলোড ব্যর্থ হয়েছে";
        // Use the most recent error message if available
        subtitle = errorMessages.isNotEmpty
            ? "${errorMessages.last} আবার চেষ্টা করুন এবং ইন্টারনেট সংযোগ পরীক্ষা করুন।"
            : "ডাউনলোডে সমস্যা হয়েছে। আবার চেষ্টা করুন।";
        break;
      case DownloadStatus.cancelled:
        title = "AI মডেল ডাউনলোড প্রস্তুত";
        subtitle =
            "ডাউনলোড বোতাম চাপুন। প্রথমবার প্রয়োজন হলে একবার Hugging Face লগইন করতে হবে — পরবর্তীতে সব স্বয়ংক্রিয়। প্রায় ৪ GB খালি জায়গা রাখুন।";
        break;
    }

    return Column(
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: textColor,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 12),
        Text(
          subtitle,
          style: TextStyle(
            fontSize: 16,
            color: textColor.withOpacity(0.7),
            height: 1.4,
          ),
          textAlign: TextAlign.center,
        ),
        // Show large percentage display during active downloads
        if (progress != null &&
            (status == DownloadStatus.downloading ||
                status == DownloadStatus.paused)) ...[
          const SizedBox(height: 20),
          Text(
            "${progress.progressPercent}%",
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w700,
              color: textColor,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }

  /// Progress bar with left-aligned fill and status-based colors
  static Widget buildProgressBar(
    DownloadProgress? progress,
    DownloadStatus status,
  ) {
    if (progress == null ||
        (status != DownloadStatus.downloading &&
            status != DownloadStatus.paused)) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      height: 8,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        color: Colors.grey[200],
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FractionallySizedBox(
          widthFactor: progress.progress,
          child: Container(
            height: 8,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(4),
              // Different colors for paused vs active downloads
              gradient: LinearGradient(
                colors: status == DownloadStatus.paused
                    ? [Colors.orange[400]!, Colors.orange[600]!]
                    : [const Color(0xFF2196F3), const Color(0xFF1976D2)],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Status-dependent action buttons with automatic navigation for completed downloads
  static Widget buildActionButtons(
    DownloadStatus status,
    VoidCallback onStartDownload,
    VoidCallback onPauseDownload,
    VoidCallback onResumeDownload,
    VoidCallback onCancelDownload,
    VoidCallback onGoToChat,
  ) {
    switch (status) {
      case DownloadStatus.notStarted:
      case DownloadStatus.failed:
      case DownloadStatus.cancelled:
        return _buildGradientButton(
          onPressed: onStartDownload,
          text: 'ডাউনলোড',
          icon: Icons.download_rounded,
          width: double.infinity,
        );

      case DownloadStatus.awaitingLicenseAcceptance:
        return _buildGradientButton(
          onPressed: onStartDownload,
          text: 'ডাউনলোড শুরু করুন',
          icon: Icons.download_rounded,
          width: double.infinity,
        );

      case DownloadStatus.downloading:
        return Row(
          children: [
            Expanded(
              child: _buildGradientButton(
                onPressed: onPauseDownload,
                text: 'বিরতি',
                icon: Icons.pause_rounded,
                isSecondary: true,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _buildGradientButton(
                onPressed: onCancelDownload,
                text: 'বাতিল',
                icon: Icons.close_rounded,
                gradientColors: [Colors.red[400]!, Colors.red[600]!],
              ),
            ),
          ],
        );

      case DownloadStatus.paused:
        return _buildGradientButton(
          onPressed: onResumeDownload,
          text: 'রিজিউম',
          icon: Icons.play_arrow_rounded,
          width: double.infinity,
        );

      case DownloadStatus.completed:
        // Auto-navigate instead of showing button
        WidgetsBinding.instance.addPostFrameCallback((_) => onGoToChat());
        return const SizedBox.shrink();

      default:
        return const SizedBox.shrink();
    }
  }

  static Widget buildLogsButton(BuildContext context, VoidCallback onPressed) {
    return Container(
      margin: const EdgeInsets.only(top: 16, right: 16),
      child: Align(
        alignment: Alignment.topRight,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.grey[100],
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey[300]!),
          ),
          child: IconButton(
            icon: Icon(Icons.list_alt_rounded, color: Colors.grey[700]),
            onPressed: onPressed,
            tooltip: 'লগ দেখুন',
          ),
        ),
      ),
    );
  }

  /// Modal bottom sheet for license agreement with proper styling.
  /// Shown when the logged-in Hugging Face account has not accepted the
  /// Gemma model license yet — restored from the proven old version.
  static Widget buildLicenseBottomSheet(
    BuildContext context,
    VoidCallback onCancel,
    VoidCallback onViewLicense,
  ) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 10,
            offset: Offset(0, -5),
          ),
        ],
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar for bottom sheet
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 24),
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [Colors.orange[400]!, Colors.orange[600]!],
              ),
            ),
            child: const Icon(
              Icons.assignment_rounded,
              size: 32,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'মডেল লাইসেন্স গ্রহণ প্রয়োজন',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: Colors.grey[800],
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            'এই মডেল ডাউনলোড করতে Hugging Face-এর লাইসেন্স শর্ত গ্রহণ করতে হবে। লাইসেন্সটি খুলে পড়ে গ্রহণ করার পর ডাউনলোড চালিয়ে যান।',
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey[600],
              height: 1.4,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 32),
          Row(
            children: [
              Expanded(
                child: _buildGradientButton(
                  onPressed: onCancel,
                  text: 'বাতিল',
                  icon: Icons.close_rounded,
                  gradientColors: [Colors.grey[400]!, Colors.grey[500]!],
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _buildGradientButton(
                  onPressed: onViewLicense,
                  text: 'লাইসেন্স খুলুন',
                  icon: Icons.open_in_new_rounded,
                  gradientColors: [Colors.orange[400]!, Colors.orange[600]!],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
