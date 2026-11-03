-- Main (Server Script, ServerScriptService)
-- Put ScriptFixer, Sandbox, and vLuau in ServerScriptService next
-- to this script, as ModuleScripts with exactly those names.
-- vLuau itself needs two child ModuleScripts: Fiu and Ception.
-- This script owns the RemoteEvents, the per-player sandboxes,
-- and the world. It never trusts the client to create anything.
--
-- v13 run path: Execute -> ScriptFixer (FE conversion) ->
-- Sandbox.run, which compiles the fixed source with vLuau
-- (LuauCeption compiler + Fiu bytecode VM) and runs it in a
-- per-player sandbox env. There is no hand-written parser any
-- more, so the whole Luau language works. Sandbox also watches
-- asset properties on script-created instances and, when the
-- content provider fails one, repairs it through AssetService
-- (see Sandbox.lua); repair reports arrive on AssetRepairReport
-- and the client appends them to the status bar.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Fixer = require(script.Parent:WaitForChild("ScriptFixer"))
local Sandbox = require(script.Parent:WaitForChild("Sandbox"))

local function getOrCreateRemote(name)
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then return existing end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = ReplicatedStorage
	return remote
end

local ExecuteScript = getOrCreateRemote("ExecuteScript")
local ScriptOutput = getOrCreateRemote("ScriptOutput")
local ClearScripts = getOrCreateRemote("ClearScripts")
local FetchScriptLink = getOrCreateRemote("FetchScriptLink")
local ConvertScript = getOrCreateRemote("ConvertScript")
local ConvertResult = getOrCreateRemote("ConvertResult")
local AssetRepairReport = getOrCreateRemote("AssetRepairReport")

-- World ----------------------------------------------------------------------

local function buildWorld()
	if workspace:FindFirstChild("Baseplate") then return end

	local baseplate = Instance.new("Part")
	baseplate.Name = "Baseplate"
	baseplate.Size = Vector3.new(512, 2, 512)
	baseplate.Position = Vector3.new(0, -1, 0)
	baseplate.Anchored = true
	baseplate.Material = Enum.Material.Grass
	baseplate.Color = Color3.fromRGB(88, 148, 66)
	baseplate.Parent = workspace

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "SpawnLocation"
	spawn.Size = Vector3.new(8, 1, 8)
	spawn.Position = Vector3.new(0, 0.5, 0)
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Parent = workspace

	local function makeTree(x, z, scale)
		scale = scale or 1
		local trunkHeight = 10 * scale
		local trunk = Instance.new("Part")
		trunk.Name = "Trunk"
		trunk.Shape = Enum.PartType.Cylinder
		trunk.Size = Vector3.new(2 * scale, trunkHeight, 2 * scale)
		-- Cylinder parts are tall along X, so rotate to stand upright.
		trunk.CFrame = CFrame.new(x, trunkHeight / 2, z) * CFrame.Angles(0, 0, math.rad(90))
		trunk.Anchored = true
		trunk.Material = Enum.Material.Wood
		trunk.Color = Color3.fromRGB(110, 70, 35)
		trunk.Parent = workspace

		local leafSizes = { 10 * scale, 8 * scale, 6 * scale }
		for i, size in ipairs(leafSizes) do
			local leaf = Instance.new("Part")
			leaf.Name = "Leaves"
			leaf.Shape = Enum.PartType.Ball
			leaf.Size = Vector3.new(size, size, size)
			leaf.Position = Vector3.new(x, trunkHeight + (i - 1) * (3.5 * scale), z)
			leaf.Anchored = true
			leaf.Material = Enum.Material.Grass
			leaf.Color = Color3.fromRGB(45, 110, 45)
			leaf.Parent = workspace
		end
	end

	makeTree(-40, -30, 1.0)
	makeTree(35, -45, 1.2)
	makeTree(-70, 20, 0.9)
	makeTree(60, 35, 1.1)
	makeTree(-25, 70, 1.0)
	makeTree(80, -10, 1.3)
	makeTree(-90, -60, 1.0)
	makeTree(20, -85, 0.9)
end

buildWorld()

-- Per-player sandbox state ----------------------------------------------------

local playersState = {}

local function getState(player)
	local state = playersState[player.UserId]
	if not state then
		local folder = Instance.new("Folder")
		folder.Name = "ScriptBuilder_" .. player.Name
		folder.Parent = workspace
		state = {
			created = {},
			connections = {},
			output = {},
			folder = folder,
			lastExecute = 0,
			uploads = {},
			runId = 0,
			player = player,
		}
		playersState[player.UserId] = state
	end
	return state
