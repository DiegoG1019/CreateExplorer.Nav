local function dumpError(msg)
  local dump = assert(fs.open("error.log", "a"))
  dump.write(msg)
  dump.close()
end

local sharedEnvironment = {
  System = {
    UpdateChecks = 0
  }
}

do

  local hasFailed = settings.get("starstream.failed")

  if not hasFailed and not StarStreamHasInit then
    StarStreamHasInit = true

    local success = pcall(require, 'starstream.startup.lua')
    if success then return end

    -- not success
    settings.set("starstream.failed", true)
    settings.save()
  end

  if hasFailed then
    print("Defaulting to original startup.lua as previous one failed")
  end

end

settings.define("astralrunner.repoUser", {
  description = "The user who owns the repository to search",
  type = "string",
  default = "DiegoG1019"
})
settings.define("astralrunner.repoName", {
  description = "The name of the repository to search",
  type = "string",
  default = nil
})

local modules = {}
local repoUser = settings.get("astralrunner.repoUser")
local repoName = settings.get("astralrunner.repoName") or error("astralrunner.repoName is not set")
local ghDownloadAddr = "https://raw.githubusercontent.com/"..repoUser.."/"..repoName.."/refs/heads/main/"
local ghQueryAddr = "https://api.github.com/repos/"..repoUser.."/"..repoName.."/git/trees/main?recursive=true"

local json = require 'json'

function string.starts(String,Start)
   return string.sub(String,1,string.len(Start)) == Start
end

local function getFilesRecursively(path, tab)
  path = path or ""
  tab = tab or {}

  local pendingDirs = {}
  for i,v in ipairs(path) do
    if fs.isDir(v) then
      table.insert(pendingDirs, path.."/"..v)
    else
      table.insert(tab, path.."/"..v, true)
    end
  end

  for i,v in ipairs(pendingDirs) do
    getFilesRecursively(v, tab)
  end

  return tab;
end

