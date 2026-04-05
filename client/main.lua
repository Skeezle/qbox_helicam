local config = require 'config.client'

local FOV_MAX = 80.0
local FOV_MIN = 10.0
local ZOOM_SPEED = 2.0
local LR_SPEED = 3.0
local UD_SPEED = 3.0

local toggleHeliCam = 51   -- E (INPUT_CONTEXT)
local toggleVision = 25    -- RMB (INPUT_AIM)
local toggleLockOn = 22    -- Space (INPUT_SPRINT)

local heliCam = false
local fov = (FOV_MAX + FOV_MIN) * 0.5

---@enum
local VISION_STATE = {
    normal = 0,
    nightmode = 1,
    thermal = 2,
}

local visionState = VISION_STATE.normal
local scanValue = 0

---@enum
local VEHICLE_LOCK_STATE = {
    dormant = 0,
    scanning = 1,
    locked = 2,
}

local vehicleLockState = VEHICLE_LOCK_STATE.dormant
local vehicleDetected = nil
local lockedOnVehicle = nil

-- current helicam handle so spotlight can follow camera aim
local activeHeliCamHandle = nil

-- spotlight sync state (from statebag)
local spotlightStates = {}
local spotlightDirByNet = {} -- [netId] = {x,y,z}

-- spotlight tuning (you can tweak)
local SPOTLIGHT = {
    enabled = true,             -- master switch for custom spotlight drawing
    distance = 180.0,           -- beam length
    brightness = 12.0,          -- intensity
    roundness = 4.0,            -- beam softness
    radius = 30.0,              -- beam radius
    fadeout = 25.0,             -- beam fade
    offset = vector3(0.0, 2.2, -0.8), -- local offset from heli center (front-ish / under nose)
}

local function isHeliHighEnough(heli)
    return heli and heli ~= 0 and GetEntityHeightAboveGround(heli) > 1.5
end

local function changeVision()
    PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', false)

    if visionState == VISION_STATE.normal then
        SetNightvision(true)
    elseif visionState == VISION_STATE.nightmode then
        SetNightvision(false)
        SetSeethrough(true)
    elseif visionState == VISION_STATE.thermal then
        SetSeethrough(false)
    else
        error('Unexpected visionState ' .. json.encode(visionState))
    end

    visionState = (visionState + 1) % 3
end

local function resetVision()
    visionState = VISION_STATE.normal
    SetNightvision(false)
    SetSeethrough(false)
end

local function hideHudThisFrame()
    HideHelpTextThisFrame()
    HideHudAndRadarThisFrame()

    local hudComponents = {1, 2, 3, 4, 13, 11, 12, 15, 18, 19}
    for _, component in ipairs(hudComponents) do
        HideHudComponentThisFrame(component)
    end
end

local function checkInputRotation(cam, zoomValue)
    local rightAxisX = GetDisabledControlNormal(0, 220) -- mouse x
    local rightAxisY = GetDisabledControlNormal(0, 221) -- mouse y
    local rotation = GetCamRot(cam, 2)

    if rightAxisX == 0.0 and rightAxisY == 0.0 then return end

    local zoomFactor = zoomValue + 0.1
    local newZ = rotation.z - rightAxisX * UD_SPEED * zoomFactor
    local newY = rightAxisY * -1.0 * LR_SPEED * zoomFactor
    local newX = math.max(math.min(20.0, rotation.x + newY), -89.5)

    SetCamRot(cam, newX, 0.0, newZ, 2)
end

local function handleZoom(cam)
    if IsControlJustPressed(0, 241) then -- scroll up
        fov = math.max(fov - ZOOM_SPEED, FOV_MIN)
    end

    if IsControlJustPressed(0, 242) then -- scroll down
        fov = math.min(fov + ZOOM_SPEED, FOV_MAX)
    end

    local currentFov = GetCamFov(cam)
    if math.abs(fov - currentFov) < 0.1 then
        fov = currentFov
    end

    SetCamFov(cam, currentFov + (fov - currentFov) * 0.05)
