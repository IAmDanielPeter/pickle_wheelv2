-- Enhanced Pickle Wheel Manual Transmission System
-- Combines pickle_wheel's wheel/pedal support with proven gear shifting logic

-- Check if ox_lib is available
local libAvailable = lib ~= nil

-- ========== MANUAL TRANSMISSION SYSTEM ==========
local useDebug = false -- Set to true for debugging

local SETGEARNATIVE = GetHashKey('SET_VEHICLE_CURRENT_GEAR') & 0xFFFFFFFF

if GetGameBuildNumber() < 3095 then
    if useDebug then
        print('^1THIS SERVER GAME BUILD IS TOO LOW TO USE MANUAL GEARBOX!')
        print("Version:", GetGameBuildNumber())
        print("Least required version:", 3095)
    end
end

-- Gear system variables
local lowestGear = 0
local topGear = 5
local clutchUp = 1.0
local clutchDown = 1.0
local nextGear = 1
local isGearing = false
local lastRpmUpdate = 0

-- Engine damage system variables
local redlineRPM = 0.92 -- RPM threshold for engine damage (92% of max RPM)
local redlineTime = 0   -- Time spent at redline
local lastRedlineCheck = 0
local damageWarningShown = false
local isEngineWarningActive = false

-- ========== STALL SYSTEM VARIABLES ==========
local stallRPM = 0.15           -- RPM threshold below which engine stalls (15% of max RPM)
local stallTime = 0             -- Time spent below stall RPM
local stallGraceTime = 2000     -- Grace period in ms before stall occurs
local isStalled = false         -- Engine stall state
local stallWarningShown = false -- Prevent spam warnings
local lastStallCheck = 0        -- Last time we checked for stall
local stallCooldown = 0         -- Cooldown before next stall can occur
local stallCooldownTime = 5000  -- 5 second cooldown between stalls

-- Minimum RPM thresholds per gear (below these = instant stall)
local gearStallThresholds = {
    [1] = 0.10, -- 1st gear: 10% RPM minimum
    [2] = 0.15, -- 2nd gear: 15% RPM minimum
    [3] = 0.20, -- 3rd gear: 20% RPM minimum
    [4] = 0.25, -- 4th gear: 25% RPM minimum
    [5] = 0.30, -- 5th gear: 30% RPM minimum
    [6] = 0.35, -- 6th gear: 35% RPM minimum
}

-- Manual transmission flags
local MANUAL_FLAG = 1024
local LATE_GEAR_FLAG = 2710

-- Animation dictionaries for gear shifting
local LanimationDict = "veh@driveby@first_person@passenger_rear_right_handed@smg"
local LanimationName = "outro_90r"
local RanimationDict = "veh@driveby@first_person@passenger_rear_left_handed@smg"
local RanimationName = "outro_90l"
local isEnteringVehicle = false

-- Config
local Config = {
    Debug = false,
    OxLib = true,
    NotifyManual = true,
    ManualNotificationText = 'This vehicle is a manual',
    UseServerSideStateSet = true,
    GearCheckSleep = 1000,
    ClutchTime = 300,
    Keys = {
        gearUp = 'EQUALS',
        gearDown = 'MINUS'
    }
}

-- RHD cars list (can be expanded)
local rhdCars = {}
local hashedRhd = {}

for i, v in pairs(rhdCars) do
    hashedRhd[joaat(v)] = true
end

-- ========== PICKLE WHEEL SYSTEM (WHEEL/PEDAL FUNCTIONALITY) ==========
local Controls = {}
local DeviceSettings = {}
local PressedBinds = {}
local manualEnabled = false
local lastUpdate = 0
local wheelActive = false

-- ========== UTILITY FUNCTIONS ==========

local function isDriver(vehicle)
    if (GetPedInVehicleSeat(vehicle, -1) == PlayerPedId()) then return true end
    return false
end

local function notify(text, type)
    if libAvailable and Config.OxLib and lib then
        lib.notify({
            title = text,
            type = type or 'info',
        })
    else
        -- Fallback to chat message
        TriggerEvent('chat:addMessage', {
            color = { 255, 255, 0 },
            args = { "Manual Gearbox", text }
        })
    end
end

-- ========== ANIMATION SYSTEM ==========
local loadedAnimDicts = {}

local function animDictIsLoaded(animDict)
    if loadedAnimDicts[animDict] then
        if useDebug then print('^6Animation was already loaded') end
        return true
    end

    RequestAnimDict(animDict)
    if useDebug then notify('Loading animation Fresh', 'success') end
    local retrys = 0
    while not HasAnimDictLoaded(animDict) do
        if useDebug then print('Loading animation dict for gearbox', animDict) end
        retrys = retrys + 1
        if retrys > 10 then
            if useDebug then
                notify('Failed to load dictionary', 'error')
            end
            return false
        end
        Wait(10)
    end

    loadedAnimDicts[animDict] = true
    return true
end

local function clearAnimCache()
    for dict in pairs(loadedAnimDicts) do
        RemoveAnimDict(dict)
    end
    loadedAnimDicts = {}
    if useDebug then print('^3Cleared animation cache') end
end

-- Clear animation cache every 5 minutes
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(5 * 60 * 1000)
        clearAnimCache()
    end
end)

local function playAnimation(animation, animDict)
    if animDictIsLoaded(animDict) then
        if useDebug then print('^2Animation loaded successfully') end
        TaskPlayAnim(PlayerPedId(), animDict, animation, 8.0, 1.0, 500, 48, 0, 0, 0, 0)
        Wait(100)
        StopAnimTask(PlayerPedId(), animDict, animation, 1.0)
    else
        if useDebug then print('^1Could not load animation') end
    end
end

local function handleAnimation(vehicle)
    local rhd = hashedRhd[GetEntityModel(vehicle)]
    local class = GetVehicleClass(vehicle)
    if class == 8 or class == 21 or class == 16 or class == 15 or class == 14 or class == 13 then
        if useDebug then print('Vehicle does not have gearing animation') end
        return
    end
    if rhd then
        playAnimation(RanimationName, RanimationDict)
    else
        playAnimation(LanimationName, LanimationDict)
    end