end

local function clearPlayerBuilds(player)
	local state = playersState[player.UserId]
	if not state then return 0 end
	-- Stop running script threads: the Sandbox task wrappers
	-- check runId and die on their next wait.
	state.runId = (state.runId or 0) + 1
	local count = 0
	for _, conn in ipairs(state.connections) do
		pcall(function() conn:Disconnect() end)
	end
	state.connections = {}
	if state.casBindings then
		for _, bindings in pairs(state.casBindings) do
			for _, conn in ipairs(bindings) do
				pcall(function() conn:Disconnect() end)
			end
		end
		state.casBindings = {}
	end
	for _, inst in ipairs(state.created) do
		if inst then
			if inst.Parent ~= nil then count = count + 1 end
			-- Destroy even parentless tracked instances: the
			-- Heartbeat relay is parentless, and Clear Builds
			-- must destroy it so the handlers connected to it
			-- die with it. Destroying an already-destroyed
			-- instance is a safe no-op under pcall.
			pcall(function() inst:Destroy() end)
		end
	end
	state.created = {}
	state.scriptChildren = {}
	state.charProxies = nil
	state.proxyReal = nil
	-- v16 sandbox state: _G/shared tables and service
	-- placeholders are rebuilt fresh on the next run.
	state.sharedTables = nil
	state.servicePlaceholders = nil
	-- v16.1: bin relays point at BindableEvents destroyed
	-- above, so drop them too; a stale relay must never
	-- fire select() after Clear.
	state.binRelays = nil
	state.binRelayLast = nil
	if state.folder then
		for _, child in ipairs(state.folder:GetChildren()) do
			pcall(function() child:Destroy() end)
		end
	end
	state.output = {}
	return count
end

-- Per-player input ------------------------------------------------------------
-- Mouse and keys cannot exist on the server, but they CAN be sent
-- to the server when they happen, and that is what v3 does.
-- One Input RemoteEvent per player, created by the SERVER (a
-- client-created remote would never replicate to the server),
-- in ReplicatedStorage/ScriptBuilderInput_<UserId>/Input.
-- NOT one shared remote for all input: a shared remote would
-- mix every player's keys and mouse moves into one channel, let
-- one player's spam delay another's, and make it easy to spoof
-- someone else's input. Per player, the traffic is isolated,
-- the sender is checked against the remote's owner, and the
-- remote survives respawn, because it is per player, not per
-- character instance. A per-character remote would break every
-- script connection on respawn, which is worse, not better.
local inputRemotes = {}

