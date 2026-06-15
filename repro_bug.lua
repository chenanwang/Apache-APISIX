-- /opt/data/bounty_hunter/Apache-APISIX/repro_bug.lua
-- 模擬 APISIX K8s Discovery 解析邏輯

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

-- 模擬核心解析代碼
local function parse_endpoints(endpoint_slice)
    local port_to_nodes = {}
    local slice_endpoints = endpoint_slice.endpoints or {}

    for _, ep in ipairs(slice_endpoints) do
        -- 核心邏輯
        if ep.addresses and ep.conditions and ep.conditions.ready then
            local addresses = ep.addresses
            for _, port in ipairs(endpoint_slice.ports or {}) do
                local port_name = port.name or tostring(port.port)
                if not port_to_nodes[port_name] then port_to_nodes[port_name] = {} end
                for _, ip in ipairs(addresses) do
                    table.insert(port_to_nodes[port_name], {
                        host = ip,
                        port = port.port
                    })
                end
            end
        end
    end
    return port_to_nodes
end

-- 測試案例 1：正常狀態
local slice1 = {
    metadata = { name = "s1" },
    endpoints = {
        { addresses = {"10.0.0.1"}, conditions = { ready = true } },
        { addresses = {"10.0.0.2"}, conditions = { ready = true } }
    },
    ports = { { port = 80, name = "http" } }
}

print("Test 1: 2 ready pods")
local res1 = parse_endpoints(slice1)
print(inspect(res1))

-- 模擬快取架構
local handle = { endpoint_slices_cache = {} }

local function update_cache(endpoint_key, slice, slice_name)
    if not handle.endpoint_slices_cache[endpoint_key] then
        handle.endpoint_slices_cache[endpoint_key] = {}
    end
    handle.endpoint_slices_cache[endpoint_key][slice_name] = slice
end

local function get_all_nodes(endpoint_key)
    local slices = handle.endpoint_slices_cache[endpoint_key] or {}
    local nodes = {}
    for _, s in pairs(slices) do
        for port, targets in pairs(s) do
            if not nodes[port] then nodes[port] = {} end
            for _, t in ipairs(targets) do table.insert(nodes[port], t) end
        end
    end
    return nodes
end

print("\n--- Cache Integration Test ---")
update_cache("svc", res1, "s1")
print("Initial cache:", inspect(get_all_nodes("svc")))

-- 模擬 K8s MODIFIED 事件，將 Pod 2 設為 Ready=False
local slice2 = {
    metadata = { name = "s1" },
    endpoints = {
        { addresses = {"10.0.0.1"}, conditions = { ready = true } },
        { addresses = {"10.0.0.2"}, conditions = { ready = false } }
    },
    ports = { { port = 80, name = "http" } }
}
local res2 = parse_endpoints(slice2)
update_cache("svc", res2, "s1")
print("Updated cache (10.0.0.2 NOT READY):", inspect(get_all_nodes("svc")))

-- 問題假設：如果 Kubernetes 回傳的 EndpointSlice 是空的？
-- 比如該 slice 目前沒有任何 Pod（全都被刪除中）
local slice_empty = {
    metadata = { name = "s1" },
    endpoints = {}, -- 空陣列
    ports = { { port = 80, name = "http" } }
}
local res_empty = parse_endpoints(slice_empty)
print("\nEmpty Slice Result:", inspect(res_empty))
update_cache("svc", res_empty, "s1")
print("Updated cache (Empty Slice):", inspect(get_all_nodes("svc")))

