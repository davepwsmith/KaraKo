local _ = require("gettext")
return {
    -- "KaraKo" rather than "Karakeep" so this is distinguishable in the plugin
    -- list from AlgusDark's karakeep.koplugin, which sends bookmarks and
    -- clippings the other way and can be installed alongside this one.
    fullname = _("KaraKo (Karakeep reader)"),
    description = _([[Downloads unread Karakeep articles for offline reading, and sends read status and highlights back.]]),
}
