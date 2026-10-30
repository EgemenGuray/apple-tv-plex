/// Optional build-time API keys, so you don't have to type them with the remote. All free.
/// Leave empty to enter them in Settings → Online services instead.
/// To keep your keys out of git after filling them in: `git update-index --skip-worktree PlexHDR/Services/Keys.swift`
enum BuildKeys {
    static let tmdb = ""                   // themoviedb.org → Settings → API (v3 key or v4 read token)
    static let omdb = ""                   // omdbapi.com → API Key
    static let openSubtitles = ""          // opensubtitles.com → Profile → API consumers
    static let openSubtitlesUser = ""
    static let openSubtitlesPassword = ""
}
