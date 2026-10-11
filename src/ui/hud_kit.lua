-- Shared helpers for the Dota HUD and shop: Dota art with Warcraft III
-- fallbacks, frame factories, cached setters and screen geometry.
--
-- Art: the launcher converts the Dota 2 HUD images listed in
-- specs/hud_assets.json into war3mapImported\Hud\<name>.blp. Maps built
-- without the launcher (test builds) have none of them, so every element also
-- names a built-in Warcraft III texture; Kit.dota picks which set is used.
--
-- Multiplayer: frames are created for every player (handle ids must match);
-- only visibility, texts and positions are changed inside local code.
define("hud_kit", function()
    local Kit = {}

    Kit.DIR = "war3mapImported\\Hud\\"
    -- nil: detect (a launcher-built map carries the Dota voice lines, and the
    -- same launcher run adds the HUD art); true / false: force either set.
    Kit.FORCE_DOTA_TEXTURES = nil
    Kit.dota = false

    local TEAM = "ReplaceableTextures\\TeamColor\\TeamColor%02d.blp"
    local BTN = "ReplaceableTextures\\CommandButtons\\%s.blp"

    -- Solid colours from the player-colour textures (all 24 exist in 2.0).
    function Kit.team(n) return string.format(TEAM, n) end
    function Kit.btn(name) return string.format(BTN, name) end

    Kit.C = {
        dark = Kit.team(20),      -- coal: panels and wells
        gold = Kit.team(4),       -- yellow: learn buttons, XP, highlights
        green = Kit.team(6),      -- health
        blue = Kit.team(1),       -- mana
        gray = Kit.team(8),
        red = Kit.team(0),
        snow = Kit.team(21),
    }

    -- Dota image `name` (a target in specs/hud_assets.json) or the fallback.
    Kit.used = {}
    function Kit.tex(name, fallback)
        Kit.used[name] = true
        if Kit.dota then return Kit.DIR .. name .. ".blp" end
        return fallback
    end

    -- A launcher-built map has the Dota voice lines; sounds that are not in
    -- the map have no duration. Any first line of the events every launcher
    -- version extracts will do: a map made by an older launcher lacks newer
    -- events such as "aegis" (2026-10-11). Local result, used for visuals only.
    local LASTING = {"spawn", "move", "attack", "kill", "death", "levelup"}
    function Kit.detect()
        if Kit.FORCE_DOTA_TEXTURES ~= nil then
            Kit.dota = Kit.FORCE_DOTA_TEXTURES
            return Kit.dota
        end
        Kit.dota = false
        local ok, sounds = pcall(use, "data.sounds")
        if ok and type(sounds) == "table" then
            local heroes = {}
            for hero in pairs(sounds) do heroes[#heroes + 1] = hero end
            table.sort(heroes)
            for _, hero in ipairs(heroes) do
                for _, ev in ipairs(LASTING) do
                    local list = sounds[hero][ev]
                    if type(list) == "table" and list[1] and GetSoundFileDuration(list[1]) > 0 then
                        Kit.dota = true
                        return true
                    end
                end
            end
        end
        return Kit.dota
    end

    ---------------------------------------------------------------- handles

    function Kit.valid(f)
        return f ~= nil and GetHandleId(f) ~= 0
    end

    function Kit.same(a, b)
        return Kit.valid(a) and Kit.valid(b) and GetHandleId(a) == GetHandleId(b)
    end

    ---------------------------------------------------------------- factories

    -- Setter caches (see below); `alphas` also holds each frame's alpha so
    -- Kit.place applies it again once the frame is anchored (alpha set on an
    -- unanchored frame can be reset by the first layout).
    local texts, shown, texs, vals, alphas = {}, {}, {}, {}, {}

    -- Plain container; it has no size, so it never blocks the mouse.
    function Kit.frame(parent)
        return BlzCreateFrameByType("FRAME", "", parent, "", 0)
    end

    function Kit.simple(parent)
        return BlzCreateFrameByType("SIMPLEFRAME", "", parent, "", 0)
    end

    function Kit.backdrop(parent, tex, alpha)
        local f = BlzCreateFrameByType("BACKDROP", "", parent, "", 0)
        BlzFrameSetTexture(f, tex, 0, true)
        if alpha then
            alphas[f] = alpha
            BlzFrameSetAlpha(f, alpha)
        end
        return f
    end

    -- Text on an unscaled box: the TEXT frame copies the box and only its
    -- glyphs are scaled (scale = font size relative to the default ~0.012).
    function Kit.text(parent, scale, horz, vert)
        local box = BlzCreateFrameByType("FRAME", "", parent, "", 0)
        local t = BlzCreateFrameByType("TEXT", "", box, "", 0)
        BlzFrameSetAllPoints(t, box)
        BlzFrameSetEnable(box, false)          -- neither catches the mouse
        BlzFrameSetEnable(t, false)
        BlzFrameSetTextAlignment(t, vert or TEXT_JUSTIFY_MIDDLE, horz or TEXT_JUSTIFY_CENTER)
        BlzFrameSetText(t, "")
        if scale and scale ~= 1 then BlzFrameSetScale(t, scale) end
        return {box = box, t = t}
    end

    -- Text that covers a button (its label); follows the button around.
    -- In game a label takes the mouse from its button even when disabled
    -- (probe panel, 2026-10-10), so a labelled button gets a transparent
    -- click layer above its children: register events on Kit.hit(button).
    Kit.hitOf = {}
    function Kit.label(button, scale, horz, vert)
        local tx = Kit.text(button, scale, horz, vert)
        BlzFrameSetAllPoints(tx.box, button)
        if not Kit.hitOf[button] then
            local hit = BlzCreateFrameByType("GLUEBUTTON", "", button, "ScoreScreenTabButtonTemplate", 0)
            BlzFrameSetAllPoints(hit, button)
            BlzFrameSetLevel(hit, 9)
            Kit.hitOf[button] = hit
        end
        return tx
    end

    -- The frame that receives the mouse for a button made by Kit.button.
    function Kit.hit(button)
        return Kit.hitOf[button] or button
    end

    -- A transparent frame that takes the mouse, so clicks on the HUD's empty
    -- space never reach the world. Our buttons stay usable as its
    -- descendants: in game a child button gets the mouse before its parent
    -- (Kit.label's click layers work that way), while an unrelated catcher
    -- over a panel took every click from the buttons on it (2026-10-10).
    -- Test builds switch all blockers off and on with -block.
    Kit.blockers = {}
    function Kit.blocker(parent)
        local b = BlzCreateFrameByType("GLUEBUTTON", "", parent, "ScoreScreenTabButtonTemplate", 0)
        -- The template's mouse-over highlight, an additive glow, flared over
        -- whole panels under the cursor (2026-10-11): fade the template's own
        -- children, before any of ours exist.
        for i = 0, BlzFrameGetChildrenCount(b) - 1 do
            BlzFrameSetAlpha(BlzFrameGetChild(b, i), 0)
        end
        Kit.blockers[#Kit.blockers + 1] = b
        return b
    end

    -- Status bar (SimpleFrame family: drawn above the HUD backgrounds).
    function Kit.bar(parent, tex)
        local b = BlzCreateFrameByType("SIMPLESTATUSBAR", "", parent, "", 0)
        BlzFrameSetTexture(b, tex, 0, true)
        BlzFrameSetMinMaxValue(b, 0, 1)
        BlzFrameSetValue(b, 0)
        return b
    end

    -- Cooldown display on an item button, the way Dota shows it: a dark
    -- clockwise sweep with the seconds left in the middle. The sweep is WC3's
    -- own cooldown indicator model on a STATUSBAR, whose value picks the point
    -- of the model's sweep animation; Kit.SWEEP = "wipe" shows a dark overlay
    -- that shrinks downwards instead (test builds toggle it with -sweep).
    -- The model is a 0.038 square drawn from its bottom-left corner, so it is
    -- scaled to the slot's height and centred.
    Kit.SWEEP = "model"
    Kit.SWEEP_MODEL = "UI\\Feedback\\Cooldown\\UI-Cooldown-Indicator.mdl"
    local SWEEP_SIZE = 0.038

    function Kit.sweep(button)
        local cd = {box = BlzCreateFrameByType("FRAME", "", button, "", 0)}
        cd.bar = BlzCreateFrameByType("STATUSBAR", "", cd.box, "", 0)
        BlzFrameSetAllPoints(cd.bar, cd.box)
        BlzFrameSetModel(cd.bar, Kit.SWEEP_MODEL, 0)
        BlzFrameSetMinMaxValue(cd.bar, 0, 1)
        BlzFrameSetValue(cd.bar, 0)
        cd.wipe = Kit.backdrop(button, Kit.C.dark, 170)
        cd.text = Kit.text(button, 1.0)
        BlzFrameSetAllPoints(cd.text.box, button)
        Kit.show(cd.box, false)
        Kit.show(cd.wipe, false)
        Kit.show(cd.text.box, false)
        return cd
    end

    function Kit.placeSweep(cd, x0, y0, x1, y1)
        local h = y1 - y0
        local cx = (x0 + x1) / 2
        Kit.place(cd.box, cx - h / 2, y0, cx + h / 2, y1)
        if cd.scale ~= h / SWEEP_SIZE then
            cd.scale = h / SWEEP_SIZE
            BlzFrameSetScale(cd.bar, cd.scale)
        end
        cd.x0, cd.y0, cd.x1, cd.y1, cd.wipeH = x0, y0, x1, y1, nil
    end

    -- Local: seconds left and the cooldown's full length (0: none).
    function Kit.setSweep(cd, left, total)
        local on = left > 0.05 and total > 0 and cd.x0 ~= nil
        local model = Kit.SWEEP == "model"
        Kit.show(cd.box, on and model)
        Kit.show(cd.wipe, on and not model)
        Kit.show(cd.text.box, on)
        if not on then return end
        local share = math.min(1, left / total)
        if model then
            Kit.setValue(cd.bar, 1 - share)
        else
            local h = math.floor((cd.y1 - cd.y0) * share * 1000 + 0.5) / 1000
            if h ~= cd.wipeH then
                cd.wipeH = h
                Kit.place(cd.wipe, cd.x0, cd.y0, cd.x1, cd.y0 + math.max(0.0005, h))
            end
        end
        Kit.setText(cd.text, "|cffffffff" .. math.ceil(left) .. "|r")
    end

    -- Test builds: logs every hover and click a frame receives, to see which
    -- of our buttons get mouse input in game at all. Separate trigger, so the
    -- frame's own handlers keep their behaviour.
    function Kit.probe(frame, label, clicksOnly)
        if not BUILD_TEST_MODE or not frame then return end
        frame = Kit.hit(frame)
        local t = CreateTrigger()
        if not clicksOnly then BlzTriggerRegisterFrameEvent(t, frame, FRAMEEVENT_MOUSE_ENTER) end
        BlzTriggerRegisterFrameEvent(t, frame, FRAMEEVENT_CONTROL_CLICK)
        TriggerAddAction(t, function()
            use("log").info(string.format("ui probe %s event %d player %d", label,
                GetHandleId(BlzGetTriggerFrameEvent()), GetPlayerId(GetTriggerPlayer())))
            use("log").flush()
        end)
    end

    -- Clickable button with an image; returns button, image. A template-less
    -- BUTTON with children got no mouse input in game; this is the common
    -- working pattern: an invisible GLUEBUTTON template plus a BACKDROP child.
    function Kit.button(parent, tex)
        local b = BlzCreateFrameByType("GLUEBUTTON", "", parent, "ScoreScreenTabButtonTemplate", 0)
        local img = BlzCreateFrameByType("BACKDROP", "", b, "", 0)
        BlzFrameSetAllPoints(img, b)
        BlzFrameSetTexture(img, tex, 0, true)
        return b, img
    end

    -- Test builds: six button variants side by side, each probed, to learn
    -- which construction receives the mouse in this game version. Created for
    -- every player, shown locally with the -uiprobe chat command.
    function Kit.probePanel()
        if not BUILD_TEST_MODE or Kit.probeRoot then return end
        local root = BlzCreateFrameByType("FRAME", "", BlzGetOriginFrame(ORIGIN_FRAME_GAME_UI, 0), "", 0)
        Kit.probeRoot = root
        local function make(i)
            local b, img
            if i == 1 then
                b = BlzCreateFrameByType("BUTTON", "", root, "", 0)
            elseif i <= 3 or i == 7 then
                b = BlzCreateFrameByType("BUTTON", "", root, "", 0)
                img = BlzCreateFrameByType("BACKDROP", "", b, "", 0)
            elseif i <= 5 then
                b = BlzCreateFrameByType("GLUEBUTTON", "", root, "ScoreScreenTabButtonTemplate", 0)
                img = BlzCreateFrameByType("BACKDROP", "", b, "", 0)
            elseif i == 6 then
                b = BlzCreateFrame("ScriptDialogButton", root, 0, 0)
            else
                b, img = Kit.button(root, Kit.btn("BTNHolyBolt"))   -- 8: what the HUD uses now
            end
            local x = 0.02 + (i - 1) * 0.05
            Kit.place(b, x, 0.30, x + 0.035, 0.335)
            if img then
                BlzFrameSetAllPoints(img, b)
                BlzFrameSetTexture(img, Kit.btn("BTNHolyBolt"), 0, true)
            end
            if i == 3 or i == 5 or i == 8 then Kit.setText(Kit.label(b, 0.8), "L") end
            if i == 6 then BlzFrameSetText(b, "6") end
            if i == 7 then
                -- a bare TEXT child (no box frame), disabled
                local t = BlzCreateFrameByType("TEXT", "", b, "", 0)
                BlzFrameSetAllPoints(t, b)
                BlzFrameSetEnable(t, false)
                BlzFrameSetText(t, "T")
            end
            local cap = Kit.text(root, 1.0)
            Kit.placeText(cap, x, 0.337, x + 0.035, 0.352)
            Kit.setText(cap, tostring(i))
            Kit.probe(b, "variant " .. i)
        end
        for i = 1, 8 do make(i) end
        -- 9 and 10: a panel that should keep clicks on its empty part from the
        -- world while its child button still gets the mouse. 9 is Kit.blocker
        -- (a GLUEBUTTON, what the HUD uses), 10 a disabled TEXT frame. Click
        -- the child, then left- and right-click the empty right part: the
        -- hero must neither lose its selection nor move.
        for i = 9, 10 do
            local x = 0.02 + (i - 1) * 0.05 + (i - 9) * 0.035
            local panel
            if i == 9 then
                panel = Kit.blocker(root)
            else
                panel = BlzCreateFrameByType("TEXT", "", root, "", 0)
                BlzFrameSetEnable(panel, false)
                BlzFrameSetText(panel, "")
            end
            Kit.place(panel, x, 0.30, x + 0.075, 0.335)
            Kit.place(Kit.backdrop(panel, Kit.C.dark, 160), x, 0.30, x + 0.075, 0.335)
            local b = Kit.button(panel, Kit.btn("BTNHolyBolt"))
            Kit.place(b, x + 0.002, 0.302, x + 0.033, 0.333)
            local cap = Kit.text(root, 1.0)
            Kit.placeText(cap, x, 0.337, x + 0.075, 0.352)
            Kit.setText(cap, tostring(i))
            Kit.probe(b, "variant " .. i .. " child")
            if i == 9 then Kit.probe(panel, "variant 9 blocker", true) end
        end
        BlzFrameSetVisible(root, false)
    end

    ---------------------------------------------------------------- setters
    -- Cached so the update loop only calls natives when something changed.

    -- Rectangle in screen units (bottom-left x0/y0, top-right x1/y1).
    function Kit.place(f, x0, y0, x1, y1)
        if not f then return end
        BlzFrameClearAllPoints(f)
        BlzFrameSetAbsPoint(f, FRAMEPOINT_BOTTOMLEFT, x0, y0)
        BlzFrameSetAbsPoint(f, FRAMEPOINT_TOPRIGHT, x1, y1)
        if alphas[f] then BlzFrameSetAlpha(f, alphas[f]) end
    end

    function Kit.placeText(tx, x0, y0, x1, y1)
        Kit.place(tx.box, x0, y0, x1, y1)
    end

    function Kit.setText(tx, s)
        local f = tx.t or tx
        if texts[f] ~= s then
            texts[f] = s
            BlzFrameSetText(f, s)
        end
    end

    function Kit.show(f, on)
        if not f then return end
        on = on and true or false
        if shown[f] ~= on then
            shown[f] = on
            BlzFrameSetVisible(f, on)
        end
    end

    -- Forget the cached visibility (the game may have shown or hidden it).
    function Kit.forget(f) shown[f] = nil end

    -- An empty path is ignored: the frame keeps its last texture.
    function Kit.setTex(f, path)
        if f and path and path ~= "" and texs[f] ~= path then
            texs[f] = path
            BlzFrameSetTexture(f, path, 0, true)
        end
    end

    function Kit.setValue(bar, v)
        v = math.floor(math.max(0, math.min(1, v)) * 1000 + 0.5) / 1000
        if vals[bar] ~= v then
            vals[bar] = v
            BlzFrameSetValue(bar, v)
        end
    end

    function Kit.setAlpha(f, a)
        if f and alphas[f] ~= a then
            alphas[f] = a
            BlzFrameSetAlpha(f, a)
        end
    end

    ---------------------------------------------------------------- screen

    -- Left and right screen edges in frame units: 0 and 0.8 at 4:3, wider
    -- screens extend past them (16:9: -0.133 .. 0.933). Local value.
    function Kit.edges()
        local w, h = BlzGetLocalClientWidth(), BlzGetLocalClientHeight()
        if not w or not h or w <= 0 or h <= 0 then return 0.0, 0.8 end
        local width = 0.6 * w / h
        if width < 0.8 then width = 0.8 end
        return 0.4 - width / 2, 0.4 + width / 2
    end

    ---------------------------------------------------------------- strings

    function Kit.int(v) return tostring(math.floor((v or 0) + 0.5)) end

    function Kit.clock(seconds)
        seconds = math.max(0, math.floor(seconds or 0))
        return string.format("%d:%02d", seconds // 60, seconds % 60)
    end

    function Kit.color(hex, s) return "|cff" .. hex .. s .. "|r" end

    return Kit
end)
