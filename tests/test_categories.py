"""Unit tests for scripts/categories.py (offline)."""

import categories as cat


def test_repo_categories_sorted_unique():
    assert cat.REPO_CATEGORIES == sorted(cat.REPO_CATEGORIES)
    assert len(cat.REPO_CATEGORIES) == len(set(cat.REPO_CATEGORIES))
    assert "misc" in cat.REPO_CATEGORIES


def test_category_priority_covers_all_repo_categories():
    assert sorted(cat.CATEGORY_PRIORITY) == cat.REPO_CATEGORIES


def test_fdroid_category_map_targets_exist():
    for src, target in cat.FDROID_CATEGORY_MAP.items():
        assert target in cat.REPO_CATEGORIES, f"{src!r} maps to unknown category {target!r}"


def test_fdroid_category_map_covers_entire_index_taxonomy():
    # every category published by the F-Droid / IzzyOnDroid indexes must map to
    # a repo category, or be a known-broad bucket resolved by keywords instead
    taxonomy = [
        "System",
        "Internet",
        "Multimedia",
        "Science & Education",
        "Connectivity",
        "Security",
        "Sports & Health",
        "Reading",
        "Writing",
        "Navigation",
        "Keyboard & IME",
        "Development",
        "Note",
        "Phone & SMS",
        "Graphics",
        "Task",
        "Puzzle Game",
        "Timer",
        "Game Helper",
        "Local Media Player",
        "Calendar & Agenda",
        "Finance Manager",
        "Password & 2FA",
        "Online Media Player",
        "Messaging",
        "VPN & Proxy",
        "Wallpaper",
        "Launcher",
        "Remote Controller",
        "Health Manager",
        "Translation & Dictionary",
        "News",
        "Calculator",
        "Board Game",
        "Music Practice Tool",
        "Workout",
        "Social Network",
        "Cloud Storage & File Sync",
        "Market & Price",
        "Camera",
        "Habit Tracker",
        "Wallet",
        "Religion",
        "Ebook Reader",
        "File Transfer",
        "App Manager",
        "Educational Game",
        "Weather",
        "Time Tracker",
        "Action Game",
        "Alarm Clock",
        "Notification",
        "Download",
        "Location Tracker & Sharer",
        "Forum",
        "Clock",
        "Schedule",
        "AI Chat",
        "Voice & Video Chat",
        "File Encryption & Vault",
        "Casual Game",
        "Network Analyzer",
        "Public Transport",
        "Card Game",
        "Draw",
        "Recorder",
        "Email",
        "Diet",
        "Podcast",
        "DNS & Hosts",
        "Gallery",
        "Strategy Game",
        "Role-Playing Game",
        "Browser",
        "Dice",
        "Firewall",
        "Shopping List",
        "Radio",
        "Text Editor",
        "Cast",
        "App Store & Updater",
        "Inventory",
        "Word Game",
        "Meditation",
        "Bookmark",
        "Remote Access",
        "Icon Pack",
        "Volume",
        "File Manager",
        "Battery",
        "Shooter Game",
        "Unit Convertor",
        "Recipe Manager",
        "Stopwatch",
        "Party Game",
        "Emulator",
        "Flashlight",
        "Code & Forge",
        "OCR",
        "Push",
        "Text to Speech",
        "Pass Wallet",
        "Lyrics",
        "Contact",
        "Platformer Game",
        "Sport Game",
        "Theming",
        "Visual Novel",
        "Time",
        "Xposed",
        "Office",
        "Automation",
        "Food",
        "Games",
    ]
    broad_by_keywords = {"Internet", "Multimedia", "Religion"}  # soft buckets: keywords decide
    unmapped = {c for c in taxonomy if c not in cat.FDROID_CATEGORY_MAP}
    assert unmapped <= broad_by_keywords, (
        f"unmapped index categories: {unmapped - broad_by_keywords}"
    )


def test_fdroid_category_map_covers_curated_taxonomy():
    # spot-check the important curated buckets
    assert cat.FDROID_CATEGORY_MAP["Puzzle Game"] == "games"
    assert cat.FDROID_CATEGORY_MAP["Money"] == "finance"
    assert cat.FDROID_CATEGORY_MAP["Navigation"] == "maps"
    assert cat.FDROID_CATEGORY_MAP["Password & 2FA"] == "security"
    assert cat.FDROID_CATEGORY_MAP["Messaging"] == "messaging"
    assert cat.FDROID_CATEGORY_MAP["Keyboard & IME"] == "keyboard"
    assert cat.FDROID_CATEGORY_MAP["Writing"] == "writing"
    assert cat.FDROID_CATEGORY_MAP["Connectivity"] == "connectivity"
    assert cat.FDROID_CATEGORY_MAP["Development"] == "development"
    assert cat.FDROID_CATEGORY_MAP["Timer"] == "time"
    assert cat.FDROID_CATEGORY_MAP["Weather"] == "weather"
    assert cat.FDROID_CATEGORY_MAP["Sports & Health"] == "health"


def test_category_from_index_uses_curated_first():
    assert (
        cat.category_from_index("com.foo", ["Internet", "Messaging"], "chat", "Foo") == "messaging"
    )
    assert cat.category_from_index("com.foo", ["Money"], "", "Foo") == "finance"


def test_category_from_index_prefers_distinctive_of_several():
    # index categories are alphabetical, not prioritized: ToS;DR is a privacy/
    # security app even though "Navigation" sorts before "Security"
    assert (
        cat.category_from_index(
            "xyz.ptgms.tosdr",
            ["Internet", "Navigation", "Reading", "Security"],
            "ToS summaries",
            "ToS;DR",
        )
        == "security"
    )
    assert (
        cat.category_from_index("com.grocery.app", ["Diet", "Shopping List", "Sports & Health"])
        == "health"
    )


def test_category_from_index_falls_back_to_keywords_for_broad_buckets():
    # "Internet" is deliberately unmapped -> keywords on summary/name decide
    assert (
        cat.category_from_index("com.foo.bar", ["Internet"], "a fast web browser", "Foo")
        == "browser"
    )
    assert (
        cat.category_from_index("com.foo.bar", ["Multimedia"], "offline music player", "Foo")
        == "music"
    )


def test_category_from_index_empty_metadata_uses_app_id():
    assert cat.category_from_index("com.alarmclock.timer", [], "", "") == "time"


def test_guess_category_no_greedy_substring_matches():
    # "tor" is a substring of calculator/editor/inventory/monitor: never let
    # short hazardous words hijack unrelated apps into security
    assert cat.guess_category("com.simplemobiletools.calculator") == "productivity"
    assert cat.guess_category("com.foo.inventory") == "productivity"
    assert cat.guess_category("com.foo.monitorapp") == "tools"
    assert cat.guess_category("com.foo.texteditor") == "writing"
    assert cat.guess_category("com.foo.codeeditor") == "development"
    # ...while real Tor apps still land in security
    assert cat.guess_category("org.torproject.android") == "security"
    # "kid" is a substring of "kidney": don't route health apps to education
    assert cat.guess_category("com.foo.kidneytracker") != "education"
    # "gita" is a substring of "digital": a DigitalOcean client is not scripture
    assert cat.guess_category("com.yassirh.digitalocean") == "development"


def test_guess_category_uses_text_signal():
    # keyword fallback also consults human-readable text
    assert cat.guess_category("com.unknown.app", text="read the news every morning") == "reading"
    assert cat.guess_category("com.unknown.app", text="") == "misc"