end

-- ========== BIT OPERATIONS FOR FLAGS ==========
local OR, XOR, AND = 1, 3, 4
local function bitOper(flag, checkFor, oper)
    local result, mask, sum = 0, 2 ^ 31
    repeat
        sum, flag, checkFor = flag + checkFor + mask, flag % mask, checkFor % mask
        result, mask = result + mask * oper % (sum - flag - checkFor), mask / 2
    until mask < 1
    return result
end

local function addManualFlagToFlag(flag)
    local hasFullAutoFlag = bitOper(flag, 512, AND) == 512
    local hasDirectShiftFlag = bitOper(flag, 2048, AND) == 2048

    -- Remove flags 512 and 2048 if present
    if hasFullAutoFlag then
        flag = bitOper(flag, 512, XOR)
    end
    if hasDirectShiftFlag then
        flag = bitOper(flag, 2048, XOR)
    end

    -- Add flag 1024 (manual)
    flag = bitOper(flag, MANUAL_FLAG, OR)

    return math.floor(flag)
end

local function removeManualFlagFromFlag(flag)
    local hasFullAutoFlag = bitOper(flag, 512, AND) == 512
    local hasDirectShiftFlag = bitOper(flag, 2048, AND) == 2048

    -- Remove flags 512 and 2048 if present
    if hasFullAutoFlag then
        flag = bitOper(flag, 512, XOR)
    end
    if hasDirectShiftFlag then
        flag = bitOper(flag, 2048, XOR)
    end

    -- Remove manual flag
    flag = bitOper(flag, MANUAL_FLAG, XOR)

    return math.floor(flag)
end

local function vehicleHasFlag(vehicle, adv_flags)
    if adv_flags == nil then adv_flags = GetVehicleHandlingInt(vehicle, 'CCarHandlingData', 'strAdvancedFlags') end
    if adv_flags == 0 and useDebug then
        print('^1This vehicle either has empty advancedflags or no advanced flag in its handling file')
    end
    local flag_check_1024 = bitOper(adv_flags, MANUAL_FLAG, AND)
    local hasFlag = flag_check_1024 == MANUAL_FLAG
    if useDebug then print('Vehicle has flag:', adv_flags, hasFlag) end
    return hasFlag
end

-- ========== MANUAL TRANSMISSION CONTROL ==========

local function createControlThread()
    Citizen.CreateThread(function()
        while true do
            local Player = PlayerPedId()
            local vehicle = GetVehiclePedIsUsing(Player)
            if not vehicle or not isDriver(vehicle) then
                TerminateThisThread()
                break;
            end
            Wait(1)
            -- Disable GTA's default gear controls
            DisableControlAction(0, 363, true)
            DisableControlAction(0, 364, true)
        end
    end)
end

local function removeManualFlag(vehicle)
    if useDebug then print('Removing manual flag') end
    local adv_flags = GetVehicleHandlingInt(vehicle, 'CCarHandlingData', 'strAdvancedFlags')
    if not Entity(vehicle).state.originalFlag then
        if useDebug then print('Setting default flag') end
        Entity(vehicle).state:set('originalFlag', adv_flags, true)
    end
    local newFlag = removeManualFlagFromFlag(adv_flags)
    SetVehicleHandlingInt(vehicle, 'CCarHandlingData', 'strAdvancedFlags', newFlag)
    ModifyVehicleTopSpeed(vehicle, 1.0)
    Entity(vehicle).state:set('isManual', false, true)
end

local function addManualFlag(vehicle)
    if useDebug then print('Adding manual flag') end

    local adv_flags = GetVehicleHandlingInt(vehicle, 'CCarHandlingData', 'strAdvancedFlags')
    if not Entity(vehicle).state.originalFlag then
        if useDebug then print('Setting default flag') end
        Entity(vehicle).state:set('originalFlag', adv_flags, true)
    end
    local newFlag = addManualFlagToFlag(adv_flags)
    SetVehicleHandlingInt(vehicle, 'CCarHandlingData', 'strAdvancedFlags', newFlag)
    ModifyVehicleTopSpeed(vehicle, 1.0)
    Entity(vehicle).state:set('isManual', true, true)
end

local function vehicleHasManualGearBox(vehicle)
    local adv_flags = GetVehicleHandlingInt(vehicle, 'CCarHandlingData', 'strAdvancedFlags')
    local originalFlag = Entity(vehicle).state.originalFlag
    if not originalFlag then
        if useDebug then print('Setting original flag to', adv_flags) end
        Entity(vehicle).state:set('originalFlag', adv_flags, true)
    end

    if vehicleHasFlag(vehicle, adv_flags) then
        topGear = GetVehicleHighGear(vehicle)
        clutchDown = GetVehicleHandlingFloat(vehicle, 'CHandlingData', 'fClutchChangeRateScaleDownShift')
        clutchUp = GetVehicleHandlingFloat(vehicle, 'CHandlingData', 'fClutchChangeRateScaleUpShift')
        if isDriver(vehicle) and Config.NotifyManual then
            notify(Config.ManualNotificationText)
        end
        createControlThread()
        Entity(vehicle).state:set('isManual', true, true)
        return true
    else
        Entity(vehicle).state:set('isManual', false, true)
        return false
    end
end

-- ========== STALL SYSTEM FUNCTIONS ==========

local function stallEngine(vehicle)
    if isStalled or stallCooldown > GetGameTimer() then return end

    isStalled = true
    stallCooldown = GetGameTimer() + stallCooldownTime

    -- Turn off engine
    SetVehicleEngineOn(vehicle, false, true, true)

    -- Force vehicle to stop
    SetVehicleForwardSpeed(vehicle, 0.0)

    -- Reset gear to neutral
    nextGear = 0
    Citizen.InvokeNative(SETGEARNATIVE, vehicle, 0)

    -- User feedback
    TriggerEvent('chat:addMessage', {
        color = { 255, 100, 100 },
        args = { "Engine", "ENGINE STALLED! RPM too low for current gear." }
    })

    -- Update UI
    SendNUIMessage({
        type = "updateGearDisplay",
        gear = 0,
        manual = true,
        stalled = true
    })

    if useDebug then
        print("[Stall System] Engine stalled - RPM too low for current gear")
    end