end

local function rotAnglesToVec(rot)
    local z = math.rad(rot.z)
    local x = math.rad(rot.x)
    local num = math.abs(math.cos(x))
    return vector3(-math.sin(z) * num, math.cos(z) * num, math.sin(x))
end

local function getVehicleInView(cam)
    if not cam or not DoesCamExist(cam) then return nil end

    local camCoords = GetCamCoord(cam)
    local camRot = GetCamRot(cam, 2)
    local forwardVector = rotAnglesToVec(camRot)
    local targetCoords = camCoords + (forwardVector * 400.0)

    -- Use shape test (more reliable than GetRaycastResult pairing)
    local rayHandle = StartShapeTestRay(
        camCoords.x, camCoords.y, camCoords.z,
        targetCoords.x, targetCoords.y, targetCoords.z,
        10, -- intersect vehicles
        cache.vehicle or 0,
        0
    )

    local _, hit, _, _, entityHit = GetShapeTestResult(rayHandle)

    if hit ~= 1 then return nil end
    if not entityHit or entityHit == 0 then return nil end
    if not DoesEntityExist(entityHit) then return nil end

    -- Entity type 2 = vehicle (avoids IsEntityAVehicle native completely)
    if GetEntityType(entityHit) ~= 2 then return nil end

    return entityHit
end

local function renderVehicleInfo(vehicle)
    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) then return end

    local pos = GetEntityCoords(vehicle)
    local model = GetEntityModel(vehicle)
    local vehName = GetLabelText(GetDisplayNameFromVehicleModel(model))
    local licensePlate = qbx.getVehiclePlate(vehicle)
    local speed = math.ceil(GetEntitySpeed(vehicle) * 3.6)
    local street1, street2 = GetStreetNameAtCoord(pos.x, pos.y, pos.z)
    local streetLabel = GetStreetNameFromHashKey(street1)

    if street2 ~= 0 then
        streetLabel = streetLabel .. ' | ' .. GetStreetNameFromHashKey(street2)
    end

    SendNUIMessage({
        type = 'heliupdateinfo',
        model = vehName,
        plate = licensePlate,
        speed = speed,
        street = streetLabel,
    })
end

local function heliCamThread()
    CreateThread(function()
        while heliCam do
            local sleep = 0

            if vehicleLockState == VEHICLE_LOCK_STATE.scanning then
                if scanValue < 100 then
                    scanValue += 1
                    SendNUIMessage({
                        type = 'heliscan',
                        scanvalue = scanValue,
                    })

                    if scanValue == 100 then
                        PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', false)
                        lockedOnVehicle = vehicleDetected
                        vehicleLockState = VEHICLE_LOCK_STATE.locked
                    end

                    sleep = 10
                end
            elseif vehicleLockState == VEHICLE_LOCK_STATE.locked then
                scanValue = 100
                renderVehicleInfo(lockedOnVehicle)
                sleep = 100
            else
                scanValue = 0
                sleep = 500
            end

            Wait(sleep)
        end
    end)
end

local function unlockCam(cam)
    PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', false)

    lockedOnVehicle = nil
    local rot = GetCamRot(cam, 2)
    fov = GetCamFov(cam)

    DestroyCam(cam, false)

    local newCam = CreateCam('DEFAULT_SCRIPTED_FLY_CAMERA', true)
    AttachCamToEntity(newCam, cache.vehicle, 0.0, 0.0, -1.5, true)
    SetCamRot(newCam, rot.x, rot.y, rot.z, 2)
    SetCamFov(newCam, fov)
    RenderScriptCams(true, false, 0, true, false)

    activeHeliCamHandle = newCam
    vehicleLockState = VEHICLE_LOCK_STATE.dormant
    scanValue = 0

    SendNUIMessage({ type = 'disablescan' })

    return newCam
end

