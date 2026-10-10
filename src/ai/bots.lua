-- Hero bots. Hero modules describe how a bot should use each ability with
-- Bots.hint(abilityName, spec); the bot driver reads these hints.
-- spec fields:
--   target  "enemyHero" | "enemy" | "ally" | "allyHero" | "self" | "point" | "none"
--   range   max cast distance (defaults to the ability's cast range)
--   radius  for "none"/"self": cast when this many enemies are within radius
--   minEnemies  how many enemies must be in radius (default 1)
--   hpBelow  only when the caster's HP fraction is below this
--   targetHpBelow  only when the target's HP fraction is below this
--   ultimate  true: save for heroes, never waste on creeps
--   toggle   true: an on/off ability (bot turns it on near enemies)
define("bots", function()
    local B = {hints = {}}

    function B.hint(abilityName, spec)
        B.hints[abilityName] = spec
    end

    return B
end)
