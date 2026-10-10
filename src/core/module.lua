-- Tiny module system. All source files are concatenated into war3map.lua, so
-- each module registers a factory with define() and modules resolve each other
-- lazily with use(). Load order of files therefore does not matter.
do
    local factories, cache = {}, {}

    function define(name, factory)
        factories[name] = factory
    end

    function defined(name)
        return factories[name] ~= nil
    end

    function use(name)
        local m = cache[name]
        if m == nil then
            local f = factories[name]
            if not f then
                error("unknown module " .. tostring(name), 2)
            end
            m = f()
            cache[name] = m
        end
        return m
    end
end