local function turnOffCam()
    PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', false)

    heliCam = false
    vehicleLockState = VEHICLE_LOCK_STATE.dormant
    scanValue = 0

    SendNUIMessage({ type = 'disablescan' })
    SendNUIMessage({ type = 'heliclose' })
end

-- ===== Custom spotlight helpers =====

local function getEntityForwardVector(entity)
    local rot = GetEntityRotation(entity, 2)
    return rotAnglesToVec(rot)
end

local function getSpotlightOrigin(veh)
    return GetOffsetFromEntityInWorldCoords(
        veh,
        SPOTLIGHT.offset.x,
        SPOTLIGHT.offset.y,
        SPOTLIGHT.offset.z
    )
end

local function getSpotlightDirectionForVehicle(veh)
    -- If local player is using helicam in this same vehicle, follow camera aim
    if heliCam and activeHeliCamHandle and DoesCamExist(activeHeliCamHandle) and cache.vehicle == veh then
        local camRot = GetCamRot(activeHeliCamHandle, 2)
        return rotAnglesToVec(camRot)
    end

    -- fallback: heli forward vector
    return getEntityForwardVector(veh)
end

local function drawVehicleSpotlight(netId, veh)
    if not SPOTLIGHT.enabled then return end
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end

    local origin = getSpotlightOrigin(veh)

    local dir

    -- ✅ If THIS client is in THIS heli and helicam is open, aim instantly from local cam
    if cache.vehicle == veh and heliCam and activeHeliCamHandle and DoesCamExist(activeHeliCamHandle) then
        dir = rotAnglesToVec(GetCamRot(activeHeliCamHandle, 2))
    else
        -- ✅ Everyone else (and you when not in helicam) uses the synced direction
        local dirTbl = spotlightDirByNet[netId]
        if dirTbl then
            dir = vector3(dirTbl.x, dirTbl.y, dirTbl.z)
        else
            -- fallback
            dir = getEntityForwardVector(veh)
        end
    end

    DrawSpotLight(
        origin.x, origin.y, origin.z,
        dir.x, dir.y, dir.z,
        255, 255, 255,
        SPOTLIGHT.distance,
        SPOTLIGHT.brightness,
        SPOTLIGHT.roundness,
        SPOTLIGHT.radius,
        SPOTLIGHT.fadeout
    )
end

CreateThread(function()
    while true do
        local sleep = 500

        for netId, enabled in pairs(spotlightStates) do
            if enabled then
                local veh = NetworkGetEntityFromNetworkId(netId)
                if veh and veh ~= 0 and DoesEntityExist(veh) then
                    drawVehicleSpotlight(netId, veh)
                    sleep = 0
                end
            end
        end

        Wait(sleep)
    end
end)

-- ===== Main helicam handling =====

