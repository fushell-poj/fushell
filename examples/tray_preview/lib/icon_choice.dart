/// Do not let a normal themed icon hide an attention-only pixmap.
String trayIconName({
  required bool needsAttention,
  required String normalName,
  required String attentionName,
  required bool hasAttentionPixmap,
}) {
  if (needsAttention && (attentionName.isNotEmpty || hasAttentionPixmap)) {
    return attentionName;
  }
  return normalName;
}