end

-- Function to reset stall state when engine is manually started
local function checkEngineState(vehicle)
    if isStalled and GetIsVehicleEngineRunning(vehicle) then
        -- Player manually restarted engine - reset stall state
        isStalled = false
        stallTime = 0
        lastStallCheck = 0
        stallWarningShown = false

        -- Update UI
        SendNUIMessage({
            type = "updateGearDisplay",
            gear = nextGear,
            manual = true,
            stalled = false
        })

        if useDebug then
            print("[Stall System] Engine manually restarted - stall state reset")
        end
    end
end

local function checkForStall(vehicle, rpm, currentGear, currentTime)
    if isStalled or not manualEnabled or currentGear == 0 then return end

    -- Don't check for stall if gearing or in cooldown
    if isGearing or stallCooldown > currentTime then return end

    -- Get gear-specific stall threshold
    local gearThreshold = gearStallThresholds[currentGear] or stallRPM
    local isAtStallRPM = rpm <= gearThreshold

    -- Check for instant stall conditions
    local speed = GetEntitySpeed(vehicle) * 2.237 -- Convert to MPH
    local instantStallConditions = {
        -- High gear at very low speed
        (currentGear >= 3 and speed < 10 and rpm < 0.2),
        -- Any gear with RPM below critical threshold
        (rpm < gearThreshold * 0.7),
        -- Starting from stop in high gear
        (speed < 2 and currentGear >= 3)
    }

    -- Check for instant stall
    for _, condition in ipairs(instantStallConditions) do
        if condition then
            stallEngine(vehicle)
            return
        end
    end

    -- Progressive stall system
    if isAtStallRPM then
        if lastStallCheck == 0 then
            lastStallCheck = currentTime
        end

        stallTime = stallTime + (currentTime - lastStallCheck)
        lastStallCheck = currentTime

        -- Show warning after 1 second at stall RPM
        if stallTime > 1000 and not stallWarningShown then
            TriggerEvent('chat:addMessage', {
                color = { 255, 200, 0 },
                args = { "Engine", "Warning: RPM too low! Increase throttle or downshift!" }
            })
            stallWarningShown = true
        end

        -- Stall after grace period
        if stallTime > stallGraceTime then
            stallEngine(vehicle)
        end
    else
        -- Reset stall timer if RPM is adequate
        if stallTime > 0 then
            if useDebug and stallTime > 500 then
                print("[Stall System] RPM recovered. Stall time: " ..
                    string.format("%.1f", stallTime / 1000) .. "s")
            end
            stallTime = 0
            lastStallCheck = 0
            stallWarningShown = false
        end
    end
end

-- ========== GEAR SHIFTING FUNCTIONS ==========

local function setNextGear(veh)
    Citizen.InvokeNative(SETGEARNATIVE, veh, nextGear)
    if Config.UseServerSideStateSet then
        TriggerServerEvent('pickle-gearbox:server:setGear', NetworkGetNetworkIdFromEntity(veh), nextGear)
        return
    end
    Entity(veh).state:set('gearchange', nextGear, false)
end

local function setNoGear(veh)
    Citizen.InvokeNative(SETGEARNATIVE, veh, 0)
end

local function setVehicleCurrentGear(veh, gear, clutch, currentGear)
    if GetEntitySpeedVector(veh, true).y < 0 then
        return
    end

    if useDebug then
        notify('Next gear: ' .. nextGear)
        print('^5========== NEW GEAR ==========')
        print('veh', veh)
        print('gear', gear)
        print('clutch', clutch)
        print('currentGear', currentGear)
    end

    if isGearing then
        if useDebug then print('^3Is gearing. skipping') end
        SetTimeout(300, function()
            if useDebug then print('Resetting clutch') end
            isGearing = false
        end)
        return
    else
        setNoGear(veh)
        isGearing = true
        SetTimeout(Config.ClutchTime / clutch, function()
            isGearing = false
            setNextGear(veh)
        end)
    end
    handleAnimation(veh)
end

local function shiftUp()
    if useDebug then print("[pickle_wheel] shiftUp called - manualEnabled: " .. tostring(manualEnabled)) end

    local Player = PlayerPedId()
    local vehicle = GetVehiclePedIsUsing(Player)
    local adv_flags = GetVehicleHandlingInt(vehicle, 'CCarHandlingData', 'strAdvancedFlags')
    if vehicle == 0 then
        if useDebug then print("[pickle_wheel] No vehicle found") end
        return
    end
    if not isDriver(vehicle) then
        if useDebug then print('^1Not driver') end
        return
    end
    if not manualEnabled then
        if useDebug then print("[pickle_wheel] Manual transmission not enabled") end
        return
    end
    if not vehicleHasFlag(vehicle, adv_flags) then
        if useDebug then print("[pickle_wheel] Vehicle does not have manual flag") end
        return
    end
    local currentGear = GetVehicleCurrentGear(vehicle)

    if useDebug then
        print("[pickle_wheel] shiftUp - Before: CurrentGear:" ..
            currentGear .. ", TopGear:" .. topGear .. ", nextGear:" .. nextGear)
    end
    if currentGear == topGear then
        TriggerEvent('chat:addMessage', {
            color = { 255, 165, 0 },
            args = { "Gear", "Already in top gear!" }
        })
        return
    end

    if currentGear == lowestGear then
        nextGear = nextGear + 1
        if useDebug then print('Current gear is lowest gear. Next gear will be', nextGear) end
    else
        nextGear = GetVehicleNextGear(vehicle) + 1
        if useDebug then print('Current was not lowest gear. Next gear will be', nextGear) end
    end

    if useDebug then print('After: CurrentGear:', currentGear, 'TopGear:', topGear, 'nextGear', nextGear) end
    if nextGear > topGear then nextGear = topGear end

    setVehicleCurrentGear(vehicle, nextGear, clutchUp, currentGear)
    ModifyVehicleTopSpeed(vehicle, 1)

    -- User feedback (UI update handled by main thread)
    TriggerEvent('chat:addMessage', {
        color = { 0, 255, 0 },
        args = { "Gear", "Shifted up to gear " .. nextGear }
    })

    if useDebug then print("[pickle_wheel] shiftUp completed - gear set to " .. nextGear) end
