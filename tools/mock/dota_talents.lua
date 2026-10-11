-- Offline exercise for the talent tree and Aghanim's sign (src/ui/dota_talents.lua)
-- on the HUD mock's frame model (tools/mock/dota_hud.lua), after the HUD
-- exercise: placement around the ability row, the glow, picking through a
-- pinned tree (the clicking player's hero only), the hover preview, the
-- Attribute Bonus row, the Aghanim's tooltip, the row growing by a granted
-- ability, and that local updates create no handles.
if not __mockDotaTalents then
    __mockDotaTalents = true

    local function exercise()
        local M = __mockHud
        if not M or not use("dota_hud").started then
            use("log").warn("dota_talents exercise: no HUD mock, skipped")
            return
        end
        local Log = use("log")
        local failures, checks = 0, 0
        local function check(name, ok, detail)
            checks = checks + 1
            if not ok then
                failures = failures + 1
                Log.error("dota_talents exercise: " .. name .. (detail ~= nil and (" - " .. tostring(detail)) or ""))
            end
        end
        local Kit, Hud, H = use("hud_kit"), use("dota_hud"), use("heroes")
        local T, DT = use("talents"), use("dota_talents")
        if not T.started then T.init() end
        if not DT.started then DT.init() end
        local F, V = DT.F, DT.V
        local p0, p1 = Player(0), Player(1)
        local hero, other = H.bySlot[0], H.bySlot[1]
        local key = H.keyOf[hero]
        check("hero to show", hero ~= nil and key ~= nil)
        if not hero then return end
        T.register(hero)
        if other then T.register(other) end
        M.selection = {hero}
        hero.level = 1
        Hud.tick()
        DT.update()

        -- around the ability row
        check("tree shown", M.shown(F.tree))
        check("aghanim's sign shown", M.shown(F.scepter) and M.shown(F.shard))
        local first = Hud.S.rects[1]
        local last = Hud.S.rects[#Hud.S.rects]
        local tx = M.at(F.tree)
        local ax = M.at(F.scepter)
        check("tree left of the row", tx and first and tx + Hud.L.TREE_W <= first[1] + 1e-6, tostring(tx))
        check("sign right of the row", ax and last and ax >= last[3] - 1e-6, tostring(ax))
        check("sign inside the ability area", ax and ax + Hud.L.AGHS_W <= Hud.G.abilR + 1e-6)
        for _, f in ipairs({F.tree, F.scepter, F.shard, F.panel}) do
            check("under the bottom blocker", M.under(Kit.hit(f), Hud.F.fgBottom))
        end
        check("no glow before level 10", not M.shown(F.glow) and not M.shown(F.rim))
        check("panel closed", not M.shown(F.panel))

        -- level 10: the tree glows; the hover preview shows it
        hero.level = 10
        DT.update()
        check("glow at level 10", M.shown(F.rim) or M.shown(F.glow))
        M.hover = F.tree
        DT.update()
        check("hover shows the tree", M.shown(F.panel))
        M.hover = nil
        DT.update()
        check("leaving hides it", not M.shown(F.panel))

        -- local updates create no handles
        local h0 = M.handles
        for _ = 1, 5 do DT.update() end
        check("no handles in local code", M.handles == h0, M.handles - h0)

        -- a click pins the tree; a choice picks for the clicker's hero
        M.click(F.tree, p0)
        check("click pins the tree", V.pinned and M.shown(F.panel))
        local right = DT.talentAt(key, 1, "right")
        local left = DT.talentAt(key, 1, "left")
        check("tier 1 listed", right ~= nil and left ~= nil)
        check("row text is the label", F.rows[1].right.text.t.text ~= "" and
            string.find(F.rows[1].right.text.t.text, right.label, 1, true) ~= nil)
        check("upper tiers locked", F.rows[2].left.text.t.text ~= "" and F.rows[2].right.b.visible ~= false)
        M.click(F.rows[1].right.b, p1)
        check("another player's click picks nothing here", not T.picked(hero, right.name))
        M.click(F.rows[1].right.b, p0)
        check("click picks the talent", T.picked(hero, right.name))
        check("the other one locks", not T.canPick(hero, left.name))
        DT.update()
        check("tree closes after the last pick", not V.pinned and not M.shown(F.panel))
        check("branch lit", M.shown(F.marks[1].right) and not M.shown(F.marks[1].left))
        check("glow left only for the Attribute Bonus",
            (M.shown(F.rim) or M.shown(F.glow)) == T.canLevelAttr(hero), tostring(T.canLevelAttr(hero)))

        -- Attribute Bonus row
        M.click(F.tree, p0)
        DT.update()
        check("attribute row shown", M.shown(F.attr) and string.find(F.attrText.t.text, "Attribute Bonus", 1, true))
        M.click(F.tree, p0)
        check("second click closes", not V.pinned)

        -- Aghanim's tooltip
        M.hover = F.scepter
        DT.update()
        check("scepter hover shows the upgrades", M.shown(F.tip)
            and string.find(F.tipText.t.text, "Aghanim's Scepter", 1, true) ~= nil)
        M.hover = nil
        DT.update()
        check("tooltip hides", not M.shown(F.tip))

        -- a granted ability joins the row once the hero has it
        local n0 = Hud.S.n
        local grants = 0
        for _, ab in ipairs(use("data.heroes")[key].abilities) do
            if ab.IsGrantedByShard == "1" and use("abilities").id(ab.name) then grants = grants + 1 end
        end
        T.consumeShard(hero)
        Hud.tick()
        check("shard ability joins the row", Hud.S.n == n0 + grants, n0 .. " -> " .. Hud.S.n)
        DT.update()
        check("shard lit", not Kit.dota and F.shardImg.alpha == 255 or Kit.dota)

        -- another selection: nothing to show
        M.selection = {}
        local was = H.bySlot[0]
        H.bySlot[0] = nil
        Hud.tick()
        DT.update()
        check("hidden without a hero", not M.shown(F.tree) and not M.shown(F.scepter))
        H.bySlot[0] = was
        M.selection = {hero}
        -- later exercises use slot 0's hero type for their own units
        T.forget(hero)
        hero.level = 1
        Hud.tick()
        DT.update()
        check("forgotten", not T.picked(hero, right.name) and not T.hasShard(hero))
        Log.info("dota_talents exercise: " .. checks .. " checks, " .. failures .. " failed")
    end

    local prev = __mock.advance
    local done = false
    function __mock.advance(seconds)
        prev(seconds)
        if done or not defined("dota_talents") then return end
        done = true
        use("safe").call(exercise)
        use("log").flush()
    end
end
