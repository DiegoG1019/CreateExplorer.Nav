---@class MultiRedstonePair
---@field peripheral table
---@field side string

---@class MultiRedstone
---@field Pairs MultiRedstonePair[]
---@field CurrentValue number
---@field Increment function
---@field Decrement function

---@param val integer
---@return integer
---@return integer
local function getIndexAndValue(val)
  local idx = math.floor(val / 15)
  return idx + 1, val - (idx * 15)
end

---@param self MultiRedstone
---@return integer
local function getMaxLevel(self)
    return #(self.Pairs) * 15;
end

---@param self MultiRedstone
local function Apply(self)
    local idx, val = getIndexAndValue(self.CurrentValue)

    if (idx > #self.Pairs) then
        for i,v in ipairs(self.Pairs) do
            v.peripheral:setAnlogOutput(15)
        end
    else
        for i = 1, idx, 1 do
            self.Pairs[i].peripheral:setAnlogOutput(15)
        end

        self.Pairs[idx].peripheral:setAnlogOutput(val)
    end
    
end

---@param self MultiRedstone
local function incrementMultiRedstone(self)
    self.CurrentValue = math.min(getMaxLevel(self), self.CurrentValue + 1)
    Apply(self)
    return self.CurrentValue
end

local function decrementMultiRedstone(self)
    self.CurrentValue = math.max(0, self.CurrentValue - 1)
    Apply(self)
    return self.CurrentValue
end

function MultiRedstonePair(peripheral, side)
    if (type(peripheral) ~= "table") then
        error("Unexpected type for value 'peripheral', expected 'table', got '"..type(peripheral).."'")
    end

    if (type(side) ~= "string") then
        error("Unexpected type for value 'side', expected 'string', got '"..type(side).."'")
    end

    return { ["peripheral"] = peripheral, ["side"] = side }
end

---@param ... MultiRedstonePair
---@return MultiRedstone
function NewMultiRedstone(...)
    local p = { ... }

    local obj = {
        Pairs = p,
        CurrentValue = 0,
        Decrement = decrementMultiRedstone,
        Increment = incrementMultiRedstone
    }

    for i,v in ipairs(p) do
        v.peripheral.setAnalogOutput(v.side, 0)
    end

    return obj
end
