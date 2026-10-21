-- The thing that actually manages navigation and such

-- Program Settings
local velSZName = "velocity_sensor_1"
local velSXName = "velocity_sensor_2"
local velSYName = "velocity_sensor_3"

local propellerRelayName = "redstone_relay_2"
local liftRL1Name = "back"
local liftRL2Name = "left"
local pushRL1Name = "bottom"
local pushRL2Name = "right"
--local manualControlsRLName = "ManualControls"

local gimbalRelay1Name = "redstone_relay_0"
local gimbalRelay2Name = "redstone_relay_1"

local fuelTank1Name = "create:fluid_tank_0"
local fuelTank2Name = "create_connected:fluid_vessel_0"
local fuelTank1Max = 1152000
local fuelTank2Max = 2232000

--

print("Initializing Prestigious Navigator Module")
require 'lib.MultiRedstone'

local gimbalCorrect1InvertX, gimbalCorrect1InvertZ, gimbalOffsetDeg
local TwoPi = math.pi * 2

local context
local gimbalCorrector
local propellerRelay
local target
local navTable
local gimbalSensor
local altitudeSensor
local velSZ, velSX, velSY
local fuelTank1, fuelTank2

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

local distanceHandler, altitudeHandler, gimbalHandler, turnDegHandler

local status = {
    ["manualcontrols"] = false,
    ["distance"] = {
        ["targetSqr"] = nil,
        ["travelledSqr"] = 0
    },
    ["facingAngle"] = {
        ["currentDegFromNorth"] = 0,
        ["targetDegFromNorth"] = nil
    },
    ["propeller"] ={
        ["liftRpm"] = 0,-- line 1
        ["pushRpm"] = 0,-- line 2
        ["tailDeg"] = 0,-- line 3
        ["tailDegRef"] = 0,-- line 4 -- 90 deg offset from tailDeg sensor, to tell angle direction
        ["tailDegAngle"] = 0,
        ["liftRL1"] = 0,
        ["liftRL2"] = 0,
        ["pushRL1"] = 0,
        ["pushRL2"] = 0,
        ["liftLevel"] = 0,
        ["pushLevel"] = 0
    },
    ["speed"] = {
        ["x"] = 0,
        ["y"] = 0,
        ["z"] = 0
    },
    ["altitude"] = {
        ["target"] = nil,
        ["current"] = 0,
        ["pressure"] = 0
    },
    ["gimbal"] = {
        ["x"] = 0,
        ["z"] = 0,
        ["correctionPX"] = 0,
        ["correctionNX"] = 0,
        ["correctionPZ"] = 0,
        ["correctionNZ"] = 0
    },
    ["fuel"] = {
        {
            ["level"] = 0,
            ["max"] = fuelTank1Max,
            ["perc"] = 0
        },
        {
            ["level"] = 0,
            ["max"] = fuelTank2Max,
            ["perc"] = 0
        }
    }
}

local function parseNumber(str)
    return tonumber(str:match("([0-9]+)") or 0)
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

    settings.define("shipman.gimbalCorrect1ionOffsetDeg", {
        description = "The angular offset (in degrees) of the gimbal correction mechanism relative to north",
        default = 0,
        type = "number",
    })

    gimbalCorrect1InvertX = settings.get("shipman.invertGimbalX")
    gimbalCorrect1InvertZ = settings.get("shipman.invertGimbalZ")
    gimbalOffsetDeg = settings.get("shipman.gimbalCorrect1ionOffsetDeg")

    local cix, ciz, ofd
    if gimbalCorrect1InvertX then cix = "Normal X" else cix = "Inverted X" end
    if gimbalCorrect1InvertZ then ciz = "Normal Z" else ciz = "Inverted Z" end
    ofd = "Offset by "..tostring(gimbalOffsetDeg).." degrees"

    print("Gimbal Correction Settings: "..cix..", "..ciz..", "..ofd)
end,

