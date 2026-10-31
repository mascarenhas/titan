-- Each spec file owns the contexts it constructs. Register the returned close
-- function with that file's after_each hook; loaders only borrow contexts.
return function(driver)
    local contexts = {}
    local function new_context(options)
        local context = driver.new_resolver_context(options)
        contexts[#contexts + 1] = context
        return context
    end
    local function close_contexts()
        local owned, first_error = contexts
        contexts = {}
        for index = #owned, 1, -1 do
            local called, closed, close_error = pcall(driver.close_resolver_context, owned[index])
            if not called then
                if first_error == nil then first_error = closed end
            elseif not closed and first_error == nil then
                first_error = close_error or "cannot close test resolver context"
            end
        end
        if first_error ~= nil then error(first_error, 0) end
    end
    local function resolver_options(options)
        options = options or {}
        if options.context == nil then options.context = new_context(options) end
        return options
    end
    return new_context, close_contexts, resolver_options
end