local function ensureInputRemote(player)
	local folderName = "ScriptBuilderInput_" .. player.UserId
	local folder = ReplicatedStorage:FindFirstChild(folderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = folderName
		folder.Parent = ReplicatedStorage
	end
	local remote = folder:FindFirstChild("Input")
	if not remote or not remote:IsA("RemoteEvent") then
		remote = Instance.new("RemoteEvent")
		remote.Name = "Input"
		remote.Parent = folder
	end
	if inputRemotes[remote] then return remote end
	inputRemotes[remote] = player.UserId
	remote.OnServerEvent:Connect(function(sender, packet)
		-- The remote is per player, so a packet from anyone else
		-- is spoofing, not input, and is dropped.
		if sender.UserId ~= player.UserId then return end
		local state = getState(sender)
		if type(packet) == "table" and packet.type == "bin" then
			Sandbox.applyBinInput(state, packet)
		else
			Sandbox.applyMouseInput(state, packet)
		end
	end)
	return remote
end

Players.PlayerAdded:Connect(function(player)
	ensureInputRemote(player)
end)
for _, player in ipairs(Players:GetPlayers()) do
	ensureInputRemote(player)
end

Players.PlayerRemoving:Connect(function(player)
	clearPlayerBuilds(player)
	local state = playersState[player.UserId]
	if state and state.folder then pcall(function() state.folder:Destroy() end) end
	playersState[player.UserId] = nil
	local folder = ReplicatedStorage:FindFirstChild("ScriptBuilderInput_" .. player.UserId)
	if folder then
		local remote = folder:FindFirstChild("Input")
		if remote then inputRemotes[remote] = nil end
		pcall(function() folder:Destroy() end)
	end
end)

-- Parallel compile worker (v15.5): Ception's compile never
-- yields, so compiling a big script on the main thread freezes
-- the game even inside task.spawn. This worker runs under an
-- Actor, so it compiles on a real worker thread: it requires
-- Ception and the shared queue while still serial, then
-- desynchronizes and answers compile requests from the queue.
-- If anything here fails (Actor unsupported, files missing,
-- worker never starts), Sandbox's compile step times out and
-- falls back to main-thread compile, so a broken worker costs
-- the freeze, never the run.
local COMPILER_WORKER_SOURCE = [==[
local svc = game:GetService("ServerScriptService")
local vluau = svc:WaitForChild("vLuau", 10)
if not vluau then error("ScriptBuilderCompiler: vLuau missing") end
local ceptionMod = vluau:WaitForChild("Ception", 10)
if not ceptionMod then error("ScriptBuilderCompiler: Ception missing") end
local Ception = require(ceptionMod)
local sharedMod = svc:WaitForChild("ScriptBuilderShared", 10)
if not sharedMod then error("ScriptBuilderCompiler: ScriptBuilderShared missing") end
local shared = require(sharedMod)
task.desynchronize()
while true do
	task.wait(0.05)
	if shared.reqBusy and not shared.resDone then
		local ok, res = pcall(Ception.luau_compile, shared.reqSource)
		if not ok then
			shared.resKind = "workerError"
			shared.resError = tostring(res)
			shared.resBytecode = ""
		elseif type(res) == "string" and res:sub(1, 1) == "\0" then
			shared.resKind = "sourceError"
			shared.resError = res:sub(2)
			shared.resBytecode = ""
		else
			shared.resKind = "ok"
			shared.resBytecode = res
			shared.resError = ""
		end
		shared.resDone = true
	end
end
]==]
pcall(function()
	local svc = game:GetService("ServerScriptService")
	if svc:FindFirstChild("ScriptBuilderCompiler") then return end
	local actor = Instance.new("Actor")
	actor.Name = "ScriptBuilderCompiler"
	local worker = Instance.new("Script")
	worker.Name = "CompilerWorker"
	worker.Source = COMPILER_WORKER_SOURCE
	worker.Parent = actor
	actor.Parent = svc
end)

-- Script size: any amount of text, bounded only against runaway
-- uploads. The client pages the editor (500 lines / 50,000 chars
-- per page, never more than that in any one Text property), and
-- splits uploads into 8,192-char chunks. 5,000 chunks is about
-- 41 million characters: far past any real script, but still a
-- bound, so a broken client cannot upload forever.
local CHUNK_SIZE = 8192
local MAX_TOTAL_CHUNKS = 5000
local MAX_TOTAL_CHARS = MAX_TOTAL_CHUNKS * CHUNK_SIZE
local MAX_FETCHED_CHARS = 5000000

local function runScript(player, state, source, fetchedSource, skipRateLimit)
	state.output = {}
	if #source == 0 then
		ScriptOutput:FireClient(player, false, "Nothing to run. Paste a script first.", {}, {}, fetchedSource)
		return
	end
	if not skipRateLimit then
		if os.clock() - state.lastExecute < 1 then
			ScriptOutput:FireClient(player, false, "Slow down a little: wait a second between runs.", {}, {}, fetchedSource)
			return
		end
		state.lastExecute = os.clock()
	end

	local fixed, notes = Fixer.fix(source)

	-- Run in its own thread so compiling (vLuau's compiler takes
	-- a few seconds on a large script) and task.wait() in user
	-- code cannot stall other players' scripts or server events.
	task.spawn(function()
		-- Asset repair reports are debounced in Sandbox and
		-- arrive after the run finished, so they go on their
		-- own remote and the client appends them to the status
		-- bar instead of replacing the "Ran OK" message.
		local function onAssetReport(text)
			AssetRepairReport:FireClient(player, text)
		end
		local ok, err = Sandbox.run(player, state, fixed, onAssetReport)
		if ok then
			ScriptOutput:FireClient(player, true, "Ran OK. " .. #state.created .. " instance(s) tracked for you.", notes, state.output, fetchedSource)
		else
			ScriptOutput:FireClient(player, false, "Error: " .. tostring(err), notes, state.output, fetchedSource)
		end
	end)
end

-- Shared chunked-upload handling for Execute and Convert.
-- Chunks do not count against the 1-second run rate limit; only
-- the completed script does. The timeout is idle-based: every
-- accepted chunk refreshes it, so a large upload that takes
-- longer than 60 seconds total is NOT reset mid-upload, but an
-- abandoned upload (no chunk for 60 seconds) is dropped.
local function handleUpload(player, state, source, onComplete)
	if type(source) == "table" and source.chunkUpload then
		local id = source.id
		local total = source.total
		local index = source.index
		if type(id) ~= "string" or type(total) ~= "number"
			or type(index) ~= "number" or type(source.chunk) ~= "string" then
			return false
		end
		if total < 1 or total > MAX_TOTAL_CHUNKS
			or index < 1 or index > total or #source.chunk > CHUNK_SIZE then
			return false
		end
		state.uploads = state.uploads or {}
		local upload = state.uploads[id]
		if not upload or upload.total ~= total then
			upload = { total = total, parts = {}, received = 0, started = os.clock() }
			state.uploads[id] = upload
		end
		if os.clock() - upload.started > 60 then
			upload = { total = total, parts = {}, received = 0, started = os.clock() }
			state.uploads[id] = upload
		end
		-- Idle timeout refresh: this chunk just arrived.
		upload.started = os.clock()
		if upload.parts[index] == nil then
			upload.parts[index] = source.chunk
			upload.received = upload.received + 1
		end
		if upload.received >= total then
			local pieces = {}
			for i = 1, total do pieces[i] = upload.parts[i] end
			state.uploads[id] = nil
			local assembled = table.concat(pieces)
			if #assembled > MAX_TOTAL_CHARS then
				ScriptOutput:FireClient(player, false, "Script is too long.", {}, {})
				return true
			end
			onComplete(assembled)
		end
		return true
	end
	return false
end

ExecuteScript.OnServerEvent:Connect(function(player, source)
	local state = getState(player)
	if handleUpload(player, state, source, function(assembled)
		runScript(player, state, assembled, nil, false)
	end) then return end
	if type(source) ~= "string" then
		ScriptOutput:FireClient(player, false, "Expected script text.", {}, {})
		return
	end
	runScript(player, state, source, nil, false)
end)

ClearScripts.OnServerEvent:Connect(function(player)
	local count = clearPlayerBuilds(player)
	ScriptOutput:FireClient(player, true, "Cleared " .. count .. " build(s).", {}, {})
end)

-- Link fetch: the client sends a URL, the SERVER fetches it
-- (user scripts never touch HttpService themselves), and the
-- fetched source is both loaded into the editor (via the 5th
-- ScriptOutput argument) and run through the normal path.
FetchScriptLink.OnServerEvent:Connect(function(player, url)
	local state = getState(player)
	if type(url) ~= "string" or (url:sub(1, 7) ~= "http://" and url:sub(1, 8) ~= "https://") then
		ScriptOutput:FireClient(player, false, "That is not an http(s) link.", {}, {})
		return
	end
	if os.clock() - state.lastExecute < 1 then
		ScriptOutput:FireClient(player, false, "Slow down a little: wait a second between runs.", {}, {})
		return
	end
	state.lastExecute = os.clock()
	local ok, body = pcall(function()
		return HttpService:GetAsync(url, true)
	end)
	if not ok then
		ScriptOutput:FireClient(player, false, "Could not fetch that link: " .. tostring(body) .. " (If HTTP is off, turn it on in Game Settings > Security > Allow HTTP Requests, then try again.)", {}, {})
		return
	end
	if #body > MAX_FETCHED_CHARS then
		ScriptOutput:FireClient(player, false, "Fetched script is too long (" .. #body .. " characters, max " .. MAX_FETCHED_CHARS .. ").", {}, {})
		return
	end
	runScript(player, state, body, body, true)
end)

-- Convert: run ScriptFixer over the editor text and send the
-- converted source back, without running it. This is the
-- FE-off -> FE-on conversion as a product: paste an old script,
-- press Convert, and the editor now holds the converted version
-- (LocalPlayer -> player, :connect -> :Connect, wait ->
-- task.wait, old method spellings -> canonical ones), ready to
-- copy out or run.
ConvertScript.OnServerEvent:Connect(function(player, source)
	local state = getState(player)
	if handleUpload(player, state, source, function(assembled)
		local fixed, notes = Fixer.fix(assembled)
		ConvertResult:FireClient(player, fixed, notes)
	end) then return end
	if type(source) ~= "string" then
		ScriptOutput:FireClient(player, false, "Expected script text.", {}, {})
		return
	end
	local fixed, notes = Fixer.fix(source)
	ConvertResult:FireClient(player, fixed, notes)
end)

print("[ScriptBuilder] Server ready (v13, vLuau + AssetService). ExecuteScript / ScriptOutput / ClearScripts / FetchScriptLink / ConvertScript / ConvertResult / AssetRepairReport in ReplicatedStorage, plus one ScriptBuilderInput_<UserId>/Input remote per player.")
