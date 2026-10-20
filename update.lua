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

local modules = {}
local repoUser = "DiegoG1019"
local repoName = "CreateAstral.StarStream"
local ghDownloadAddr = "https://raw.githubusercontent.com/"..repoUser.."/"..repoName.."/refs/heads/main/"
local ghQueryAddr = "https://api.github.com/repos/"..repoUser.."/"..repoName.."/git/trees/main?recursive=true"

StarStream = {}
StarStream.queryableInfo = {}

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

  local function update_print(str)
    if not silent then print(str) end
  end

  update_print("Updating...")
  local r = inner_update(silent)
  
  if r then 
    update_print("Updated!")
    os.reboot()
  end
  
  update_print("No updates found")
  os.sleep(2)
end

local function dumpError(msg)
  local dump = assert(fs.open("error.log", "w"))
  dump.write(msg)
  dump.close()
end

local function loadModules()
  
  print("Loading Modules")
  local moduleInfo = {}
  
  table.insert(moduleInfo, { require 'modules.astralnet' })
  table.insert(moduleInfo, { require 'modules.factory' })
  table.insert(moduleInfo, { require 'modules.ui' })
  
  local awaitingInit = {}
  
  for i,v in ipairs(moduleInfo) do
    
    local moduleFunc, moduleInitFunc = v[1], v[2]
    
    if type(moduleFunc) == "table" then
      moduleInitFunc = moduleFunc[2]
      moduleFunc = moduleFunc[1]
    end
    
    if type(moduleFunc) == "function" then
      table.insert(modules, moduleFunc)
    end
    
    if type(moduleInitFunc) == "function" then
      table.insert(awaitingInit, moduleInitFunc)
    end
  end
  
  print("Registered "..#modules.." module listeners")
  
  print("Initializing "..#awaitingInit.." modules")
  
  for i,v in ipairs(awaitingInit) do
    local success, retval = xpcall(v, debug.traceback)
    if not success then
      dumpError(tostring(success)..":::"..tostring(retval))
      error("Failed to load a module")
    end
  end
  
  print("Initialized modules")
  os.sleep(2)
end

update()
loadModules()

local timerId = os.startTimer(60)

while true do
  local event = { os.pullEvent() }
  
  if event[0] == "alarm" and timerId == event[1] 
  then 
    update(true)
  else
    for i,v in ipairs(modules) do
      local success, retval = pcall(v, unpack(event))
      if retval == true then break end
    end
  end
  
  os.sleep(0.1)
end