end

local function shiftDown()
    if useDebug then print("[pickle_wheel] shiftDown called - manualEnabled: " .. tostring(manualEnabled)) end

    local Player = PlayerPedId()
    local vehicle = GetVehiclePedIsUsing(Player)
    local adv_flags = GetVehicleHandlingInt(vehicle, 'CCarHandlingData', 'strAdvancedFlags')
    if not isDriver(vehicle) then return end
    if not manualEnabled then
        if useDebug then print("[pickle_wheel] Manual transmission not enabled") end
        return
    end
    if not vehicleHasFlag(vehicle, adv_flags) then return end
    local currentGear = GetVehicleCurrentGear(vehicle)

    if useDebug then print("[pickle_wheel] shiftDown - Before: CurrentGear:" .. currentGear .. ", nextGear:" .. nextGear) end

    if currentGear == lowestGear then
        local newNextGear = nextGear - 1
        if newNextGear > lowestGear then nextGear = newNextGear end
    else
        local newNextGear = currentGear - 1
        if newNextGear > lowestGear then nextGear = newNextGear end
    end

    if nextGear <= lowestGear then
        TriggerEvent('chat:addMessage', {
            color = { 255, 165, 0 },
            args = { "Gear", "Already in lowest gear!" }
        })
        return
    end

    setVehicleCurrentGear(vehicle, nextGear, clutchDown, currentGear)
    ModifyVehicleTopSpeed(vehicle, 1)

    -- User feedback (UI update handled by main thread)
    TriggerEvent('chat:addMessage', {
        color = { 0, 255, 0 },
        args = { "Gear", "Shifted down to gear " .. nextGear }
    })

    if useDebug then print("[pickle_wheel] shiftDown completed - gear set to " .. nextGear) end
end

-- ========== NUI CALLBACKS (PICKLE WHEEL FUNCTIONALITY) ==========

RegisterNUICallback("updateInput", function(data, cb)
    for k, v in pairs(data) do
        local value = v
        if value > 0.9999 then
            value = 0.9999
        elseif value < -0.9999 then
            value = -0.9999
        end
        if k == "wheelAxis" then
            if value > 0 then
                value = value + (DeviceSettings.wheelDeadzone or 0)
            elseif value < 0 then
                value = value - (DeviceSettings.wheelDeadzone or 0)
            end
        end
        Controls[k] = value
    end
    cb(true)
end)

RegisterNUICallback("buttonUpdate", function(data, cb)
    ButtonInteract(data.index, data.pressed)
    cb(true)
end)

RegisterNUICallback("updateSettings", function(data, cb)
    UpdateSettings(data)
    cb(true)
end)

RegisterNUICallback("close", function(data, cb)
    SetNuiFocus(false, false)
    cb(true)
end)

-- Manual transmission toggle callback
RegisterNUICallback("toggleManual", function(data, cb)
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)

    manualEnabled = data.manual

    if not vehicle or vehicle == 0 then
        SendNUIMessage({
            type = "updateGearDisplay",
            gear = 0,
            manual = manualEnabled
        })
        cb(true)
        return
    end

    if useDebug then
        print("[pickle_wheel] Manual transmission toggled: " ..
            tostring(manualEnabled) .. " for vehicle: " .. vehicle)
    end

    if manualEnabled then
        -- Initialize gear system variables
        topGear = GetVehicleHighGear(vehicle)
        clutchUp = GetVehicleHandlingFloat(vehicle, 'CHandlingData', 'fClutchChangeRateScaleUpShift') or 1.0
        clutchDown = GetVehicleHandlingFloat(vehicle, 'CHandlingData', 'fClutchChangeRateScaleDownShift') or 1.0
        isGearing = false
        nextGear = 1 -- Start in first gear

        -- Apply manual flag
        addManualFlag(vehicle)

        -- Force vehicle into first gear
        Citizen.InvokeNative(SETGEARNATIVE, vehicle, 1)

        notify("Manual transmission enabled. Use " .. Config.Keys.gearUp .. "/" .. Config.Keys.gearDown .. " to shift.")

        -- Create control thread if not already created
        createControlThread()

        if useDebug then
            print("[pickle_wheel] Manual transmission initialized - Gear: " ..
                nextGear .. ", TopGear: " .. topGear)
        end
    else
        removeManualFlag(vehicle)
        nextGear = 0
        isGearing = false

        -- Hide gear display when disabled
        SendNUIMessage({
            type = "updateGearDisplay",
            gear = 0,
            manual = false
        })

        notify("Switched to automatic transmission.")
    end

    cb(true)
end)

RegisterNUICallback("getManualStatus", function(data, cb)
    cb({ manual = manualEnabled })
end)

-- ========== BUTTON INTERACTION (SIMPLIFIED FOR GEAR SHIFTING) ==========

function ButtonInteract(index, pressed)
    local bind = DeviceSettings.binds and DeviceSettings.binds[index .. ""]
    if bind then
        if bind.type == "control" and bind.values[2] ~= nil then
            if pressed then
                local startTime = GetGameTimer()
                PressedBinds[index] = true
                CreateThread(function()
                    local key = tonumber(bind.values[2])
                    while lastUpdate < startTime and PressedBinds[index] do
                        SetControlNormal(0, key, 1.0)
                        SetControlNormal(1, key, 1.0)
                        SetControlNormal(2, key, 1.0)
                        Wait(0)
                    end
                end)
            else
                PressedBinds[index] = false
            end
        elseif bind.type == "command" then
            if pressed and bind.values[1] ~= nil then
                PressedBinds[index] = true
                ExecuteCommand(bind.values[1])
            elseif not pressed and bind.values[2] ~= nil then
                PressedBinds[index] = false
                ExecuteCommand(bind.values[2])
            end
        elseif bind.type == "gearshift" and pressed then
            local ped = PlayerPedId()
            local vehicle = GetVehiclePedIsIn(ped, false)

            if vehicle ~= 0 and manualEnabled then
                if bind.values[1] == "up" then
                    shiftUp()
                elseif bind.values[1] == "down" then
                    shiftDown()
                end
            end
        end
    end