-- 到此為止，邏輯似乎都是對的。
-- 但 issue 提到 Stale Upstream Nodes。
-- 只有一個可能：APISIX 的 `on_endpoint_slices_modified` 本身對於「更新失敗」的情況處理？
-- 或者，
-- 看看 core.lua 第 351 行：
-- local slice_endpoints = endpoint_slice.endpoints
-- if not slice_endpoints or slice_endpoints == ngx.null then
--     slice_endpoints = {}
-- end
--
-- 這裡！如果 `endpoint_slice.endpoints` 存在但為空，那麼後續的 `for _, ep in ipairs(slice_endpoints) do` 就不會執行。
-- `port_to_nodes` 保持為 `{}`。
-- 接著執行：
-- update_endpoint_slices_cache(handle, endpoint_key, port_to_nodes, endpoint_slice.metadata.name)
-- 這會將快取中的該項設為 `{}`。
-- 最終 `get_endpoints_from_cache` 算出空的。這也是對的。
--
-- 難道是 DELETED 事件？
-- on_endpoint_slices_deleted(handle, endpoint_slice)
-- 呼叫 update_endpoint_slices_cache(handle, endpoint_key, nil, endpoint_slice.metadata.name)
-- 這會把項設為 `nil`。也對。
--
-- 再看一次核心檢查點：
-- if ep.addresses and ep.conditions and ep.conditions.ready then
--
-- 如果 Kubernetes 回傳的節點，`ready` 是 false，但是 `serving` 是 true 呢？
-- 某些 LoadBalancer 會看 `serving`。但 APISIX 目前只看 `ready`。
-- 如果 `ready` 欄位遺失了呢？
-- 如果 pod 正在處於 Terminating 狀態，且 spec 裡沒有設定 `ready` 欄位？
-- K8s 的 API 中，ready 是「Required」。
-- 
-- 等等！
-- 觀察 `get_endpoints_from_cache` (302行):
-- local endpoints = {}
-- for _, endpoint_slice in pairs(endpoint_slices) do
--    for port, targets in pairs(endpoint_slice) do
--        if not endpoints[port] then
--            endpoints[port] = core.table.new(0, #targets)
--        end
--        core.table.insert_tail(endpoints[port], unpack(targets))
--    end
-- end
--
-- 這裡有一個細節：
-- 如果 `endpoint_slice` 物件在某次更新中變成了空表 `{}`。
-- 那麼內部的 `for port, targets in pairs(endpoint_slice) do` 就不會執行。
-- 這也沒錯。
--
-- 除非... 快取沒有被真的「蓋掉」？
-- 不會啊， Lua 的 table 賦值 `handle.endpoint_slices_cache[endpoint_key][slice_name] = slice`
-- 不管 slice 是 `{}` 還是 nil，都會把舊的值移除。
--
-- 等等！
-- 找到疑點了！
-- 在 `informer_factory.lua` 中，如果 APISIX 收到的 `MODIFIED` 事件中，
-- 根本沒有包含 `endpoints` 欄位（比如這是個 Metadata Only 的更新）？
-- 那麼 `on_endpoint_slices_modified` 會算出 `port_to_nodes = {}`。
-- 這會導致「誤刪除」快取中的所有節點！
--
-- 但是 issue 說的是「Stale Nodes」(沒刪掉)，而不是「誤刪」。
-- 
-- 讓我們來仔細研讀 `EndpointSlice` 的 K8s 官方行為。
-- 當 pod 從 Ready 變成 NotReady，K8s 會修改該 EndpointSlice 物件中該項目的 conditions.ready = false。
-- APISIX 的 `on_endpoint_slices_modified` 就會把該節點排除。
--
-- 假如 pod 被徹底刪除了呢？
-- 該 Pod 會從 `endpoints` 陣列中消失。
-- APISIX 同樣會算出一份不含該 pod 的 `port_to_nodes` 並蓋掉快取。
--
-- 唯一的「Stale」可能：
-- 如果 APISIX 對於 MODIFIED 事件的解析出現異常（Exception），導致代碼沒有執行到 `update_endpoint_slices_cache` 這一行。
-- 那麼舊的快取就會一直留在記憶體中！
-- 
-- 讓我們看 `on_endpoint_slices_modified` 的前幾行：
-- local ok, err = validate_endpoint_slice(endpoint_slice)
-- if not ok then
--     core.log.error("endpoint_slice validation fail: ", err)
--     return
-- end
--
-- 如果 `validate_endpoint_slice` 失敗，函數直接 return，舊快取不變！
-- 讓我們看 `validate_endpoint_slice` (314行)：
-- 檢查 metadata, name, namespace, labels 以及 kubernetes_service_name_label。
-- 只要這幾項都在，就不會失敗。
-- 
-- 再看一個地方：
-- 如果 pod 有多個地址（Dual Stack）？
-- `for _, ip in ipairs(addresses) do`
--
-- 讓我們思考 issue 的另一句話：
-- "reconcile MODIFIED or DELETED events for EndpointSlice resources"
-- 
-- 假如一個 Service 從有 EndpointSlice 變成「完全沒有任何 EndpointSlice」呢？
-- 此時 APISIX 會收到一個 `DELETED` 事件給最後一個 Slice。
-- `on_endpoint_slices_deleted` 會清除快取。
--
-- 但是，假如 K8s 只是移除了其中一個 slice，但那個 slice 名稱改了？
-- (EndpointSlice 名稱通常包含亂數後綴)。
-- 
-- 讓我們看看目前的解決方案建議：
-- 1. Correctly parse updates and remove endpoints no longer present. (目前似乎已做)
-- 2. Endpoints with conditions.ready = false must be filtered out. (目前似乎已做)
-- 3. Handle DELETED events. (目前似乎已做)
--
-- 既然目前代碼「看起來」都做了，為什麼還有 bug？
--
-- 或許問題在於 `MODIFIED` 事件中，APISIX 採用的「Incremental 更新」邏輯？
-- 讓我們看 `informer_factory.lua` 是不是用了 `on_add`, `on_update`, `on_delete`。
-- 
-- 啊！我有一個猜測：
-- 如果原本 APISIX 用的是 `Endpoints` 物件，現在切換到 `EndpointSlice`。
-- `Endpoints` 物件是「整全」的 (一次包含所有 pod)。
-- 而 `EndpointSlice` 是「分片」的。
-- 如果 APISIX 內部的 Discovery 邏輯中，某些地方還假設「一個 Service 只有一個資源物件」？
--
-- 讓我們來檢查 `core.lua` 中的 `endpoint_slices_cache` 結構。
-- `handle.endpoint_slices_cache[endpoint_key][slice_name]`
-- 這是一個 nested table，確實支援分片。
--
-- 那會不會是... `kubernetes_service_name_label` 變了？
-- 
-- 讓我們看 issue 的關鍵修正建議 3:
-- "Ensure that when a MODIFIED event is received, the local cache is fully synchronized (diffed or overwritten) with the new list of active endpoints, rather than appending or failing to prune stale entries."
-- 
-- 這暗示原本可能存在「Appending」而不是「Overwriting」的行為？
-- 觀察 393-394 行：
-- update_endpoint_slices_cache(handle, endpoint_key, port_to_nodes, endpoint_slice.metadata.name)
-- 這確實是用最新的 `port_to_nodes` (目前這個 slice 的狀態) 去覆蓋快取。
--
-- 等等！
-- 假如一個 Pod 在 `s1` 分片中，後來因為負載平衡被搬移到 `s2` 分片中。
-- APISIX 會收到兩次更新：
-- 1. `s1` 更新 (不再含該 Pod)。
-- 2. `s2` 更新 (含該 Pod)。
-- 
-- 如果 `s1` 的更新事件被遺漏，或解析出錯，
-- 快取中 `s1` 就會保留舊的 Pod，而 `s2` 又新增了 Pod。
--
-- 讓我們來看 `core.lua` 中有沒有沒考慮到的條件？
-- `if ep.addresses and ep.conditions and ep.conditions.ready then`
-- 
-- 萬一 `ep.conditions.ready` 為 `nil` 但是該 Pod 其實是 `Ready` 呢？
-- 在某些極早期 K8s 或特殊實作中，可能預設 Ready。
--
-- 或是：
-- 如果 Pod 正在 `Terminating`，但是 `ready` 為 `false` 且 `serving` 為 `true`。
-- 目前 APISIX 會把流量切斷。
--
-- 但 issue 的重點是「Stale Nodes」(該走的沒走)。
-- 這通常發生在 `MODIFIED` 之後，舊節點還在。
--
-- 重新檢視 `on_endpoint_slices_modified`:
-- 它每次都產生全新的 `port_to_nodes` 並呼叫 `update_endpoint_slices_cache`。
-- 除非 `on_endpoint_slices_modified` 的 input `endpoint_slice` 內容本身不包含最新的變動？
--
-- 讓我們看看 `on_endpoint_slices_deleted` (413行)：
-- 它呼叫 `update_endpoint_slices_cache(handle, endpoint_key, nil, endpoint_slice.metadata.name)`
-- 
-- 我們來檢查 `update_endpoint_slices_cache` (293行)：
-- ```lua
--    local function update_endpoint_slices_cache(handle, endpoint_key, slice, slice_name)
--        if not handle.endpoint_slices_cache[endpoint_key] then
--            handle.endpoint_slices_cache[endpoint_key] = {}
--        end
--        handle.endpoint_slices_cache[endpoint_key][slice_name] = slice
--    end
-- ```
--
-- 這裡！如果 `slice` 是 `nil`，它會執行 `handle.endpoint_slices_cache[endpoint_key][slice_name] = nil`。
-- 這在 Lua 中確實會刪除該 key。
--
-- 那麼...
-- 會不會是 `MODIFIED` 事件觸發時，`operate` 變數的處理？
--
-- 讓我們看 issue 的「Filtering Logic」建議：
-- "In /apisix/discovery/kubernetes/init.lua, ensure the parser checks conditions.ready. If ready is not true, the address must be excluded."
--
-- 目前 `core.lua` 確實做了檢查。
-- 可是...
-- 萬一 Pod 是「Terminating」但 `ready` 為 `false` 呢？
-- 如果用戶希望在這種情況下「不」轉發流量，原本代碼已經滿足。
-- 
-- 讓我們來找真正的 Bug。
-- 在 Apache APISIX 的歷史 PR 中，曾有過相關討論。
-- 關鍵點在於：`EndpointSlice` 中的 `addresses` 陣列可能含有多個 IP。
--
-- 還有另一個：
-- K8s 的 `EndpointSlice` 如果包含 `endpoints[i].conditions.ready = nil`。
-- 在 Lua 中 `nil` 即 `false`。
-- 這表示該 Pod 會被「排除」。
-- 
-- 讓我們看 `informer_factory.lua`。它是如何呼叫 `on_modified` 的。
