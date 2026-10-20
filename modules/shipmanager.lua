-- The thing that actually manages navigation and such

print("Initializing Prestigious Navigator Module")

local gimbalCorrectInvertX, gimbalCorrectInvertZ, gimbalOffsetDeg
local TwoPi = math.pi * 2

local liftRL1Name = "Lift1"
local liftRL2Name = "Lift2"
local pushRL1Name = "Push1"
local pushRL2Name = "Push2"
local manualControlsRLName = "ManualControls"
local gimbalCorrectPXName = "GimbalCorrectPositiveX"
local gimbalCorrectNXName = "GimbalCorrectNegativeX"
local gimbalCorrectPZName = "GimbalCorrectPositiveZ"
local gimbalCorrectNZName = "GimbalCorrectNegativeZ"

local function systemHandlerTableAction(self)
    if (self["delay"] == 0) or (os.clock() > (self["lastClock"] + self["delay"])) then
        self["lastClock"] = os.clock()
        self["updateValue"](self)
    end
end

-- if scalar, then the handler ignores values less than current.
-- if not, it's a vector and the handler attempts to decrease towards negative values
local function newSystemHandler(delay, updateValue)
    if (not updateValue) then error("Invalid argument for genCurrentTarget: expected 'function', got '"..type(updateValue).."'") end

    return {
        ["delay"] = delay or 0,
        ["Update"] = systemHandlerTableAction,
        ["UpdateValue"] = updateValue,
        ["lastClock"] = 0
    }
end

local context
local target
local redstoneLinks
local navTable

local distanceHandler, altitudeHandler, gimbalHandler, turnDegHandler

local status = {
    ["manualcontrols"] = false,
    ["distance"] = {
        ["targetSqr"] = nil,
        ["travelledSqr"] = 0
    },
    ["turnDeg"] = { 
        ["currentDegFromNorth"] = 0,-- navTable1
        ["targetDegFromNorth"] = 0,
        ["currentIncline"] = 0
    },
    ["propeller"] ={
        ["liftRpm"] = 0,-- line 11
        ["pushRpm"] = 0,-- line 12
        ["tailDeg"] = 0,-- line 13
        ["tailDegRef"] = 0,-- line 14 -- 90 deg offset from tailDeg sensor, to tell angle direction
        ["liftRL1"] = 0,-- redstonePeri1
        ["liftRL2"] = 0,-- redstonePeri2
        ["pushRL1"] = 0,-- redstonePeri3
        ["pushRL2"] = 0,-- redstonePeri4
        ["liftLevel"] = 0,
        ["pushLevel"] = 0
    },
    ["speed"] = {
        ["x"] = 0,-- line 1
        --["y"] = 0,-- line 2 -- We don't need this one, we've got an altitude sensor that's more accurate
        ["z"] = 0 -- line 3
    },
    ["altitude"] = {
        ["target"] = nil,
        ["current"] = 0 -- line 4
    },
    ["gimbal"] = {
        ["x"] = 0,-- line 5
        ["z"] = 0,-- line 6,
        [gimbalCorrectNXName] = 0,
        [gimbalCorrectNZName] = 0,
        [gimbalCorrectPXName] = 0,
        [gimbalCorrectPZName] = 0
    },
    ["fuel"] = {
        {
            ["level"] = 0,-- line 7
            ["max"] = 0,-- line 8
            ["perc"] = 0
        },
        {
            ["level"] = 0,-- line 9
            ["max"] = 0,-- line 10
            ["perc"] = 0
        }
    }
}

local function parseNumber(str)
    return tonumber(str:match("([0-9]+)"))
end