end

function UpdateSettings(data)
    lastUpdate = GetGameTimer()
    DeviceSettings = data
    SetResourceKvp("picklewheel", json.encode(DeviceSettings))
end

-- Function to reinitialize gear system for a new vehicle
local function reinitializeGearSystem(vehicle)
    if not vehicle or vehicle == 0 then return end

    -- Reset all gear system variables for the new vehicle
    topGear = GetVehicleHighGear(vehicle)
    clutchUp = GetVehicleHandlingFloat(vehicle, 'CHandlingData', 'fClutchChangeRateScaleUpShift') or 1.0
    clutchDown = GetVehicleHandlingFloat(vehicle, 'CHandlingData', 'fClutchChangeRateScaleDownShift') or 1.0
    isGearing = false
    nextGear = 1 -- Start in first gear for new vehicle

    -- Reset engine damage counters
    redlineTime = 0
    lastRedlineCheck = 0
    damageWarningShown = false
    isEngineWarningActive = false

    -- Reset stall system variables
    isStalled = false
    stallTime = 0
    lastStallCheck = 0
    stallWarningShown = false
    stallCooldown = 0

    -- Apply manual flag to the new vehicle
    addManualFlag(vehicle)

    -- Force vehicle into first gear
    Citizen.InvokeNative(SETGEARNATIVE, vehicle, 1)

    if useDebug then
        print("[pickle_wheel] Reinitialized gear system for new vehicle - TopGear: " ..
            topGear .. ", Starting gear: " .. nextGear)
    end
end

-- ========== VEHICLE ENTER/EXIT HANDLING ==========

if libAvailable then
    lib.onCache("vehicle", function(newVehicle)
        SendNUIMessage({
            type = "toggleGameLoop",
            toggle = newVehicle ~= false
        })

        if newVehicle then
            -- Check if manual transmission is enabled
            if manualEnabled then
                -- Always reinitialize gear system for new vehicle when manual is enabled
                reinitializeGearSystem(newVehicle)
                if useDebug then print("[pickle_wheel] Entered vehicle with manual transmission enabled") end
            end
        else
            -- Exited vehicle - hide gear display and reset variables
            SendNUIMessage({
                type = "updateGearDisplay",
                gear = 0,
                manual = false
            })
            -- Reset gear system variables when exiting vehicle
            nextGear = 1
            isGearing = false
            redlineTime = 0
            lastRedlineCheck = 0
            damageWarningShown = false
            if useDebug then print("[pickle_wheel] Exited vehicle - hiding gear display") end
        end
    end)
else
    -- Fallback vehicle detection without ox_lib
    CreateThread(function()
        local lastVehicle = nil
        while true do
            local ped = PlayerPedId()
            local currentVehicle = GetVehiclePedIsIn(ped, false)

            if currentVehicle ~= lastVehicle then
                if currentVehicle ~= 0 then
                    -- Entered vehicle
                    SendNUIMessage({
                        type = "toggleGameLoop",
                        toggle = true
                    })

                    if manualEnabled then
                        -- Always reinitialize gear system for new vehicle when manual is enabled
                        reinitializeGearSystem(currentVehicle)
                        if useDebug then print("[pickle_wheel] Entered vehicle with manual transmission enabled") end
                    end
                else
                    -- Exited vehicle - hide gear display and reset variables
                    SendNUIMessage({
                        type = "toggleGameLoop",
                        toggle = false
                    })
                    SendNUIMessage({
                        type = "updateGearDisplay",
                        gear = 0,
                        manual = false
                    })
                    -- Reset gear system variables when exiting vehicle
                    nextGear = 1
                    isGearing = false
                    redlineTime = 0
                    lastRedlineCheck = 0
                    damageWarningShown = false
                    if useDebug then print("[pickle_wheel] Exited vehicle - hiding gear display") end
                end
                lastVehicle = currentVehicle
            end
            Wait(1000)
        end
    end)
end

-- ========== WHEEL/PEDAL CONTROL THREAD ==========

CreateThread(function()
    Wait(1000)
    DeviceSettings = json.decode(GetResourceKvpString("picklewheel"))
    if DeviceSettings then
        wheelActive = true
    end
    SendNUIMessage({
        type = "updateSettings",
        data = DeviceSettings
    })

    while true do
        if wheelActive then
            -- Apply wheel and pedal inputs
            SetControlNormal(0, 59, Controls.wheelAxis or 0.0)
            SetControlNormal(0, 71, Controls.throttleAxis or 0.0)
            SetControlNormal(0, 72, Controls.brakeAxis or 0.0)
            SetControlNormal(0, 73, Controls.clutchAxis or 0.0)
            Wait(0)
        else
            Wait(5000)
        end
    end
end)

-- ========== KEY BINDINGS ==========

if libAvailable and Config.OxLib and lib then
    lib.addKeybind({
        name = 'shiftup',
        description = 'Shift Up',
        defaultKey = Config.Keys.gearUp,
        onPressed = function(self)
            shiftUp()
        end,
    })

    lib.addKeybind({
        name = 'shiftdown',
        description = 'Shift Down',
        defaultKey = Config.Keys.gearDown,
        onPressed = function(self)
            shiftDown()
        end
    })
else
    RegisterCommand("shiftUp", function()
        shiftUp()
    end, false)
    RegisterKeyMapping("shiftUp", "Shift Up", "keyboard", Config.Keys.gearUp)

    RegisterCommand("shiftDown", function()
        shiftDown()
    end, false)
    RegisterKeyMapping("shiftDown", "Shift Down", "keyboard", Config.Keys.gearDown)
end

-- ========== VEHICLE ENTER/EXIT HANDLING ==========