local function handleInVehicle()
    if not LocalPlayer.state.isLoggedIn then return end
    if not heliCam then return end
    if not cache.vehicle or cache.vehicle == 0 then return end

    SetTimecycleModifier('heliGunCam')
    SetTimecycleModifierStrength(0.3)

    local scaleform = lib.requestScaleformMovie('HELI_CAM')
    local cam = CreateCam('DEFAULT_SCRIPTED_FLY_CAMERA', true)
    activeHeliCamHandle = cam

    AttachCamToEntity(cam, cache.vehicle, 0.0, 0.0, -1.5, true)
    SetCamRot(cam, 0.0, 0.0, GetEntityHeading(cache.vehicle), 2)
    SetCamFov(cam, fov)
    RenderScriptCams(true, false, 0, true, false)

    PushScaleformMovieFunction(scaleform, 'SET_CAM_LOGO')
    PushScaleformMovieFunctionParameterInt(0)
    PopScaleformMovieFunctionVoid()

    lockedOnVehicle = nil

    while heliCam and not IsEntityDead(cache.ped) and cache.vehicle and isHeliHighEnough(cache.vehicle) do
        DisableControlAction(0, toggleVision, true)
        DisableControlAction(0, toggleLockOn, true)
        DisableControlAction(0, toggleHeliCam, true)

        if IsDisabledControlJustPressed(0, toggleHeliCam) then
            turnOffCam()
            break
        end

        -- FIX: use disabled control check so RMB works during scripted cam
        if IsDisabledControlJustPressed(0, toggleVision) then
            changeVision()
        end

        local zoomValue = 0.0

        if lockedOnVehicle then
            if DoesEntityExist(lockedOnVehicle) then
                PointCamAtEntity(cam, lockedOnVehicle, 0.0, 0.0, 0.0, true)

                -- FIX: use disabled control check so space works while cam is active
                if IsDisabledControlJustPressed(0, toggleLockOn) then
                    cam = unlockCam(cam)
                    activeHeliCamHandle = cam
                end
            else
                vehicleLockState = VEHICLE_LOCK_STATE.dormant
                SendNUIMessage({ type = 'disablescan' })
                lockedOnVehicle = nil
            end
        else
            zoomValue = (1.0 / (FOV_MAX - FOV_MIN)) * (fov - FOV_MIN)

            checkInputRotation(cam, zoomValue)

        local ok, hitVeh = pcall(getVehicleInView, cam)
        if not ok then
            turnOffCam()
            break
        end

        vehicleDetected = hitVeh
            vehicleLockState = (vehicleDetected and DoesEntityExist(vehicleDetected))
                and VEHICLE_LOCK_STATE.scanning
                or VEHICLE_LOCK_STATE.dormant

            -- Optional: lock-on from free cam too
            if vehicleDetected and IsDisabledControlJustPressed(0, toggleLockOn) then
                -- start scan lock flow (keeps your original scanning behavior)
                -- no action needed here beyond allowing scan state to progress
            end
        end

        handleZoom(cam)
        hideHudThisFrame()

        PushScaleformMovieFunction(scaleform, 'SET_ALT_FOV_HEADING')
        PushScaleformMovieFunctionParameterFloat(GetEntityCoords(cache.vehicle).z)
        PushScaleformMovieFunctionParameterFloat(zoomValue)
        PushScaleformMovieFunctionParameterFloat(GetCamRot(cam, 2).z)
        PopScaleformMovieFunctionVoid()

        DrawScaleformMovieFullscreen(scaleform, 255, 255, 255, 255, 0)

        Wait(0)
    end

    heliCam = false
    activeHeliCamHandle = nil
    ClearTimecycleModifier()

    fov = (FOV_MAX + FOV_MIN) * 0.5
    RenderScriptCams(false, false, 0, true, false)

    SetScaleformMovieAsNoLongerNeeded(scaleform)

    if DoesCamExist(cam) then
        DestroyCam(cam, false)
    end

    resetVision()
end

local camera = lib.addKeybind({
    name = 'qbx_helicam_camera',
    description = locale('camera_keybind'),
    defaultKey = 'E',
    disabled = true,
    onPressed = function()
        if not cache.vehicle or cache.vehicle == 0 then return end
        if not isHeliHighEnough(cache.vehicle) then return end

        PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', false)

        heliCam = true
        heliCamThread()

        SendNUIMessage({ type = 'heliopen' })
    end
})

local spotlight = lib.addKeybind({
    name = 'qbx_helicam_spotlight',
    description = locale('spotlight_keybind'),
    defaultKey = 'H',
    disabled = true,
    onPressed = function()
        if not cache.vehicle or cache.vehicle == 0 then return end

        PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', false)

        local netId = NetworkGetNetworkIdFromEntity(cache.vehicle)
        TriggerServerEvent('qbx_helicam:server:toggleSpotlightState', netId)
    end,
})