local function inner_update(silent)

  local function update_print(str)
    if not silent then print(str) end
  end

  local manifest;
	local manifestFile = fs.open("manifest.json", "r")
	if not manifestFile then
		manifest = {}
	else
    manifest = json.decode(manifestFile.readAll())
    manifestFile.close()
  end

	local r, statusMsg = http.get(ghQueryAddr)
  if not r then
    update_print("Failed to GET from "..ghQueryAddr..": "..statusMsg)
    return false
  end

	local contents = json.decode(r.readAll());
  r.close();

	if not contents.tree or #(contents.tree) == 0 then return false end

  for i,v in ipairs(contents.tree) do
    if v.path == "startup.lua" then v.path = "starstream.startup.lua"; v.dlpath = "startup.lua" end
  end

  update_print("Parsed git tree info")

  local pendingDownload = {}

  local pendingDeletion = {}
  getFilesRecursively(pendingDeletion)

  update_print("Iterating over git tree")
	for i,v in ipairs(contents.tree) do
    pendingDeletion[v.path] = nil
    update_print("Removed file "..v.path.." from deletion")

		if v.path ~= "LICENSE" and not string.starts(v.path, ".") then

			if not manifest[v.path] or v.sha ~= manifest[v.path] then
        manifest[v.path] = v.sha
        if not v.size then
          if not fs.isDir(v.path) then
            fs.makeDir(v.path)
          end
        else
          table.insert(pendingDownload, v)
        end
      end
		end
	end

  if (#pendingDownload == 0) and (#pendingDeletion == 0) then return false end

  update_print("Deleting upstream-removed files")
  for k,v in pairs(pendingDeletion) do
    if v == true then
      update_print("Deleting file" ..k)
      fs.delete(k)
    end
  end

  update_print("Downloading outdated files")
  for i,v in ipairs(pendingDownload) do
    update_print("Downloading file "..v.path)
    local response, statusStr = http.get(ghDownloadAddr..(v.dlpath or v.path))
    if not response then
      print("ERROR: Could not get file "..v.path.." :"..statusStr)
    else
      local downfile = assert(fs.open(v.path, "w"))
      downfile.write(response.readAll())
      downfile.close()
      response.close()
    end
  end

  update_print("Updating manifest")
  manifestFile = assert(fs.open("manifest.json", "w"))
  manifestFile.write(json.encode(manifest))
  manifestFile.close()

  return true
end

local function update(silent)

  sharedEnvironment.System.UpdateChecks = sharedEnvironment.System.UpdateChecks + 1
  local function update_print(str)
    if not silent then print(str) end
  end

  if (not silent) then
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.clear()
  end

  update_print("Updating...")
  local r = inner_update(silent)

  if r then
    update_print("Updated!")
    os.reboot()
  end

  update_print("No updates found")
end

local function dumpError(msg)
  local dump = assert(fs.open("error.log", "w"))
  dump.write(msg)
  dump.close()
end

local function loadModules()

  print("Loading Modules")

  local moduleInfo = {}

  table.insert(moduleInfo, require 'modules.astralnet')
  table.insert(moduleInfo, require 'modules.ui')

  local awaitingInit = {}
  local updating, listening = 0, 0

  for i,v in ipairs(moduleInfo) do
    if type(v) ~= "table" then
        error("Failed to initiate module "..tostring(i))
    end

    local moduleFunc, modulePreInitFunc, moduleInitFunc, moduleUpdateFunc

    moduleFunc, modulePreInitFunc, moduleInitFunc, moduleUpdateFunc = v["Event"], v["PreInit"], v["Init"], v["Update"]

    if type(modulePreInitFunc) == "function" then
      local success, retval = xpcall(modulePreInitFunc, debug.traceback, sharedEnvironment)
      if not success then
        dumpError(tostring(retval))
        error("Failed to initialize a module")
      end
    end

    local moduleTab = nil;

    if type(moduleFunc) == "function" then
      moduleTab = moduleTab or {}
      moduleTab.event = moduleFunc
      listening = listening + 1
    end

    if type(moduleUpdateFunc) == "function" then
      moduleTab = moduleTab or {}
      moduleTab.update = moduleUpdateFunc
      updating = updating + 1
    end

    if moduleTab then
      table.insert(modules, moduleTab)
    end

    if type(moduleInitFunc) == "function" then
      table.insert(awaitingInit, moduleInitFunc)
    end

  end

  print("Registered "..#modules.." modules, "..listening.." listening, and "..updating.." updating")

  print("Initializing "..#awaitingInit.." modules")

  for i,v in ipairs(awaitingInit) do
    local success, retval = xpcall(v, debug.traceback, sharedEnvironment)
    if not success then
      dumpError(tostring(success)..":::"..tostring(retval))
      error("Failed to load a module")
    end
  end

  print("Initialized modules")
  os.sleep(2)
end

settings.define("disableUpdates", {
  ["description"] = "True if this instance should skip trying to update entirely, false otherwise",
  ["default"] = false,
  ["type"] = "boolean"
})

if (not settings.get("disableUpdates")) then
  update()
end

loadModules()

local updateTimerId = os.startTimer(60)
local refreshTimerId = os.startTimer(0.05)

local lastClock = os.clock()
local delta = 0

while true do
  local event = { os.pullEvent() }

  delta = os.clock() - lastClock
  lastClock = os.clock()

  if event[1] == "timer" then
    if updateTimerId == event[2] then
      updateTimerId = os.startTimer(60)
      --if (not settings.get("disableUpdates")) then
        update(true)
        refreshTimerId = os.startTimer(0.05)
        goto continue
      --end

    elseif refreshTimerId == event[2] then
      refreshTimerId = os.startTimer(0.05)

      for i,v in ipairs(modules) do
        if v.update then
          local success, retval = pcall(v.update, delta)
          if success ~= true then
            dumpError(tostring(retval))
            print(tostring(retval))
            goto continue
          end
        end
      end
    end
  end

  for i,v in ipairs(modules) do
    if v.event then
      local success, retval = pcall(v.event, unpack(event))
        if success ~= true then
          dumpError(tostring(retval))
          print(tostring(retval))
          goto continue
        end
        if retval == true then goto continue end
      end
    end
  ::continue::
end