local function createPassengerThread()
    if useDebug then print('Initiating Passenger thread') end
    local ped = PlayerPedId()
    CreateThread(function()
        while IsPedInAnyVehicle(ped, false) do
            local vehicle = GetVehiclePedIsIn(ped, false)

            if DoesEntityExist(vehicle) then
                if not isDriver(vehicle) then
                    if Entity(vehicle).state.gearchange ~= GetVehicleCurrentGear(vehicle) then
                        if useDebug then
                            print('^1Current gear:', GetVehicleCurrentGear(vehicle))
                            print('^2Should be', Entity(vehicle).state.gearchange)
                        end
                        nextGear = GetVehicleCurrentGear(vehicle)
                        setNextGear(vehicle)
                    end
                end
            end
            Wait(Config.GearCheckSleep)
        end
        if useDebug then print('Not in a vehicle. Breaking Thread.') end
    end)
end

local function createDriverThread()
    if useDebug then print('Initiating Driver thread') end
    local ped = PlayerPedId()
    CreateThread(function()
        while IsPedInAnyVehicle(ped, false) do
            local vehicle = GetVehiclePedIsIn(ped, false)

            if DoesEntityExist(vehicle) then
                if isDriver(vehicle) then
                    if Entity(vehicle).state.gearchange ~= GetVehicleCurrentGear(vehicle) then
                        if useDebug then
                            print('^1Current gear:', GetVehicleCurrentGear(vehicle))
                            print('^2Should be', Entity(vehicle).state.gearchange)
                        end
                    end
                end
            end
            Wait(Config.GearCheckSleep)
        end
        if useDebug then print('Not in a vehicle. Breaking Thread.') end
    end)
end

AddEventHandler('gameEventTriggered', function(name, args)
    if name == 'CEventNetworkPlayerEnteredVehicle' and not isEnteringVehicle then
        local enteredPlayerId = args[1]
        local localPlayerId = PlayerId()
        if enteredPlayerId ~= localPlayerId then
            if useDebug then print('Another player entered vehicle. Skipping') end
            return
        end
        isEnteringVehicle = true
        SetTimeout(2000, function()
            isEnteringVehicle = false
        end)
        local Player = PlayerPedId()
        local vehicle = GetVehiclePedIsUsing(Player)

        if manualEnabled and vehicleHasManualGearBox(vehicle) then
            if not isDriver(vehicle) then
                createPassengerThread()
                return
            end

            isGearing = false
            nextGear = 1
            topGear = GetVehicleHighGear(vehicle)
            clutchUp = GetVehicleHandlingFloat(vehicle, 'CHandlingData', 'fClutchChangeRateScaleUpShift') or 1.0
            clutchDown = GetVehicleHandlingFloat(vehicle, 'CHandlingData', 'fClutchChangeRateScaleDownShift') or 1.0
            createDriverThread()

            -- Update UI
            SendNUIMessage({
                type = "updateGearDisplay",
                gear = nextGear,
                manual = true
            })
        end
    end
end)

AddStateBagChangeHandler("gearchange", nil, function(bagName, key, value)
    local veh = GetEntityFromStateBagName(bagName)
    if useDebug then print('State Bag Called: gear change for veh', veh, value) end
    if veh == 0 then return end
    if not isDriver(veh) then
        local attempts = 0
        while not HasCollisionLoadedAroundEntity(veh) and attempts < 20 do
            if not DoesEntityExist(veh) then return end
            attempts = attempts + 1
            Wait(100)
        end
        if attempts == 20 then
            if useDebug then print('^1Could not find entity!^0') end
        end

        Citizen.InvokeNative(SETGEARNATIVE, veh, value)
    else
        if useDebug then print('^3Skipping change due to being driver^0') end
    end
end)

-- ========== COMMANDS ==========

RegisterCommand("wheel", function()
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 then
        return
    end
    SetNuiFocus(true, true)
    SendNUIMessage({
        type = "open"
    })
    wheelActive = true
end)

RegisterCommand("wheeloff", function()
    wheelActive = false
end)

RegisterCommand("pickle_help", function()
    TriggerEvent('chat:addMessage', {
        color = { 0, 255, 255 },
        args = { "Pickle Wheel Help", "Use the wheel settings UI to configure your wheel and pedals. Toggle manual transmission in the UI." }
    })
    TriggerEvent('chat:addMessage', {
        color = { 0, 255, 255 },
        args = { "Gear Controls", "Shift Up: " .. Config.Keys.gearUp .. " | Shift Down: " .. Config.Keys.gearDown }
    })
    TriggerEvent('chat:addMessage', {
        color = { 255, 200, 100 },
        args = { "Stall System", "Engine stalls if RPM too low for gear. Use normal engine controls to restart." }
    })
    TriggerEvent('chat:addMessage', {
        color = { 255, 255, 0 },
        args = { "Debug Commands", "/pickle_debug - Show debug info | /stall_debug - Stall system info | /engine_debug - Engine health" }
    })
    TriggerEvent('chat:addMessage', {
        color = { 255, 255, 0 },
        args = { "Advanced", "/force_stall - Test stall | /toggle_stall_system - Enable/disable stall system" }
    })
end)

RegisterCommand("resetgear", function()
    nextGear = 1
    isGearing = false
    TriggerEvent('chat:addMessage', {
        color = { 255, 255, 0 },
        args = { "System", "Gear system reset. You may need to exit and re-enter your vehicle." }
    })
end)

RegisterCommand("pickle_test", function()
    TriggerEvent('chat:addMessage', {
        color = { 0, 255, 0 },
        args = { "Pickle Wheel Enhanced", "System loaded! Wheel/pedal support: Active" }
    })
    TriggerEvent('chat:addMessage', {
        color = { 0, 255, 255 },
        args = { "Status", "Manual enabled: " .. tostring(manualEnabled) .. " | Wheel active: " .. tostring(wheelActive) }
    })
end)

