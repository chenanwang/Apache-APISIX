-- /opt/data/bounty_hunter/Apache-APISIX/repro_bug_v2.lua
local function inspect(o)
    if type(o) == 'table' then
       local s = '{ '
       for k,v in pairs(o) do
          if type(k) ~= 'number' then k = '"'..k..'"' end
          s = s .. '['..k..'] = ' .. inspect(v) .. ','
       end
       return s .. '} '
    else
       return tostring(o)
    end
end

-- 模擬 OpenResty/ngx.null
local ngx_null = "ngx.null (userdata)" 

local function parse_endpoints(endpoints)
    local ready_nodes = {}
    for _, ep in ipairs(endpoints) do
        -- 原始程式碼邏輯: if ep.conditions.ready then
        -- 在 Lua 中，除了 nil 和 false，其餘皆為 true。
        -- 如果 ep.conditions.ready 是 ngx.null，則條件成立！
        if ep.conditions and ep.conditions.ready then
            table.insert(ready_nodes, ep.address)
        end
    end
    return ready_nodes
end

local test_endpoints = {
    { address = "10.0.0.1", conditions = { ready = true } },
    { address = "10.0.0.2", conditions = { ready = false } },
    { address = "10.0.0.3", conditions = { ready = ngx_null } } -- 模擬 JSON null
}

print("Simulating Bug: ngx.null is truthy")
local result = parse_endpoints(test_endpoints)
print("Ready Nodes:", inspect(result))

-- 預期修復後的邏輯
local function parse_endpoints_fixed(endpoints)
    local ready_nodes = {}
    for _, ep in ipairs(endpoints) do
        -- 1. 明確檢查是否為 true (排除 ngx.null)
        -- 2. 增加 terminating 檢查 (K8s 建議)
        local c = ep.conditions
        if c and c.ready == true and not c.terminating then
            table.insert(ready_nodes, ep.address)
        end
    end
    return ready_nodes
end

local test_endpoints_v2 = {
    { address = "10.0.0.1", conditions = { ready = true, terminating = false } },
    { address = "10.0.0.3", conditions = { ready = true, terminating = true } }, -- Terminating
    { address = "10.0.0.4", conditions = { ready = ngx_null } }                  -- Null
}

print("\nFixed Logic Test:")
local result_fixed = parse_endpoints_fixed(test_endpoints_v2)
print("Ready Nodes (Fixed):", inspect(result_fixed))
