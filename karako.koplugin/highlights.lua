--[[--
Pushes KOReader highlights back to Karakeep.

KOReader records a highlight's location as a crengine XPointer into the EPUB we
generated; Karakeep wants character offsets into its own rendered content. The
only thing the two representations share is the highlighted text, so matching is
done on text and is necessarily best-effort — see findTextOffsets() in
articleutil.lua for the caveats.

@module koplugin.karako.highlights
]]

local DocSettings = require("docsettings")
local logger = require("logger")

local ArticleUtil = require("articleutil")

local Highlights = {}

-- Karakeep accepts a fixed palette; everything else becomes yellow.
local COLOR_MAP = {
    red = "red", green = "green", blue = "blue", yellow = "yellow",
    cyan = "blue", purple = "red", olive = "green", orange = "yellow",
    gray = "yellow",
}

--- Read the highlights out of a document's sidecar.
--
-- Page bookmarks (annotations with no `drawer`) are not highlights and are
-- skipped, as are highlights with no captured text.
--
-- @tparam string path Path to the downloaded article.
-- @tparam[opt] table doc_settings An already-open sidecar, to save reopening it.
-- @treturn table Array of { text, note, color, chapter, datetime }.
function Highlights.collect(path, doc_settings)
    doc_settings = doc_settings or DocSettings:open(path)
    local annotations = doc_settings:readSetting("annotations")

    if not annotations then
        -- KOReader merged its separate `highlight` and `bookmarks` tables into
        -- one `annotations` array in 2024.04. Older sidecars keep highlights in
        -- the old shape, which is not read here -- but say so, rather than
        -- reporting an annotated document as having no highlights at all.
        if doc_settings:readSetting("highlight") ~= nil then
            logger.warn("KaraKo:", path,
                "holds pre-2024 'highlight' sidecar data, which this plugin does not read;",
                "sending highlights needs KOReader 2024.04 or newer")
        end
        return {}
    end

    local collected = {}
    for _, annotation in ipairs(annotations) do
        if annotation.drawer and annotation.text and annotation.text ~= "" then
            table.insert(collected, {
                text = ArticleUtil.normaliseWhitespace(annotation.text),
                note = annotation.note,
                color = COLOR_MAP[annotation.color or ""] or "yellow",
                chapter = annotation.chapter,
                datetime = annotation.datetime,
            })
        end
    end

    return collected
end

--- Build a lookup of highlights Karakeep already holds, keyed by normalised text.
-- @tparam table api
-- @tparam string bookmark_id
-- @treturn table|nil Set of texts, or nil if the existing set could not be read.
local function fetchExisting(api, bookmark_id)
    local ok, result = api:getHighlights(bookmark_id)
    if not ok then return nil end

    local existing = {}
    for _, highlight in ipairs(result.highlights or result or {}) do
        if type(highlight) == "table" and highlight.text then
            existing[ArticleUtil.normaliseWhitespace(highlight.text)] = true
        end
    end

    return existing
end

--- Push a document's highlights to Karakeep.
--
-- Existing highlights are fetched first and matched by text so that repeated
-- syncs do not create duplicates. If the remote set cannot be read the push is
-- skipped rather than risking duplicates.
--
-- @tparam table api KarakeepApi instance.
-- @tparam string bookmark_id
-- @tparam string path Path to the downloaded article.
-- @tparam[opt] table doc_settings An already-open sidecar, to save reopening it.
-- @treturn number Highlights created.
-- @treturn number Highlights sent without resolved offsets.
function Highlights.push(api, bookmark_id, path, doc_settings)
    local collected = Highlights.collect(path, doc_settings)
    if #collected == 0 then return 0, 0 end

    local existing = fetchExisting(api, bookmark_id)
    if not existing then
        logger.warn("KaraKo: cannot read existing highlights for", bookmark_id, "- skipping push")
        return 0, 0
    end

    local pending = {}
    for _, highlight in ipairs(collected) do
        if not existing[highlight.text] then
            table.insert(pending, highlight)
        end
    end

    -- Nothing new: skip the article fetch entirely. This is the common case on
    -- every sync after the first, so it is worth the early return.
    if #pending == 0 then return 0, 0 end

    -- Fetch the article text once, to resolve offsets against the same content
    -- Karakeep itself renders.
    local article_text = ""
    local ok, bookmark = api:getBookmark(bookmark_id)
    if ok and bookmark and bookmark.content then
        if bookmark.content.htmlContent and bookmark.content.htmlContent ~= "" then
            -- Rendered text, not htmlToText(): offsets have to be counted in
            -- the stream Karakeep measures, which has nothing where the tags
            -- were and keeps its whitespace.
            article_text = ArticleUtil.htmlToRenderedText(bookmark.content.htmlContent)
        elseif bookmark.content.text then
            -- Likewise verbatim -- collapsing runs of whitespace here would
            -- shift every offset past the first one that was collapsed.
            article_text = bookmark.content.text
        end
    end

    local created, unresolved = 0, 0

    for _, highlight in ipairs(pending) do
        if not existing[highlight.text] then
            local start_offset, end_offset = ArticleUtil.findTextOffsets(article_text, highlight.text)

            if not start_offset then
                -- Send it anyway: losing the passage and any note attached to it
                -- is worse than an unanchored highlight, which Karakeep still
                -- displays with its text.
                start_offset, end_offset = 0, 0
                unresolved = unresolved + 1
            end

            local note = highlight.note
            if highlight.chapter and highlight.chapter ~= "" then
                note = note and (note .. "\n\n") or ""
                note = note .. "(" .. highlight.chapter .. ")"
            end

            local pushed = api:createHighlight{
                bookmarkId = bookmark_id,
                startOffset = start_offset,
                endOffset = end_offset,
                text = highlight.text,
                note = note,
                color = highlight.color,
            }

            if pushed then
                created = created + 1
                existing[highlight.text] = true
            else
                logger.warn("KaraKo: failed to create highlight for", bookmark_id)
            end
        end
    end

    return created, unresolved
end

return Highlights