RegisterCommand("pickle_debug", function()
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)

    if vehicle == 0 then
        TriggerEvent('chat:addMessage', {
            color = { 255, 0, 0 },
            args = { "Debug", "Not in a vehicle!" }
        })
        return
    end

    local rpm = GetVehicleCurrentRpm(vehicle)
    local currentGear = GetVehicleCurrentGear(vehicle)
    local adv_flags = GetVehicleHandlingInt(vehicle, 'CCarHandlingData', 'strAdvancedFlags')
    local hasFlag = vehicleHasFlag(vehicle, adv_flags)

    TriggerEvent('chat:addMessage', {
        color = { 0, 255, 255 },
        args = { "Pickle Debug", "Manual: " .. tostring(manualEnabled) .. " | NextGear: " .. nextGear .. " | CurrentGear: " .. currentGear }
    })
    TriggerEvent('chat:addMessage', {
        color = { 0, 255, 255 },
        args = { "Debug", "RPM: " .. string.format("%.2f", rpm) .. " | TopGear: " .. topGear .. " | HasFlag: " .. tostring(hasFlag) }
    })
    TriggerEvent('chat:addMessage', {
        color = { 0, 255, 255 },
        args = { "Debug", "IsGearing: " .. tostring(isGearing) .. " | Flags: " .. adv_flags }
    })
end)

RegisterCommand("force_gear", function(source, args)
    if #args < 1 then
        TriggerEvent('chat:addMessage', {
            color = { 255, 255, 0 },
            args = { "Usage", "/force_gear [gear_number]" }
        })
        return
    end

    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    local gear = tonumber(args[1])

    if vehicle == 0 then
        TriggerEvent('chat:addMessage', {
            color = { 255, 0, 0 },
            args = { "Error", "Not in a vehicle!" }
        })
        return
    end

    if not gear or gear < 0 or gear > topGear then
        TriggerEvent('chat:addMessage', {
            color = { 255, 0, 0 },
            args = { "Error", "Invalid gear! Use 0-" .. topGear }
        })
        return
    end

    nextGear = gear
    Citizen.InvokeNative(SETGEARNATIVE, vehicle, gear)

    TriggerEvent('chat:addMessage', {
        color = { 0, 255, 0 },
        args = { "Gear", "Forced gear to: " .. gear }
    })
end)

RegisterCommand("engine_debug", function()
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)

    if vehicle == 0 then
        TriggerEvent('chat:addMessage', {
            color = { 255, 0, 0 },
            args = { "Debug", "Not in a vehicle!" }
        })
        return
    end

    local engineHealth = GetVehicleEngineHealth(vehicle)
    local rpm = GetVehicleCurrentRpm(vehicle)
    local isAtRedline = rpm >= redlineRPM

    TriggerEvent('chat:addMessage', {
        color = { 0, 255, 255 },
        args = { "Engine Debug", "Health: " .. string.format("%.1f", engineHealth) .. "/1000 | RPM: " .. string.format("%.2f", rpm) }
    })
    TriggerEvent('chat:addMessage', {
        color = { 0, 255, 255 },
        args = { "Engine Debug", "At redline: " .. tostring(isAtRedline) .. " | Redline time: " .. string.format("%.1f", redlineTime / 1000) .. "s" }
    })

    local healthPercent = (engineHealth / 1000) * 100
    local statusColor
    if healthPercent > 80 then
        statusColor = { 0, 255, 0 }
    elseif healthPercent > 50 then
        statusColor = { 255, 255, 0 }
    elseif healthPercent > 25 then
        statusColor = { 255, 165, 0 }
    else
        statusColor = { 255, 0, 0 }
    end

    TriggerEvent('chat:addMessage', {
        color = statusColor,
        args = { "Engine Status", string.format("%.1f", healthPercent) .. "% - " ..
        (healthPercent > 80 and "Excellent" or
            healthPercent > 50 and "Good" or
            healthPercent > 25 and "Poor" or "Critical") }
    })
end)

RegisterCommand("stall_debug", function()
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)

    if vehicle == 0 then
        TriggerEvent('chat:addMessage', {
            color = { 255, 0, 0 },
            args = { "Stall Debug", "Not in a vehicle!" }
        })
        return
    end

    local rpm = GetVehicleCurrentRpm(vehicle)
    local currentGear = GetVehicleCurrentGear(vehicle)
    local speed = GetEntitySpeed(vehicle) * 2.237 -- Convert to MPH
    local gearThreshold = gearStallThresholds[currentGear] or stallRPM
    local isEngineRunning = GetIsVehicleEngineRunning(vehicle)

    TriggerEvent('chat:addMessage', {
        color = { 0, 255, 255 },
        args = { "Stall Debug", "Stalled: " .. tostring(isStalled) .. " | Engine Running: " .. tostring(isEngineRunning) }
    })
    TriggerEvent('chat:addMessage', {
        color = { 0, 255, 255 },
        args = { "Stall Debug", "RPM: " .. string.format("%.2f", rpm) .. " | Threshold: " .. string.format("%.2f", gearThreshold) }
    })
    TriggerEvent('chat:addMessage', {
        color = { 0, 255, 255 },
        args = { "Stall Debug", "Speed: " .. string.format("%.1f", speed) .. " MPH | Stall Time: " .. string.format("%.1f", stallTime / 1000) .. "s" }
    })

    local cooldownRemaining = math.max(0, (stallCooldown - GetGameTimer()) / 1000)
    if cooldownRemaining > 0 then
        TriggerEvent('chat:addMessage', {
            color = { 255, 255, 0 },
            args = { "Stall Debug", "Cooldown: " .. string.format("%.1f", cooldownRemaining) .. "s remaining" }
        })
    end
end)

RegisterCommand("force_stall", function()
    local ped = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)

    if vehicle == 0 then
        TriggerEvent('chat:addMessage', {
            color = { 255, 0, 0 },
            args = { "Force Stall", "Not in a vehicle!" }
        })
        return
    end

    if not manualEnabled then
        TriggerEvent('chat:addMessage', {
            color = { 255, 0, 0 },
            args = { "Force Stall", "Manual transmission not enabled!" }
        })
        return
    end

    stallEngine(vehicle)
    TriggerEvent('chat:addMessage', {
        color = { 255, 255, 0 },
        args = { "Force Stall", "Engine forcefully stalled for testing!" }
    })
