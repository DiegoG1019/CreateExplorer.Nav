-- Basically just receive a rednet request and return the requested item from queryable info

print("Initializing AstralNet Module")
local context
local endpoints = {}

local function AddEndpoint(uri, handler)
  if type(uri) ~= "string" then
    error("Invalid URI provided")
  end

  local ht = type(handler)
  if ht ~= "function" and ht ~= "string" and ht ~= "number" and ht ~= "boolean" and ht ~= "table" then
    error("Invalid handler provided")
  end

  local newUri = string.gsub(uri, "%s+", "")
  if(string.len(newUri) ~= string.len(uri)) then error("The provided URI was invalid, as it may not contain whitespace") end

  if (string.len(newUri) == 0) then
    error("The provided URI was invalid, as it may not be empty")
  end

  if endpoints[uri] then 
    error("The URI '"..uri.."' is already registered")
  end

  endpoints[uri] = handler
end

return { 

["Event"] = function(event, sender_id, message, protocol)
  if event == "rednet_message" and sender_id and sender_id ~= os.getComputerID() and protocol == "astralnet-query" and type(message) == "table" then
    
    local uri = message.uri or ""
    local info = endpoints[message.uri]
    if info then
      if type(info) == "function" then
        local resp, code = info(message.body)
        rednet.send(sender_id, { ["body"] = resp, ["code"] = code, ["tstamp"] = os.time() }, "astralnet-query-response")
      end
      
      -- assume primitive
      rednet.send(sender_id, { ["body"] = info, ["code"] = 1, ["tstamp"] = os.time() }, "astralnet-query-response")
    else
      rednet.send(sender_id, nil, "astralnet-query-response")
    end
    
    return true
  end
end,

["PreInit"] = function(ctx)
  context = ctx
  if(type(ctx) ~= "table") then
    error("Invalid context provided")
  end

  context.AstralNet = context.AstralNet or {}
  context.AstralNet.Query = function(uri, message, recipient, timeout)
    rednet.send(recipient, { ["uri"] = uri, ["body"] = message })
    return rednet.receive("astralnet-query-response", timeout)
  end

  context.AstralNet.AddEndpoint = AddEndpoint

end,

["Init"] = function(ctx)
  
  if #endpoints > 0 then  
    context.AstralNet.Endpoints[""] = endpoints
    
    settings.define("astralnet.host", { description = "The hostname of this factory controller", default = nil, type = "string" })
    local hostname = tostring(settings.get("astralnet.host") or "")..":"..os.getComputerID()
    rednet.host("astralnet-query", hostname)
    
    print("Started hosting 'astralnet-query'")
  end
end }
