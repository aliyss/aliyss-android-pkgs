"""Category classification for Android apps in this repository.

Classification sources, in order of preference:

1. curated category from a F-Droid-format index: ``index-v2.json`` carries
   per-app categories curated by the F-Droid / IzzyOnDroid maintainers
   (``FDROID_CATEGORY_MAP`` maps those onto this repo's taxonomy);
2. keyword heuristics over the app id plus the human-readable name/summary
   (``guess_category``);
3. fallback: ``misc``.
"""

from __future__ import annotations

import re

# Canonical list of top-level categories (also the directories under pkgs/).
REPO_CATEGORIES = [
    "browser", "camera", "connectivity", "development", "education",
    "finance", "games", "graphics", "health", "keyboard", "maps",
    "messaging", "misc", "music", "productivity", "reading", "security",
    "social", "time", "tools", "video", "weather", "writing",
]

# Priority when an app spans several curated categories: distinctive buckets
# (security, games, ...) win over broad ones. Order mirrors the keyword
# checks in guess_category().
CATEGORY_PRIORITY = [
    "security", "finance", "games", "social", "messaging", "browser",
    "maps", "music", "video", "camera", "graphics", "reading",
    "education", "health", "weather", "keyboard", "writing",
    "connectivity", "development", "time", "tools", "productivity", "misc",
]

# F-Droid / IzzyOnDroid index-v2 category -> repository category.
#
# Broad buckets that span several repo categories (Internet, Multimedia,
# System, ...) are deliberately *not* listed here: they are resolved by the
# keyword heuristics in guess_category() over the app's name/summary instead.
FDROID_CATEGORY_MAP = {
    # games
    "Action Game": "games", "Board Game": "games", "Card Game": "games",
    "Casual Game": "games", "Dice": "games", "Educational Game": "games",
    "Game Helper": "games", "Games": "games", "Party Game": "games",
    "Platformer Game": "games", "Puzzle Game": "games",
    "Role-Playing Game": "games", "Shooter Game": "games", "Sport Game": "games",
    "Strategy Game": "games", "Visual Novel": "games", "Word Game": "games",
    # finance
    "Finance Manager": "finance", "Market & Price": "finance", "Money": "finance",
    "Pass Wallet": "finance", "Wallet": "finance",
    # maps / travel
    "Location Tracker & Sharer": "maps", "Navigation": "maps",
    "Public Transport": "maps", "Travel & Local": "maps",
    # weather
    "Weather": "weather",
    # health
    "Diet": "health", "Health Manager": "health", "Meditation": "health",
    "Sports & Health": "health", "Workout": "health",
    # reading
    "Ebook Reader": "reading", "News": "reading", "Reading": "reading",
    # education
    "Science & Education": "education", "Translation & Dictionary": "education",
    # security
    "File Encryption & Vault": "security", "Firewall": "security",
    "Password & 2FA": "security", "Security": "security", "VPN & Proxy": "security",
    # messaging
    "AI Chat": "messaging", "Messaging": "messaging", "Phone & SMS": "messaging",
    "Voice & Video Chat": "messaging",
    # social
    "Forum": "social", "Social Network": "social",
    # browser
    "Browser": "browser",
    # productivity
    "Bookmark": "productivity", "Calculator": "productivity",
    "Calendar & Agenda": "productivity", "Cloud Storage & File Sync": "productivity",
    "Contact": "productivity", "Email": "productivity", "Food": "productivity",
    "Habit Tracker": "productivity", "Inventory": "productivity", "OCR": "productivity",
    "Office": "productivity", "Push": "productivity", "Recipe Manager": "productivity",
    "Schedule": "productivity", "Shopping List": "productivity", "Task": "productivity",
    "Text to Speech": "productivity", "Unit Convertor": "productivity",
    # writing
    "Note": "writing", "Text Editor": "writing", "Writing": "writing",
    # connectivity
    "Cast": "connectivity", "Connectivity": "connectivity", "DNS & Hosts": "connectivity",
    "Download": "connectivity", "File Transfer": "connectivity",
    "Network Analyzer": "connectivity", "Remote Access": "connectivity",
    "Remote Controller": "connectivity",
    # development
    "App Manager": "development", "App Store & Updater": "development",
    "Code & Forge": "development", "Development": "development",
    # camera / graphics
    "Camera": "camera",
    "Draw": "graphics", "Gallery": "graphics", "Graphics": "graphics",
    "Icon Pack": "graphics", "Theming": "graphics", "Wallpaper": "graphics",
    # keyboard
    "Keyboard & IME": "keyboard",
    # time
    "Alarm Clock": "time", "Clock": "time", "Stopwatch": "time",
    "Time Tracker": "time", "Timer": "time", "Time": "time",
    # tools
    "Automation": "tools", "Battery": "tools", "Emulator": "tools",
    "File Manager": "tools", "Flashlight": "tools", "Launcher": "tools",
    "Notification": "tools", "Recorder": "tools", "System": "tools",
    "Volume": "tools", "Xposed": "tools",
    # video / music sub-buckets
    "Local Media Player": "video", "Online Media Player": "video",
    "Lyrics": "music", "Music Practice Tool": "music", "Podcast": "music",
    "Radio": "music",
}

