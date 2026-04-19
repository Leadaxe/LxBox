/// Метаданные из HTTP-заголовков подписки (`subscription-userinfo`,
/// `profile-title`, `profile-update-interval`, `profile-web-page-url`).
///
/// Поля опциональны — сервер может отдавать любое подмножество. Трафик
/// в байтах. Expire — unix seconds (int), UI конвертирует в DateTime при
/// рендере.
class SubscriptionMeta {
  final int uploadBytes;
  final int downloadBytes;
  final int totalBytes;
  final int? expireTimestamp;
  final String? supportUrl;
  final String? webPageUrl;
  final String? profileTitle;
  final int? updateIntervalHours;

  const SubscriptionMeta({
    this.uploadBytes = 0,
    this.downloadBytes = 0,
    this.totalBytes = 0,
    this.expireTimestamp,
    this.supportUrl,
    this.webPageUrl,
    this.profileTitle,
    this.updateIntervalHours,
  });

  factory SubscriptionMeta.fromJson(Map<String, dynamic> j) => SubscriptionMeta(
        uploadBytes: (j['upload_bytes'] as num?)?.toInt() ?? 0,
        downloadBytes: (j['download_bytes'] as num?)?.toInt() ?? 0,
        totalBytes: (j['total_bytes'] as num?)?.toInt() ?? 0,
        expireTimestamp: (j['expire_timestamp'] as num?)?.toInt(),
        supportUrl: j['support_url'] as String?,
        webPageUrl: j['web_page_url'] as String?,
        profileTitle: j['profile_title'] as String?,
        updateIntervalHours: (j['update_interval_hours'] as num?)?.toInt(),
      );

  Map<String, dynamic> toJson() => {
        if (uploadBytes != 0) 'upload_bytes': uploadBytes,
        if (downloadBytes != 0) 'download_bytes': downloadBytes,
        if (totalBytes != 0) 'total_bytes': totalBytes,
        if (expireTimestamp != null) 'expire_timestamp': expireTimestamp,
        if (supportUrl != null) 'support_url': supportUrl,
        if (webPageUrl != null) 'web_page_url': webPageUrl,
        if (profileTitle != null) 'profile_title': profileTitle,
        if (updateIntervalHours != null)
          'update_interval_hours': updateIntervalHours,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SubscriptionMeta &&
          uploadBytes == other.uploadBytes &&
          downloadBytes == other.downloadBytes &&
          totalBytes == other.totalBytes &&
          expireTimestamp == other.expireTimestamp &&
          supportUrl == other.supportUrl &&
          webPageUrl == other.webPageUrl &&
          profileTitle == other.profileTitle &&
          updateIntervalHours == other.updateIntervalHours);

  @override
  int get hashCode => Object.hash(uploadBytes, downloadBytes, totalBytes,
      expireTimestamp, supportUrl, webPageUrl, profileTitle, updateIntervalHours);
}
