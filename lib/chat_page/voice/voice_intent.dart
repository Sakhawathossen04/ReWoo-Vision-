enum VoiceIntent {
  describeFront,
  describeCurrent,
  describeRight,
  describeLeft,
  identifyObject,
  readText,
  takePhoto,
  startVideo,
  stopVideo,
  repeatLast,
  stopSpeaking,
  help,
  newChat,
}

extension VoiceIntentLabel on VoiceIntent {
  String get banglaLabel {
    switch (this) {
      case VoiceIntent.describeFront:
        return 'সামনে কী আছে';
      case VoiceIntent.describeCurrent:
        return 'এদিকে দেখো';
      case VoiceIntent.describeRight:
        return 'ডান পাশে কী আছে';
      case VoiceIntent.describeLeft:
        return 'বাম পাশে কী আছে';
      case VoiceIntent.identifyObject:
        return 'এটা কী';
      case VoiceIntent.readText:
        return 'লেখাটা পড়ে শোনাও';
      case VoiceIntent.takePhoto:
        return 'ছবি তোলো';
      case VoiceIntent.startVideo:
        return 'ভিডিও রেকর্ড শুরু করো';
      case VoiceIntent.stopVideo:
        return 'ভিডিও রেকর্ড বন্ধ করো';
      case VoiceIntent.repeatLast:
        return 'আবার বলো';
      case VoiceIntent.stopSpeaking:
        return 'চুপ করো';
      case VoiceIntent.help:
        return 'কী কী বলতে পারি';
      case VoiceIntent.newChat:
        return 'নতুন আলাপ';
    }
  }
}