return {

["PreInit"] = function(ctx)
    settings.define("shipman.invertGimbalX", {
        description = "True to invert the gimbal correction on the x axis",
        default = false,
        type = "boolean",
    })

    settings.define("shipman.invertGimbalZ", {
        description = "True to invert the gimbal correction on the z axis",
        default = false,
        type = "boolean",
    })

    settings.define("shipman.gimbalCorrectionOffsetDeg", {
        description = "The angular offset (in degrees) of the gimbal correction mechanism relative to north",
        default = 0,
        type = "number",
    })

    gimbalCorrectInvertX = settings.get("shipman.invertGimbalX")
    gimbalCorrectInvertZ = settings.get("shipman.invertGimbalZ")
    gimbalOffsetDeg = settings.get("shipman.gimbalCorrectionOffsetDeg")

    local cix, ciz, ofd
    if gimbalCorrectInvertX then cix = "Normal X" else cix = "Inverted X" end
    if gimbalCorrectInvertZ then ciz = "Normal Z" else ciz = "Inverted Z" end
    ofd = "Offset by "..tostring(gimbalOffsetDeg).." degrees"

    print("Gimbal Correction Settings: "..cix..", "..ciz..", "..ofd)
end,

["Init"] = function(ctx)
    context = ctx
    if(type(ctx) ~= "table") then
        error("Invalid context provided")
    end

    if type(context.AstralNet) ~= "table" then
        error("Could not start Ship Manager: Invalid or non-existent AstralNet context")
    end

    context.AstralNet.AddEndpoint("status", status)

    target = peripheral.find("create_target")
    if not target then error("Could not find create_target peripheral") end

    navTable = peripheral.find("navigation_table")
    if not navTable then error("Could not find navigation_table peripheral") end

    redstoneLinks = {}
    local rlCount = 0
    peripheral.find("redstone_link", function(name, rl)
        redstoneLinks[name] = rl
        rlCount = rlCount + 1
    end)

    if (not redstoneLinks) or (rlCount == 0) then error("Could not any find redstone_link peripherals") end
    if (rlCount ~= 5) then error("Expected 5 redstone_link peripherals, found " .. tostring(rlCount)) end

    target.resize(64, 14)

    distanceHandler = newSystemHandler(
        0.05,
        function(self)
            -- WARNING!!
            -- set difference thresholds to adjust between the 30 levels of granularity of speed

            if status["distance"]["travelledSqr"] >= status["distance"]["targetSqr"] then
                status["distance"]["travelledSqr"] = 0
                status["distance"]["targetSqr"] = nil
            end
        end
    )

    altitudeHandler = newSystemHandler(
        1,
        function(self)
        end
    )
    
    gimbalHandler = newSystemHandler(
        .5, -- This one's gonna be a doozy
        function(self)
            -- prepare
            local x = status["gimbal"]["x"]
            local z = status["gimbal"]["z"]
            if (math.abs(x) < 0.05) then return end
            if (math.abs(z) < 0.05) then return end

            if gimbalCorrectInvertX then x = x * -1 end
            if gimbalCorrectInvertZ then z = z * -1 end

            -- rotate
            local theta = math.atan(x, z) % TwoPi
            local angularOffset = math.rad(gimbalOffsetDeg)
            local alpha = theta + angularOffset
            local len = math.sqrt((x * x) + (z * z))
            local x2 = len * math.cos(alpha)
            local z2 = len * math.sin(alpha)

            -- apply each component
            -- After all of that, they're still degrees, since we're working with them as vectors and the unit makes no difference

            if (x2 < 0) then
                status["gimbal"][gimbalCorrectPXName] = math.max(0, status["gimbal"][gimbalCorrectPXName] - 1)
                status["gimbal"][gimbalCorrectNXName] = math.min(15, status["gimbal"][gimbalCorrectNXName] + 1)
            else
                status["gimbal"][gimbalCorrectNXName] = math.max(0, status["gimbal"][gimbalCorrectNXName] - 1)
                status["gimbal"][gimbalCorrectPXName] = math.min(15, status["gimbal"][gimbalCorrectPXName] + 1)
            end

            if (z2 < 0) then
                status["gimbal"][gimbalCorrectPZName] = math.max(0, status["gimbal"][gimbalCorrectPZName] - 1)
                status["gimbal"][gimbalCorrectNZName] = math.min(15, status["gimbal"][gimbalCorrectNZName] + 1)
            else
                status["gimbal"][gimbalCorrectNZName] = math.max(0, status["gimbal"][gimbalCorrectNZName] - 1)
                status["gimbal"][gimbalCorrectPZName] = math.min(15, status["gimbal"][gimbalCorrectPZName] + 1)
            end

            redstoneLinks[gimbalCorrectPXName]:setAnalogOutput(status["gimbal"][gimbalCorrectPXName])
            redstoneLinks[gimbalCorrectNXName]:setAnalogOutput(status["gimbal"][gimbalCorrectNXName])
            redstoneLinks[gimbalCorrectNZName]:setAnalogOutput(status["gimbal"][gimbalCorrectNZName])
            redstoneLinks[gimbalCorrectPZName]:setAnalogOutput(status["gimbal"][gimbalCorrectPZName])
        end
    )

    turnDegHandler = newSystemHandler(
        0.05, -- Just keep track of current angle from north and the target, it won't be hard
        function(self)
            -- WARNING!!
            -- Not done
        end
    )
end,

["Update"] = function(delta)
    assert(target)

    local tailDeg, tailDegRef, liftRL1, liftRL2, pushRL1, pushRL2, spdX, spdZ, f1L, f1M, f2L, f2M
    status["propeller"]["liftRpm"] = parseNumber(target.getLine(11))
    status["propeller"]["pushRpm"] = parseNumber(target.getLine(12))
    
    -- directional redstone, where 0 is 180deg and 15 is 0deg 
    tailDeg = parseNumber(target.getLine(13))
    tailDegRef = parseNumber(target.getLine(14))

    if (tailDeg == 15) then
        status["turnDeg"]["currentIncline"] = 0
    elseif (tailDeg == 0) then
        status["turnDeg"]["currentIncline"] = 180
    else
        local deg = (180 / 15) * tailDeg -- there is a lot of error here, have them as close as possible
        if (tailDegRef < 7) then deg = deg * -1 end
        status["turnDeg"]["currentIncline"] = deg
    end

    liftRL1 = redstoneLinks[liftRL1Name]:getAnalogInput()
    liftRL2 = redstoneLinks[liftRL2Name]:getAnalogInput()
    pushRL1 = redstoneLinks[pushRL1Name]:getAnalogInput()
    pushRL2 = redstoneLinks[pushRL2Name]:getAnalogInput()

    status["propeller"]["liftRL1"] = liftRL1
    status["propeller"]["liftRL2"] = liftRL2
    status["propeller"]["pushRL1"] = pushRL1
    status["propeller"]["pushRL2"] = pushRL2
    status["propeller"]["liftLevel"] = (liftRL1 + liftRL2) / 30;
    status["propeller"]["pushLevel"] = (pushRL1 + pushRL2) / 30;

    spdX = parseNumber(target.getLine(1))
    spdZ = parseNumber(target.getLine(3))

    status["speed"]["x"] = spdX
    status["speed"]["z"] = spdZ

    local travelledSqr = status["distance"]["travelledSqr"]

    status["distance"]["travelledSqr"] = travelledSqr + (((spdX * spdX) + (spdZ * spdZ)) * delta)
    status["turnDeg"]["degFromNorth"] = (360 - navTable.getRelativeAngle() + 270) % 360

    status["altitude"]["current"] = parseNumber(target.getLine(4))
    status["gimbal"]["x"] = parseNumber(target.getLine(5))
    status["gimbal"]["z"] = parseNumber(target.getLine(6))

    f1L = parseNumber(target.getLine(7))
    f1M = parseNumber(target.getLine(8))
    f2L = parseNumber(target.getLine(9))
    f2M = parseNumber(target.getLine(10))

    status["fuel"][1]["level"] = f1L
    status["fuel"][1]["max"] = f1M
    status["fuel"][1]["perc"] = (f1L / f1M)

    status["fuel"][2]["level"] = f2L
    status["fuel"][2]["max"] = f2M
    status["fuel"][2]["perc"] = (f2L / f2M)

    gimbalHandler:Update()

    status["manualcontrols"] = redstoneLinks[manualControlsRLName]:getInput()
    if (not status["manualcontrols"]) then
        altitudeHandler:Update()
        distanceHandler:Update()
        turnDegHandler:Update()
    end
end
}
