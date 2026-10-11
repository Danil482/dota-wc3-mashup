-- Dota spell effects converted by the launcher from the player's own Dota 2
-- install (specs/effects.json, launcher/dvw_launcher/effects.py). data.effects
-- maps an effect key to its model in a personalized map and is empty in the
-- base map, so each caller passes its WC3 fallback:
--   local FX = {void = Fx.model("antimage_mana_void", "Abilities\\...\\ManaFlareBoltImpact.mdl")}
-- An effect the launcher could not convert is simply not listed, and the
-- fallback shows. Attack projectiles are object data instead (ua1m, set by
-- tools/gen_objects.py in release and --dota-models builds).
-- No init line: modules use("fx").
define("fx", function()
    local Fx = {}
    local models = nil

    function Fx.model(key, fallback)
        models = models or use("data.effects")
        return models[key] or fallback
    end

    return Fx
end)
