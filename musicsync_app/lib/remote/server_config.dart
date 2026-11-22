/// Configurația serverului MusicSync (actualizări + teme comune).
/// Singurul loc unde se schimbă adresa serverului.
library;

const String kServerBaseUrl = 'https://musicsync-server-9zf9.onrender.com';

/// Repo-ul GitHub cu release-urile aplicației (APK + version.json).
const String kAppRepo = 'MusicSync-App/music_sync';

/// Rezervă când serverul nu răspunde: version.json din ultimul release.
const String kFallbackVersionJsonUrl = 'https://github.com/$kAppRepo/releases/latest/download/version.json';

/// Pagina release-urilor (Windows: actualizarea se descarcă din browser).
const String kReleasesPageUrl = 'https://github.com/$kAppRepo/releases/latest';

/// Render (plan gratuit) poate porni la rece până la ~60 s.
const Duration kServerTimeout = Duration(seconds: 75);
const Duration kUploadTimeout = Duration(seconds: 180);
const Duration kDownloadTimeout = Duration(seconds: 60);

/// Cât de des verificăm automat actualizările / temele comune.
const Duration kRemoteCheckInterval = Duration(hours: 6);