["Init"] = function(ctx)
    context = ctx
    if(type(ctx) ~= "table") then
        error("Invalid context provided: Expected a 'table', got '"..type(ctx).."'")
    end

    if type(context.AstralNet) ~= "table" then
        error("Could not start Ship Manager: Invalid or non-existent AstralNet context")
    end

    context.AstralNet.AddEndpoint("status", status)

    target = peripheral.find("create_target")
    if not target then error("Could not find create_target peripheral") end

    navTable = peripheral.find("navigation_table")
    if not navTable then error("Could not find navigation_table peripheral") end

    gimbalSensor = peripheral.find("gimbal_sensor")
    if not gimbalSensor then error("Could not find gimbal_sensor peripheral") end

    altitudeSensor = peripheral.find("altitude_sensor")
    if not altitudeSensor then error("Could not find altitude_sensor peripheral") end

    local gimbalRelay1 = peripheral.wrap(gimbalRelay1Name)
    if not gimbalRelay1 then error("Could not find '"..gimbalRelay1Name.."' peripheral for gimbalRelay1") end

    local gimbalRelay2 = peripheral.wrap(gimbalRelay2Name)
    if not gimbalRelay2 then error("Could not find '"..gimbalRelay2Name.."' peripheral for gimbalRelay2") end

    gimbalCorrector = {
        ["PX"] = NewMultiRedstone(
            MultiRedstonePair(gimbalRelay1, "front"), MultiRedstonePair(gimbalRelay2, "front")
        ),
        ["NX"] = NewMultiRedstone(
            MultiRedstonePair(gimbalRelay1, "back"), MultiRedstonePair(gimbalRelay2, "back")
        ),
        ["PZ"] = NewMultiRedstone(
            MultiRedstonePair(gimbalRelay1, "left"), MultiRedstonePair(gimbalRelay2, "left")
        ),
        ["NZ"] = NewMultiRedstone(
            MultiRedstonePair(gimbalRelay1, "right"), MultiRedstonePair(gimbalRelay2, "right")
        )
    }

    propellerRelay = peripheral.wrap(propellerRelayName)
    if not propellerRelay then error("Could not find '"..propellerRelayName.."' peripheral for propellerRelay") end

    fuelTank1 = peripheral.wrap(fuelTank1Name)
    if not fuelTank1 then error("Could not find '"..fuelTank1Name.."' peripheral fuelTank1") end

    fuelTank2 = peripheral.wrap(fuelTank2Name)
    if not fuelTank2 then error("Could not find '"..fuelTank2Name.."' peripheral fuelTank2") end

    velSX = peripheral.wrap(velSXName)
    velSY = peripheral.wrap(velSYName)
    velSZ = peripheral.wrap(velSZName)

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

            if gimbalCorrect1InvertX then x = x * -1 end
            if gimbalCorrect1InvertZ then z = z * -1 end

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
                status["gimbal"]["correctionPX"] = gimbalCorrector["PX"]:Decrement()
                status["gimbal"]["correctionNX"] = gimbalCorrector["NX"]:Increment()
            else
                status["gimbal"]["correctionPX"] = gimbalCorrector["PX"]:Increment()
                status["gimbal"]["correctionNX"] = gimbalCorrector["NX"]:Decrement()
            end

            if (z2 < 0) then
                status["gimbal"]["correctionPZ"] = gimbalCorrector["PZ"]:Decrement()
                status["gimbal"]["correctionNZ"] = gimbalCorrector["NZ"]:Increment()
            else
                status["gimbal"]["correctionPZ"] = gimbalCorrector["PZ"]:Increment()
                status["gimbal"]["correctionNZ"] = gimbalCorrector["NZ"]:Decrement()
            end
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

    local tailDeg, tailDegRef, liftRL1, liftRL2, pushRL1, pushRL2, spdX, spdZ, spdY, f1L, f2L
    status["propeller"]["liftRpm"] = parseNumber(target.getLine(1))
    status["propeller"]["pushRpm"] = parseNumber(target.getLine(2))
    
    --[[ [ Can't get the info yet ]
    -- directional redstone, where 0 is 180deg and 15 is 0deg
    tailDeg = parseNumber(target.getLine(13))
    tailDegRef = parseNumber(target.getLine(14))

    if (tailDeg == 15) then
        status["propeller"]["t"] = 0
    elseif (tailDeg == 0) then
        status["propeller"]["tailDegAngle"] = 180
    else
        local deg = (180 / 15) * tailDeg -- there is a lot of error here, have them as close as possible
        if (tailDegRef < 7) then deg = deg * -1 end
        status["propeller"]["tailDegAngle"] = deg
    end
    ]]

    liftRL1 = propellerRelay:getAnalogInput(liftRL1Name)
    liftRL2 = propellerRelay:getAnalogInput(liftRL2Name)
    pushRL1 = propellerRelay:getAnalogInput(pushRL1Name)
    pushRL2 = propellerRelay:getAnalogInput(pushRL2Name)

    status["propeller"]["liftRL1"] = liftRL1
    status["propeller"]["liftRL2"] = liftRL2
    status["propeller"]["pushRL1"] = pushRL1
    status["propeller"]["pushRL2"] = pushRL2
    status["propeller"]["liftLevel"] = (liftRL1 + liftRL2) / 30;
    status["propeller"]["pushLevel"] = (pushRL1 + pushRL2) / 30;

    spdX = velSX:getVelocity()
    spdZ = velSZ:getVelocity()
    spdY = velSY:getVelocity()

    status["speed"]["x"] = spdX
    status["speed"]["z"] = spdZ
    status["speed"]["y"] = spdY

    local travelledSqr = status["distance"]["travelledSqr"]

    status["distance"]["travelledSqr"] = travelledSqr + (((spdX * spdX) + (spdZ * spdZ)) * delta)
    status["facingAngle"]["currentDegFromNorth"] = (360 - navTable.getRelativeAngle() + 270) % 360

    status["altitude"]["current"] = altitudeSensor:getHeight()
    status["altitude"]["pressure"] = altitudeSensor:getAirPressure()

    local gimbal = gimbalSensor:getAngles()
    status["gimbal"]["x"] = gimbal[1]
    status["gimbal"]["z"] = gimbal[2]

    f1L = fuelTank1:tanks()[1].amount
    f2L = fuelTank2:tanks()[1].amount

    status["fuel"][1]["level"] = f1L
    status["fuel"][1]["perc"] = (f1L / fuelTank1Max)

    status["fuel"][2]["level"] = f2L
    status["fuel"][2]["perc"] = (f2L / fuelTank2Max)

    gimbalHandler:Update()

    --status["manualcontrols"] = redstoneLinks[manualControlsRLName]:getInput()
    --if (not status["manualcontrols"]) then
        altitudeHandler:Update()
        distanceHandler:Update()
        turnDegHandler:Update()
    --end
end
}