# Generic last-segment app-id suffixes that carry no meaning ("app", "fdroid"...)
_GENERIC_SUFFIX = {
    "app", "apps", "android", "mobile", "player", "client", "web", "gms",
    "play", "fdroid", "accrescent", "oss", "release", "repo", "core", "lite",
    "pro", "prod", "debug", "nightly", "beta", "test",
}

# pname override map for well-known apps (empty -> derive from app id).
PNAME_OVERRIDES = {
    "org.thoughtcrime.securesms": "signal",
    "org.telegram.messenger": "telegram",
    "org.mozilla.firefox": "firefox",
    "com.spotify.music": "spotify",
}


def derive_pname(app_id: str) -> str:
    if app_id in PNAME_OVERRIDES:
        return PNAME_OVERRIDES[app_id]
    parts = app_id.split(".")
    primary = parts[-2] if parts[-1].lower() in _GENERIC_SUFFIX and len(parts) > 1 else parts[-1]
    # drop leading "com"/"org"/"app"/co.xx country domains as noise
    while primary.lower() in {"com", "org", "app", "net", "io", "co", "cc", "at", "ch", "appinventor"} and len(parts) > 1:
        parts = parts[:-1]
        primary = parts[-1]
    return primary


def guess_category(app_id: str, text: str = "") -> str:
    """Classify an app id (+ optional human-readable name/summary) into a repo category."""
    pname = derive_pname(app_id).lower()
    tokens = re.split(r"[^a-z0-9]+", f"{app_id} {pname} {text}".lower())

    def has(*words):
        return any(any(w in t for w in words) for t in tokens)

    # Security/privacy first: password managers, 2FA, VPNs, crypto, firewalls.
    if has("password", "authenticator", "2fa", "otp", "totp", "keepass", "bitwarden",
           "vpn", "wireguard", "torproject", "orbot", "protonvpn", "droidvpn", "crypt",
           "encrypt", "pgp", "openkeychain", "privacy", "appverifier", "keychain",
           "firewall", "vault", "authy", "aegis", "steghide", "untrack", "sanitize"):
        return "security"
    if has("bank", "finance", "wallet", "bitcoin", "monero", "payment", "invoice",
           "budget", "expense", "stock", "trade", "invest", "ledger", "money",
           "coin", "currency", "cryptocurrency"):
        return "finance"
    if has("game", "chess", "sudoku", "puzzle", "tetris", "minecraft", "snake",
           "cards", "solitaire", "checkers", "mahjong", "wordle", "crossword",
           "scrabble", "platformer", "rpg", "shooter", "emulator"):
        return "games"
    if has("reddit", "mastodon", "lemmy", "kbin", "instagram", "tiktok", "facebook",
           "twitter", "tumblr", "social", "pixelfed", "microblog", "forum", "discord",
           "bluesky", "friendica", "fediverse", "community", "dating"):
        return "social"
    if has("signal", "telegram", "simplex", "matrix", "element", "fluffy", "threema",
           "delta", "iridium", "conversations", "quicksy", "briar", "olvid", "snikket",
           "xabber", "beeper", "berla", "session", "sms", "mms", "dial", "dialer",
           "sip", "voip", "whatsapp", "jami", "chat"):
        return "messaging"
    if has("firefox", "chrome", "bromite", "mull", "duckduckgo", "javascript",
           "browser", "chromium", "vivaldi", "brave", "webview", "gecko", "webkit"):
        return "browser"
    if has("organicmaps", "osmand", "comaps", "maps", "navigation", "route", "gps",
           "atlas", "geocache", "geocaching", "navi", "compass"):
        return "maps"
    if has("spotify", "music", "pocketcasts", "cover", "vinyl", "musicolet",
           "soundcloud", "jam", "retromusic", "melodix", "radio", "podcast",
           "lyrics", "bandcamp", "equalizer", "metronome", "tuner", "midi",
           "synth", "tabs", "ringtone", "karaoke", "binaural", "soundboard",
           "sound", "song"):
        return "music"
    if has("newpipe", "mpv", "vlc", "kodi", "youtube", "video", "tv", "plex",
           "jellyfin", "audiobook", "mihon", "tachiyomi", "anime", "stream",
           "subtitle", "media", "movie", "peertube", "crunchyroll",
           "cinema", "tmdb"):
        return "video"
    if has("camera", "photo", "picture", "scanner", "selfie"):
        return "camera"
    if has("icon", "wallpaper", "theme", "draw", "paint", "sketch", "gallery",
           "pixel", "sticker", "image"):
        return "graphics"
    if has("note", "notes", "notebook", "notepad", "diary", "journal", "memo",
           "markdown", "text", "write"):
        return "writing"
    if has("koreader", "reader", "book", "ebook", "librera", "comic",
           "manga", "newspaper", "news", "epub", "pdf", "novel", "quran",
           "scripture", "quote", "bible", "rosary", "gospel"):
        return "reading"
    if has("learn", "school", "university", "quiz", "flashcard", "dictionary",
           "language", "vocabulary", "grammar", "study", "course", "alphabet",
           "math", "wiki", "science", "translate", "chemistry", "biology",
           "physics", "kids", "children", "preschool"):
        return "education"
    if has("health", "fitness", "sleep", "heart", "pulse", "medical", "medicine",
           "workout", "calorie", "yoga", "therapy", "meditation", "diet", "step",
           "pedometer", "weight", "glucose", "blood", "insulin", "pregnancy",
           "breath", "mindfulness"):
        return "health"
    if has("weather", "forecast", "meteo", "radar", "storm", "temperature",
           "windy", "barometer"):
        return "weather"
    if has("keyboard", "swipe", "typing"):
        return "keyboard"
    if has("network", "wifi", "dns", "hosts", "remote", "transfer", "download",
           "cast", "chromecast", "dlna", "ftp", "sftp", "ssh", "nfc", "bluetooth",
           "hotspot", "tether", "proxy", "ping", "traceroute", "bandwidth",
           "speedtest", "server", "http", "torrent", "zerotier", "sstp"):
        return "connectivity"
    if has("code", "git", "github", "gitlab", "forge", "compiler", "sdk",
           "developer", "plugin", "kotlin", "python", "rust", "golang", "lua",
           "digitalocean"):
        return "development"
    if has("clock", "timer", "alarm", "stopwatch", "time", "pomodoro", "chrono",
           "prayer", "azan", "adhan"):
        return "time"
    if has("termux", "fdroid", "lawnchair", "shell", "root", "battery", "tasker",
           "automate", "macro", "adb", "monitor", "terminal", "emulator",
           "benchmark", "system", "launcher", "flashlight", "volume", "xposed",
           "magisk", "recovery", "bootloader", "settings"):
        return "tools"
    if has("mail", "thunderbird", "k9", "fairemail", "envelope", "nextcloud",
           "syncthing", "onedrive", "drive", "cloud", "filemanager", "files",
           "calendar", "schedule", "agenda", "document", "office", "spreadsheet",
           "presentation", "slides", "task", "todo", "habit", "recipe", "shopping",
           "inventory", "calculator", "convert", "email", "contact", "addressbook"):
        return "productivity"
    return "misc"


def category_from_index(app_id: str, categories: list[str], summary: str = "", name: str = "") -> str:
    """Pick a repo category for an app given its index-v2 metadata.

    Curated index categories win; when several map to different repo categories
    (index categories are alphabetical, not prioritized) the most distinctive
    one wins. Broad/unmapped buckets fall back to keyword heuristics over the
    human-readable name/summary.
    """
    mapped = {FDROID_CATEGORY_MAP[c] for c in (categories or []) if c in FDROID_CATEGORY_MAP}
    if mapped:
        return min(mapped, key=CATEGORY_PRIORITY.index)
    return guess_category(app_id, text=f"{name} {summary}")