end)

RegisterCommand("toggle_stall_system", function()
    -- Toggle the stall system by modifying grace time
    if stallGraceTime == 2000 then
        stallGraceTime = 999999 -- Effectively disable stall system
        TriggerEvent('chat:addMessage', {
            color = { 255, 255, 0 },
            args = { "Stall System", "Stall system DISABLED" }
        })
    else
        stallGraceTime = 2000 -- Re-enable with default grace time
        TriggerEvent('chat:addMessage', {
            color = { 0, 255, 0 },
            args = { "Stall System", "Stall system ENABLED (2s grace period)" }
        })
    end
end)

if useDebug then print("^2[Pickle Wheel] Enhanced manual transmission system loaded successfully!^0") end

-- ========== MAIN CONTROL THREAD ==========

CreateThread(function()
    local lastDisplayedGear = nil -- Track last gear sent to UI

    while true do
        if manualEnabled then
            Wait(50) -- Reduced frequency - 20 times per second instead of 60+

            local ped = PlayerPedId()
            local vehicle = GetVehiclePedIsIn(ped, false)

            if vehicle ~= 0 and GetPedInVehicleSeat(vehicle, -1) == ped then
                local rpm = GetVehicleCurrentRpm(vehicle)
                local currentGear = GetVehicleCurrentGear(vehicle)
                local currentTime = GetGameTimer()

                -- Check for stall conditions (only if not stalled)
                if not isStalled then
                    checkForStall(vehicle, rpm, currentGear, currentTime)
                else
                    -- Check if player manually restarted engine
                    checkEngineState(vehicle)
                end

                -- Engine damage system - monitor high RPM (only if not stalled)
                if not isStalled and rpm >= redlineRPM and not isGearing then
                    -- Vehicle is at redline
                    if lastRedlineCheck == 0 then
                        lastRedlineCheck = currentTime
                    end

                    redlineTime = redlineTime + (currentTime - lastRedlineCheck)
                    lastRedlineCheck = currentTime

                    -- Show warning after 3 seconds at redline
                    if redlineTime > 3000 and not damageWarningShown then
                        TriggerEvent('chat:addMessage', {
                            color = { 255, 100, 0 },
                            args = { "Engine", "Warning: Engine overrevving! Reduce RPM to prevent damage!" }
                        })
                        damageWarningShown = true
                    end

                    -- Start applying damage after 5 seconds at redline
                    if redlineTime > 5000 then
                        local currentHealth = GetVehicleEngineHealth(vehicle)
                        if currentHealth > 150 then                           -- Don't damage below minimum operational level
                            -- Calculate damage: more damage the longer at redline
                            local timeAtRedline = (redlineTime - 5000) / 1000 -- seconds beyond grace period
                            local damageRate = 0.1 + (timeAtRedline * 0.02)   -- Increasing damage rate
                            local newHealth = currentHealth - damageRate

                            -- Apply the damage
                            SetVehicleEngineHealth(vehicle, math.max(150, newHealth))

                            -- Critical engine warning
                            if currentHealth < 400 and not isEngineWarningActive then
                                isEngineWarningActive = true
                                TriggerEvent('chat:addMessage', {
                                    color = { 255, 0, 0 },
                                    args = { "Engine", "CRITICAL: Engine severely damaged! Stop overrevving immediately!" }
                                })

                                -- Reset warning after 10 seconds
                                SetTimeout(10000, function()
                                    isEngineWarningActive = false
                                end)
                            end

                            if useDebug then
                                print("[Engine Damage] RPM: " .. string.format("%.2f", rpm) ..
                                    ", Time at redline: " .. string.format("%.1f", redlineTime / 1000) ..
                                    "s, Health: " .. string.format("%.1f", newHealth))
                            end
                        end
                    end
                else
                    -- Not at redline - reset counters
                    if redlineTime > 0 then
                        if useDebug and redlineTime > 1000 then
                            print("[Engine Damage] RPM normalized. Total redline time: " ..
                                string.format("%.1f", redlineTime / 1000) .. "s")
                        end
                        redlineTime = 0
                        lastRedlineCheck = 0
                        damageWarningShown = false
                    end
                end

                -- Update RPM display (10 times per second to reduce overhead)
                if not lastRpmUpdate then lastRpmUpdate = 0 end
                if currentTime - lastRpmUpdate > 100 then
                    SendNUIMessage({
                        type = "updateRPM",
                        rpm = rpm or 0
                    })
                    lastRpmUpdate = currentTime
                end

                -- Ensure gear synchronization (only if not stalled)
                if not isStalled and nextGear ~= currentGear and not isGearing then
                    if useDebug then
                        print('Gear sync: nextGear=' .. nextGear .. ', currentGear=' .. currentGear)
                    end
                    -- Force gear to be what we expect
                    Citizen.InvokeNative(SETGEARNATIVE, vehicle, nextGear)
                end

                -- Only update gear display if the gear has actually changed or stall status changed
                local displayGear = isStalled and 0 or nextGear
                if lastDisplayedGear ~= displayGear then
                    SendNUIMessage({
                        type = "updateGearDisplay",
                        gear = displayGear,
                        manual = true,
                        stalled = isStalled
                    })
                    lastDisplayedGear = displayGear
                end
            else
                -- Not in vehicle - hide gear display if it was shown
                if lastDisplayedGear ~= nil then
                    SendNUIMessage({
                        type = "updateGearDisplay",
                        gear = 0,
                        manual = false,
                        stalled = false
                    })
                    lastDisplayedGear = nil
                    if useDebug then print("[pickle_wheel] Not in vehicle - hiding gear display") end
                end
            end
        else
            Wait(500) -- Longer wait when not in manual mode
            -- Hide gear display when manual mode is disabled
            if lastDisplayedGear ~= nil then
                SendNUIMessage({
                    type = "updateGearDisplay",
                    gear = 0,
                    manual = false,
                    stalled = false
                })
                lastDisplayedGear = nil
            end
        end
    end
end)