local rappel = lib.addKeybind({
    name = 'qbx_helicam_rappel',
    description = locale('rappel_keybind'),
    defaultKey = 'X',
    disabled = true,
    onPressed = function()
        if not cache.vehicle or cache.vehicle == 0 then return end

        PlaySoundFrontend(-1, 'SELECT', 'HUD_FRONTEND_DEFAULT_SOUNDSET', false)
        TaskRappelFromHeli(cache.ped, 1)
    end
})

-- Read spotlight state from server statebag
---@diagnostic disable-next-line: param-type-mismatch
AddStateBagChangeHandler('spotlight', nil, function(bagName, _, value)
    local entity = GetEntityFromStateBagName(bagName)
    if not entity or entity == 0 then return end

    local netId = NetworkGetNetworkIdFromEntity(entity)
    spotlightStates[netId] = value == true
    if value ~= true then
        spotlightDirByNet[netId] = nil
    end

    -- Disable vanilla searchlight so it doesn't conflict with custom aimable spotlight
    -- (If you prefer vanilla toggle instead, set this to `value`)
    SetVehicleSearchlight(entity, false, false)
end)

---@diagnostic disable-next-line: param-type-mismatch
AddStateBagChangeHandler('spotlightDir', nil, function(bagName, _, value)
    local entity = GetEntityFromStateBagName(bagName)
    if not entity or entity == 0 then return end
    if type(value) ~= 'table' then return end
    if type(value.x) ~= 'number' or type(value.y) ~= 'number' or type(value.z) ~= 'number' then return end

    local netId = NetworkGetNetworkIdFromEntity(entity)
    spotlightDirByNet[netId] = value
end)

lib.onCache('seat', function(seat)
    if seat == nil then
        camera:disable(true)
        spotlight:disable(true)
        rappel:disable(true)
        return
    end

    if not cache.vehicle or cache.vehicle == 0 then
        camera:disable(true)
        spotlight:disable(true)
        rappel:disable(true)
        return
    end

    local model = GetEntityModel(cache.vehicle)

    if not config.authorizedHelicopters[model] then
        camera:disable(true)
        spotlight:disable(true)
        rappel:disable(true)
        return
    end

    if seat == -1 or seat == 0 then
        rappel:disable(true)

        -- enable spotlight key regardless of vanilla light presence because custom spotlight is client-drawn
        spotlight:disable(false)
        camera:disable(false)
    elseif seat >= 1 then
        camera:disable(true)
        spotlight:disable(true)

        if DoesVehicleAllowRappel(cache.vehicle) then
            rappel:disable(false)
        else
            rappel:disable(true)
        end
    end

    CreateThread(function()
        while cache.vehicle do
            handleInVehicle()
            Wait(0)
        end
    end)
end)

local lastSend = 0

local function sendSpotlightDir(netId, dir)
    local now = GetGameTimer()
    if now - lastSend < 75 then return end -- ~13 updates/sec
    lastSend = now
    TriggerServerEvent('qbx_helicam:server:updateSpotlightDir', netId, { x = dir.x, y = dir.y, z = dir.z })
end

CreateThread(function()
    while true do
        Wait(0)

        if not cache.vehicle or cache.vehicle == 0 then goto continue end
        if GetVehicleType(cache.vehicle) ~= 'heli' then goto continue end

        -- only pilot/copilot should broadcast direction
        local seat = cache.seat
        if seat ~= -1 and seat ~= 0 then goto continue end

        local netId = NetworkGetNetworkIdFromEntity(cache.vehicle)

        -- only broadcast if spotlight is actually on (statebag replicated)
        if spotlightStates[netId] ~= true then goto continue end

        -- direction source:
        -- if helicam is open, follow camera aim; otherwise follow heli heading
        local dir
        if heliCam and activeHeliCamHandle and DoesCamExist(activeHeliCamHandle) then
            dir = rotAnglesToVec(GetCamRot(activeHeliCamHandle, 2))
        else
            dir = rotAnglesToVec(GetEntityRotation(cache.vehicle, 2))
        end

        sendSpotlightDir(netId, dir)

        ::continue::
    end
end)