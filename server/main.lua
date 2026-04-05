lib.versionCheck('Qbox-project/qbx_helicam')

local lastDirUpdate = {} -- [src] = gameTimer ms

local function isPilotOrCopilot(src, veh)
    if not src or src <= 0 then return false end
    if not veh or veh == 0 or not DoesEntityExist(veh) then return false end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return false end

    -- must be in this exact vehicle
    if GetVehiclePedIsIn(ped, false) ~= veh then return false end

    -- seat -1 = pilot, seat 0 = copilot
    if GetPedInVehicleSeat(veh, -1) == ped then return true end
    if GetPedInVehicleSeat(veh, 0) == ped then return true end

    return false
end

RegisterNetEvent('qbx_helicam:server:toggleSpotlightState', function(netId)
    local src = source
    if type(netId) ~= 'number' then return end

    local vehicle = NetworkGetEntityFromNetworkId(netId)
    if not DoesEntityExist(vehicle) or GetVehicleType(vehicle) ~= 'heli' then return end

    -- ONLY pilot/copilot can toggle
    if not isPilotOrCopilot(src, vehicle) then return end

    local spotlightStatus = Entity(vehicle).state.spotlight
    Entity(vehicle).state:set('spotlight', not spotlightStatus, true)
end)

RegisterNetEvent('qbx_helicam:server:updateSpotlightDir', function(netId, dir)
    local src = source

    -- rate limit (~13 updates/sec)
    local now = GetGameTimer()
    if lastDirUpdate[src] and (now - lastDirUpdate[src]) < 75 then return end
    lastDirUpdate[src] = now

    if type(netId) ~= 'number' or type(dir) ~= 'table' then return end
    if type(dir.x) ~= 'number' or type(dir.y) ~= 'number' or type(dir.z) ~= 'number' then return end

    local veh = NetworkGetEntityFromNetworkId(netId)
    if veh == 0 or not DoesEntityExist(veh) then return end
    if GetVehicleType(veh) ~= 'heli' then return end

    -- ONLY pilot/copilot can update direction
    if not isPilotOrCopilot(src, veh) then return end

    -- optional: only update if spotlight is on
    if not Entity(veh).state.spotlight then return end

    Entity(veh).state:set('spotlightDir', { x = dir.x, y = dir.y, z = dir.z }, true)
end)

AddEventHandler('playerDropped', function()
    lastDirUpdate[source] = nil
end)