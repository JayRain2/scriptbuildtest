-- Sandbox (ModuleScript, ServerScriptService)
-- v12: the runner is no longer a hand-written tree-walking
-- interpreter. It is vLuau: a real Luau compiler (LuauCeption)
-- plus a real Luau bytecode VM (Fiu), both written in Luau and
-- running inside Roblox. That is why v12 supports the whole
-- language, not just the subset the old parser happened to
-- implement: compound assignment (+=, -=, *=, /=, ..=), continue,
-- string interpolation (`...{x}...`), type annotations (stripped
-- by the compiler), generalized iteration, if-expressions, and
-- every other Luau construct Ception accepts. The old parser's
-- failures (parenthesised suffixes like ((a - b).magnitude),
-- varargs edge cases, comma assignments) are gone because there
-- is no old parser any more.
--
-- The sandbox is the env table handed to vLuau. Fiu resolves
-- globals ONLY from that table (plus the empty extensions table),
-- so anything not listed here is nil inside a user script.
-- Deliberately absent: getfenv/setfenv from the host (those would
-- leak the real server environment), debug, loadstring, require,
-- io, package, HttpService, DataStoreService, and every other
-- service that could reach outside this place. User code runs
-- with normal server-script power over THIS place (it can create
-- parts, change Lighting, and so on - that is the point of a
-- script builder), but it cannot read Main, Sandbox, or vLuau,
-- cannot create Script/ModuleScript objects with Instance.new,
-- and cannot reach the network or datastores. Two deliberate
-- exceptions, both needed by real FE-era scripts: RemoteEvent /
-- RemoteFunction creation IS allowed (client code made by NLS
-- needs remotes to talk to the server), and NLS(source, parent)
-- creates a real LocalScript for client code (see env.NLS).
--
-- Conversion (the FE fix) still happens before compile, in
-- ScriptFixer: LocalPlayer -> player, :connect -> :Connect,
-- bare wait/spawn/delay -> task.*, old method spellings ->
-- canonical ones, and so on. On top of that, this module adds
-- the two conversions a compiler alone cannot do:
--   1. Mouse/keys: the client forwards real input over the
--      per-player Input remote (v3), and this module turns it
--      into real BindableEvent signals on an emulated mouse
--      object, plus a UserInputService proxy.
--   2. R6 -> R15: a character with no Torso is wrapped in a
--      proxy that answers Torso / "Left Arm" / etc. with the
--      matching UpperTorso / LeftUpperArm / etc. instance.
--      A character that DOES have a Torso (R6) is returned
--      unwrapped, so == comparisons against it keep working.
--      Known limit of the proxy: hit.Parent == Character will
--      not match for an R15 character, because a table proxy
--      can never equal a real Instance under ==. Compare
--      .Name, or use FindFirstChild("Humanoid"), instead.

local Sandbox = {}

local vLuau = require(script.Parent:WaitForChild("vLuau"))
local ScriptFixer = require(script.Parent:WaitForChild("ScriptFixer"))
local Players = game:GetService("Players")
local AssetService = game:GetService("AssetService")
local ContentProvider = game:GetService("ContentProvider")

--------------------------------------------------------------------------------
-- Instance allow-list (same set the old interpreter allowed)
--------------------------------------------------------------------------------

local ALLOWED_CLASSES = {}
for _, c in ipairs({
	"Part", "Model", "Folder", "MeshPart", "WedgePart", "CornerWedgePart",
	"SpawnLocation", "Seat", "VehicleSeat", "PointLight", "SpotLight",
	"SurfaceLight", "Decal", "Texture", "SpecialMesh", "BlockMesh",
	"CylinderMesh", "BillboardGui", "SurfaceGui", "TextLabel", "TextButton",
	"Frame", "ImageLabel", "Sound", "ParticleEmitter", "Fire", "Smoke",
	"Sparkles", "Beam", "Attachment", "StringValue", "IntValue", "NumberValue",
	"BoolValue", "ObjectValue", "BodyVelocity", "BodyGyro", "BodyPosition",
	"Weld", "ManualWeld", "Motor6D", "Sky", "CharacterMesh",
	"Shirt", "Pants", "BindableEvent", "Hat", "Accessory",
	"ScreenGui", "ImageButton", "TextBox", "ScrollingFrame",
	"RemoteEvent", "RemoteFunction",
	"ViewportFrame", "CanvasGroup", "UIListLayout", "UIGridLayout",
	"UIPadding", "UICorner", "UIStroke", "UIAspectRatioConstraint",
	"Animation", "Tool", "Trail", "Highlight", "BodyColors",
	"ShirtGraphic", "Snap", "BindableFunction", "Configuration",
	"BodyAngularVelocity", "BodyForce", "BodyThrust",
	"RocketPropulsion", "SelectionBox", "SelectionSphere",
	"SoundGroup", "WeldConstraint", "UnionOperation",
	"AnimationController", "HumanoidDescription",
	"Message", "Hint", "ForceField",
	"BallSocketConstraint", "HingeConstraint", "AlignPosition",
	"AlignOrientation", "VectorForce", "LinearVelocity",
	"PitchShiftSoundEffect", "EqualizerSoundEffect",
	"EchoSoundEffect", "ReverbSoundEffect", "CompressorSoundEffect",
	"DistortionSoundEffect", "FlangerSoundEffect", "TremoloSoundEffect",
	"Explosion", "HopperBin", "Motor",
	"Glue", "Humanoid", "Vector3Value",
	"ColorCorrectionEffect", "Color3Value",
}) do ALLOWED_CLASSES[c] = true end

local BLOCKED_CLASSES = {
	Script = true, LocalScript = true, ModuleScript = true,
}

--------------------------------------------------------------------------------
-- R6 -> R15 limb map (Upper first, Lower as fallback)
--------------------------------------------------------------------------------

local R6_MAP = {
	Torso = { "UpperTorso", "LowerTorso" },
	["Left Arm"] = { "LeftUpperArm", "LeftLowerArm" },
	["Right Arm"] = { "RightUpperArm", "RightLowerArm" },
	["Left Leg"] = { "LeftUpperLeg", "LeftLowerLeg" },
	["Right Leg"] = { "RightUpperLeg", "RightLowerLeg" },
}

--------------------------------------------------------------------------------
-- Mouse / input state (per player, owned by Main's state table)
--------------------------------------------------------------------------------

local MOUSE_SIGNALS = {
	"KeyDown", "KeyUp", "Button1Down", "Button1Up",
	"Button2Down", "Button2Up", "Move", "Idle",
	"WheelForward", "WheelBackward",
}

local function ensureMouse(state)
	if state.mouseEvents then return end
	local events = {}
	for _, name in ipairs(MOUSE_SIGNALS) do
		local ev = Instance.new("BindableEvent")
		events[name] = ev
	end
	state.mouseEvents = events
	state.mouseState = {
		hit = CFrame.new(0, 10, 0),
		target = nil,
		x = 0, y = 0,
		viewSizeX = 0, viewSizeY = 0,
		unitRay = Ray.new(Vector3.new(0, 0, 0), Vector3.new(0, 0, -1)),
	}
	state.downKeys = {}
	local uis = {}
	for _, name in ipairs({ "InputBegan", "InputEnded", "InputChanged" }) do
		uis[name] = Instance.new("BindableEvent")
	end
	state.uisEvents = uis
end

local KEYCODE_MAP = {}
for _, name in ipairs({
	"A","B","C","D","E","F","G","H","I","J","K","L","M",
	"N","O","P","Q","R","S","T","U","V","W","X","Y","Z",
}) do KEYCODE_MAP[string.lower(name)] = Enum.KeyCode[name] end
-- Digits are named, not numbered, in Enum.KeyCode: there is
-- no "0" member, which is why the old loop errored on i = 0.
-- Indexing an Enum with a bad name throws, so the old `or`
-- fallback never ran.
local DIGIT_NAMES = { "Zero", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine" }
for i = 0, 9 do KEYCODE_MAP[tostring(i)] = Enum.KeyCode[DIGIT_NAMES[i + 1]] end
KEYCODE_MAP[" "] = Enum.KeyCode.Space
KEYCODE_MAP["-"] = Enum.KeyCode.Minus
KEYCODE_MAP["="] = Enum.KeyCode.Equals

local function fakeInput(state, keyString, inputType, inputState, position, delta)
	local keyCode = Enum.KeyCode.Unknown
	if keyString and KEYCODE_MAP[keyString] then keyCode = KEYCODE_MAP[keyString] end
	return {
		KeyCode = keyCode,
		UserInputType = inputType,
		UserInputState = inputState,
		Position = position or Vector3.new(state.mouseState.x, state.mouseState.y, 0),
		Delta = delta or Vector3.new(0, 0, 0),
	}
end

-- Called by Main when a packet arrives on the player's Input
-- remote. Updates the emulated mouse state, then fires the real
-- BindableEvent signals old scripts listen to.
function Sandbox.applyMouseInput(state, packet)
	ensureMouse(state)
	if type(packet) ~= "table" then return end
	local ms = state.mouseState
	if packet.type == "mouse" then
		if packet.hit ~= nil then ms.hit = packet.hit end
		if packet.target ~= nil then ms.target = packet.target end
		if packet.x ~= nil then ms.x = packet.x end
		if packet.y ~= nil then ms.y = packet.y end
		if packet.viewSizeX ~= nil then ms.viewSizeX = packet.viewSizeX end
		if packet.viewSizeY ~= nil then ms.viewSizeY = packet.viewSizeY end
		if packet.rayOrigin ~= nil and packet.rayDirection ~= nil then
			ms.unitRay = Ray.new(packet.rayOrigin, packet.rayDirection)
		end
		state.mouseEvents.Move:Fire()
	elseif packet.type == "keyDown" then
		local key = packet.key
		if type(key) == "string" then
			state.downKeys[key] = true
			state.mouseEvents.KeyDown:Fire(key)
			state.uisEvents.InputBegan:Fire(
				fakeInput(state, key, Enum.UserInputType.Keyboard, Enum.UserInputState.Begin),
				false
			)
		end
	elseif packet.type == "keyUp" then
		local key = packet.key
		if type(key) == "string" then
			state.downKeys[key] = nil
			state.mouseEvents.KeyUp:Fire(key)
			state.uisEvents.InputEnded:Fire(
				fakeInput(state, key, Enum.UserInputType.Keyboard, Enum.UserInputState.End),
				false
			)
		end
	elseif packet.type == "button1Down" then
		state.mouseEvents.Button1Down:Fire()
		state.uisEvents.InputBegan:Fire(
			fakeInput(state, nil, Enum.UserInputType.MouseButton1, Enum.UserInputState.Begin),
			false
		)
	elseif packet.type == "button1Up" then
		state.mouseEvents.Button1Up:Fire()
		state.uisEvents.InputEnded:Fire(
			fakeInput(state, nil, Enum.UserInputType.MouseButton1, Enum.UserInputState.End),
			false
		)
	elseif packet.type == "button2Down" then
		state.mouseEvents.Button2Down:Fire()
		state.uisEvents.InputBegan:Fire(
			fakeInput(state, nil, Enum.UserInputType.MouseButton2, Enum.UserInputState.Begin),
			false
		)
	elseif packet.type == "button2Up" then
		state.mouseEvents.Button2Up:Fire()
		state.uisEvents.InputEnded:Fire(
			fakeInput(state, nil, Enum.UserInputType.MouseButton2, Enum.UserInputState.End),
			false
		)
	elseif packet.type == "wheelForward" then
		state.mouseEvents.WheelForward:Fire()
		state.uisEvents.InputChanged:Fire(
			fakeInput(state, nil, Enum.UserInputType.MouseWheel, Enum.UserInputState.Change,
				nil, Vector3.new(0, 0, 1)),
			false
		)
	elseif packet.type == "wheelBackward" then
		state.mouseEvents.WheelBackward:Fire()
		state.uisEvents.InputChanged:Fire(
			fakeInput(state, nil, Enum.UserInputType.MouseWheel, Enum.UserInputState.Change,
				nil, Vector3.new(0, 0, -1)),
			false
		)
	end
end

--------------------------------------------------------------------------------
-- Proxies
--------------------------------------------------------------------------------

-- Unwrap helper: character proxies and script-parented values are
-- tables; real Roblox APIs need the real Instance underneath.
local function unwrap(value, state)
	if type(value) == "table" and state and state.proxyReal then
		local real = state.proxyReal[value]
		if real then return real end
	end
	return value
end

local function makeCharacterProxy(state, char)
	-- R6 characters already have a Torso: return them unwrapped,
	-- so == comparisons and every other identity check work.
	if char:FindFirstChild("Torso") then return char end
	if state.charProxies and state.charProxies[char] then
		return state.charProxies[char]
	end
	local proxy = {}
	state.charProxies = state.charProxies or {}
	state.proxyReal = state.proxyReal or {}
	state.charProxies[char] = proxy
	state.proxyReal[proxy] = char
	local mt = {}
	mt.__index = function(_, key)
		if R6_MAP[key] then
			for _, candidate in ipairs(R6_MAP[key]) do
				local found = char:FindFirstChild(candidate)
				if found then return found end
			end
			return nil
		end
		if key == "FindFirstChild" then
			return function(_, name, recursive)
				local found = char:FindFirstChild(name, recursive)
				if found then return found end
				if R6_MAP[name] then
					for _, candidate in ipairs(R6_MAP[name]) do
						found = char:FindFirstChild(candidate, recursive)
						if found then return found end
					end
				end
				return nil
			end
		end
		if key == "WaitForChild" then
			return function(_, name, timeout)
				local found = char:WaitForChild(name, timeout)
				if found then return found end
				if R6_MAP[name] then
					for _, candidate in ipairs(R6_MAP[name]) do
						found = char:FindFirstChild(candidate)
						if found then return found end
					end
				end
				return nil
			end
		end
		local value = char[key]
		if type(value) == "function" then
			return function(_, ...)
				return value(char, ...)
			end
		end
		return value
	end
	mt.__newindex = function(_, key, value)
		char[key] = value
	end
	-- Best effort only: Luau does not call __eq when the other
	-- side is a real Instance, so == against the real character
	-- still fails for R15. Table-vs-table comparisons do use it.
	mt.__eq = function(left, right)
		local l = state.proxyReal[left] or left
		local r = state.proxyReal[right] or right
		return l == r
	end
	setmetatable(proxy, mt)
	return proxy
end

local function makeScriptProxy(state)
	local proxy = { __isScriptProxy = true, Name = "UserScript", ClassName = "Script" }
	state.scriptChildren = state.scriptChildren or {}
	local mt = {}
	mt.__index = function(_, key)
		if key == "Parent" then return state.folder end
		if key == "WaitForChild" then
			return function(_, name, timeout)
				if state.scriptChildren[name] then return state.scriptChildren[name] end
				return state.folder:WaitForChild(name, timeout)
			end
		end
		if key == "FindFirstChild" then
			return function(_, name)
				return state.scriptChildren[name] or state.folder:FindFirstChild(name)
			end
		end
		if state.scriptChildren[key] then return state.scriptChildren[key] end
		return state.folder:FindFirstChild(key)
	end
	mt.__newindex = function(_, key, value)
		if key == "Parent" then return end
		rawset(proxy, key, value)
	end
	setmetatable(proxy, mt)
	return proxy
end

--------------------------------------------------------------------------------
-- Assets via AssetService (v13)
--------------------------------------------------------------------------------
-- Why this exists: Roblox's default content handler errors on
-- assets the experience is not authorised for, assets that are
-- archived, and assets that are not approved for the requester
-- ("ContentId: rbxassetid://... failed due to: ..."). Turning
-- on Game Settings > Security > Allow Loading Third Party
-- Assets enables AssetService APIs to fetch assets the place
-- does not own, but it does NOT change the default handler:
-- a SpecialMesh.MeshId or Decal.Texture still goes through
-- the content provider and still fails. So this layer watches
-- every asset property on every instance a script creates, and
-- when the content provider reports Failure for one, it
-- re-fetches that asset through AssetService and displays it
-- through a path AssetService can serve:
--   MeshPart.MeshId      -> MeshContent from an EditableMesh
--   SpecialMesh.MeshId   -> a follower MeshPart (from
--                           AssetService) welded to the
--                           original part, with the original
--                           part hidden (a Part with a failed
--                           mesh would otherwise render as a
--                           plain block next to the mesh)
--   ImageLabel/Image     -> ImageContent from an EditableImage
--   Decal/Texture        -> a SurfaceGui + ImageLabel with
--                           ImageContent on the same face,
--                           with the original decal hidden
-- Sounds, clothing templates, mesh textures, and particle
-- textures have no Content-type property, so AssetService
-- cannot display them another way: those are reported as
-- unrepairable instead of silently failing. Archived assets
-- cannot be repaired by anyone, AssetService included: if
-- CreateEditableMeshAsync / CreateEditableImageAsync also
-- fails, the report says so plainly.
-- Nothing here runs for assets that load fine: the repair
-- only triggers on a confirmed PreloadAsync Failure, so a
-- working asset is never duplicated.

-- Forward declarations: repair, watching, and tracked creation
-- call each other, so they are declared here and assigned below.
local scheduleAssetCheck
local repairAsset
local createTrackedInstance
local connectAssetWatchers

-- "rbxassetid://123", "http://www.roblox.com/asset/?id=123",
-- a bare number, or a numeric string -> the numeric id plus a
-- canonical content string. Anything else (built-in
-- rbxasset:// paths, empty strings, non-numeric junk) -> nil.
local function parseAssetId(value)
	if type(value) == "number" then
		if value > 0 then return value, "rbxassetid://" .. tostring(value) end
		return nil
	end
	if type(value) ~= "string" or value == "" then return nil end
	local id = value:match("^rbxassetid://(%d+)$")
		or value:match("[?&]id=(%d+)")
		or value:match("^(%d+)$")
	if id then
		local num = tonumber(id)
		if num and num > 0 then return num, "rbxassetid://" .. id end
	end
	return nil
end

-- Which (class, property) pairs are watched, and what kind of
-- repair they get. "report" means: watch it so the failure is
-- reported clearly, but there is no AssetService display path.
local function assetKind(className, property)
	if property == "MeshId" then
		if className == "MeshPart" then return "meshPart" end
		if className == "SpecialMesh" or className == "BlockMesh"
			or className == "CylinderMesh" then return "specialMesh" end
	elseif property == "TextureId" then
		if className == "SpecialMesh" or className == "BlockMesh"
			or className == "CylinderMesh" then return "report" end
	elseif property == "TextureID" then
		if className == "MeshPart" then return "report" end
	elseif property == "Texture" then
		if className == "Decal" or className == "Texture" then return "decal" end
		if className == "ParticleEmitter" then return "report" end
	elseif property == "Image" then
		if className == "ImageLabel" or className == "ImageButton" then return "guiImage" end
	elseif property == "SoundId" then
		if className == "Sound" then return "report" end
	elseif property == "ShirtTemplate" then
		if className == "Shirt" then return "report" end
	elseif property == "PantsTemplate" then
		if className == "Pants" then return "report" end
	end
	return nil
end

local WATCHED_PROPERTIES = {
	"MeshId", "TextureId", "TextureID", "Texture",
	"Image", "SoundId", "ShirtTemplate", "PantsTemplate",
}

-- Debounced repair reporting: repairs finish asynchronously
-- (preload + AssetService calls), so results are collected and
-- sent as one message ~1.5 seconds after the last result, via
-- the report function Main stores in state (AssetRepairReport).
-- They also print to the server console, so they are visible
-- even if the client status bar has moved on.
local function reportRepair(state, text)
	print("[ScriptBuilder][Assets] " .. text)
	state.assetRepairLog = state.assetRepairLog or {}
	state.assetRepairLog[#state.assetRepairLog + 1] = text
	if state.assetReportFn and not state.assetReportScheduled then
		state.assetReportScheduled = true
		task.delay(1.5, function()
			state.assetReportScheduled = false
			local log = state.assetRepairLog or {}
			state.assetRepairLog = {}
			if #log > 0 and state.assetReportFn then
				state.assetReportFn(table.concat(log, "\n"))
			end
		end)
	end
end

-- The tracked Instance.new: allow-list, 1000 limit, script
-- parenting, and asset watching. Used by user scripts (through
-- the env) and by the repair code itself (follower MeshParts,
-- SurfaceGuis), so repaired objects are also cleared by
-- Clear Builds and counted against the same limit.
createTrackedInstance = function(state, className, parent, allowBlocked)
	if type(className) ~= "string" then
		error("Instance.new expects a string class name", 0)
	end
	if not allowBlocked and BLOCKED_CLASSES[className] then
		error("Instance.new(" .. className .. ") is not allowed in the sandbox", 0)
	end
	if className == "Motor" then className = "Motor6D" end
	if className == "Glue" then className = "Weld" end
	if not allowBlocked and not ALLOWED_CLASSES[className] then
		error("Instance.new(" .. className .. ") is not allowed in the sandbox", 0)
	end
	if #state.created >= 1000 then
		error("Script hit the 1000 instance limit for one player (press Clear Builds to reset it)", 0)
	end
	local inst = Instance.new(className)
	state.created[#state.created + 1] = inst
	if parent ~= nil then
		if type(parent) == "table" and parent.__isScriptProxy then
			inst.Parent = state.folder
			if inst.Name then state.scriptChildren[inst.Name] = inst end
		else
			inst.Parent = unwrap(parent, state)
		end
	end
	connectAssetWatchers(state, inst)
	return inst
end

connectAssetWatchers = function(state, inst)
	local className
	local okClass = pcall(function() className = inst.ClassName end)
	if not okClass or not className then return end
	for _, property in ipairs(WATCHED_PROPERTIES) do
		if assetKind(className, property) then
			local okConn, conn = pcall(function()
				return inst:GetPropertyChangedSignal(property):Connect(function()
					scheduleAssetCheck(state, inst, property)
				end)
			end)
			if okConn and conn then
				state.connections[#state.connections + 1] = conn
			end
		end
	end
end

scheduleAssetCheck = function(state, inst, property)
	local okValue, value = pcall(function() return inst[property] end)
	if not okValue then return end
	local id, contentId = parseAssetId(value)
	if not id then return end
	state.assetChecked = state.assetChecked or {}
	state.assetChecked[inst] = state.assetChecked[inst] or {}
	if state.assetChecked[inst][property] == id then return end
	state.assetChecked[inst][property] = id
	local className = inst.ClassName
	local kind = assetKind(className, property)
	if not kind then return end
	task.spawn(function()
		-- PreloadAsync yields until the asset loads or fails,
		-- and calls back with (contentId, AssetFetchStatus).
		-- Only a confirmed Failure triggers a repair, so a
		-- working asset is never duplicated.
		local okPreload = pcall(function()
			ContentProvider:PreloadAsync({ contentId }, function(_, status)
				if status == Enum.AssetFetchStatus.Failure
					or status == Enum.AssetFetchStatus.TimedOut then
					task.spawn(function()
						repairAsset(state, inst, property, kind, id, contentId)
					end)
				end
			end)
		end)
		if not okPreload then
			-- Preload itself errored (bad id shape, service
			-- unavailable): leave the default behaviour alone
			-- rather than guessing at a repair.
			return
		end
	end)
end

repairAsset = function(state, inst, property, kind, id, contentId)
	local className = inst.ClassName
	if kind == "meshPart" then
		local okEdit, editable = pcall(function()
			return AssetService:CreateEditableMeshAsync(Content.fromUri(contentId))
		end)
		if not okEdit or not editable then
			reportRepair(state, "Asset " .. id .. " (" .. className .. ".MeshId) failed to load and AssetService could not fetch it either (it may be archived, private, or not a mesh).")
			return
		end
		local okSet = pcall(function()
			inst.MeshContent = Content.fromObject(editable)
		end)
		if not okSet then
			reportRepair(state, "Asset " .. id .. " (" .. className .. ".MeshId) failed to load and this client does not support MeshContent, so it could not be repaired.")
			return
		end
		pcall(function() inst.MeshId = "" end)
		reportRepair(state, "Asset " .. id .. " (" .. className .. ".MeshId) failed to load, repaired via AssetService (EditableMesh -> MeshContent).")
		return
	end
	if kind == "specialMesh" then
		local part = nil
		pcall(function() part = inst.Parent end)
		if not part or not part:IsA("BasePart") or part.Parent == nil then
			reportRepair(state, "Asset " .. id .. " (" .. className .. ".MeshId) failed to load, but its mesh is not on a part in the world, so no follower mesh could be placed.")
			return
		end
		-- AssetService creates the replacement mesh part. If
		-- that fails, fall back to an EditableMesh on a plain
		-- MeshPart; if both fail, the asset is unrecoverable.
		local meshPart = nil
		local okCreate = pcall(function()
			meshPart = AssetService:CreateMeshPartAsync(Content.fromUri(contentId))
		end)
		if not okCreate or not meshPart then
			local okEdit, editable = pcall(function()
				return AssetService:CreateEditableMeshAsync(Content.fromUri(contentId))
			end)
			if okEdit and editable then
				local okNew = pcall(function()
					meshPart = createTrackedInstance(state, "MeshPart", part.Parent)
					meshPart.MeshContent = Content.fromObject(editable)
				end)
				if not okNew or not meshPart then meshPart = nil end
			end
		end
		if not meshPart then
			reportRepair(state, "Asset " .. id .. " (" .. className .. ".MeshId) failed to load and AssetService could not fetch it either (it may be archived, private, or not a mesh).")
			return
		end
		-- Match the original part's placement and the mesh's
		-- scale, then weld the follower to the original part
		-- so it follows every move and animation the script
		-- makes to that part. The original part is hidden:
		-- with a working mesh a Part renders as the mesh, not
		-- as a block, so leaving the block visible would show
		-- both. The original mesh id is cleared so a late
		-- load cannot duplicate the follower.
		local scale = Vector3.new(1, 1, 1)
		pcall(function() scale = inst.Scale end)
		local okPlace = pcall(function()
			meshPart.CFrame = part.CFrame
			meshPart.Size = Vector3.new(
				part.Size.X * scale.X,
				part.Size.Y * scale.Y,
				part.Size.Z * scale.Z
			)
			meshPart.Anchored = false
			meshPart.CanCollide = false
			meshPart.Material = part.Material
			meshPart.Color = part.Color
			meshPart.Transparency = part.Transparency
			meshPart.Parent = part.Parent
			local weld = createTrackedInstance(state, "Weld", meshPart)
			weld.Part0 = part
			weld.Part1 = meshPart
			weld.C0 = CFrame.new()
			weld.C1 = CFrame.new()
		end)
		if not okPlace then
			pcall(function() meshPart:Destroy() end)
			reportRepair(state, "Asset " .. id .. " (" .. className .. ".MeshId) fetched via AssetService, but placing the follower mesh failed.")
			return
		end
		pcall(function()
			part.Transparency = 1
			part.CanCollide = false
		end)
		pcall(function() inst.MeshId = "" end)
		pcall(function()
			local conn = part.Destroying:Connect(function()
				pcall(function() meshPart:Destroy() end)
			end)
			state.connections[#state.connections + 1] = conn
		end)
		reportRepair(state, "Asset " .. id .. " (" .. className .. ".MeshId) failed to load, repaired via AssetService (follower MeshPart welded to '" .. part.Name .. "').")
		return
	end
	if kind == "guiImage" then
		local okEdit, editable = pcall(function()
			return AssetService:CreateEditableImageAsync(Content.fromUri(contentId))
		end)
		if not okEdit or not editable then
			reportRepair(state, "Asset " .. id .. " (" .. className .. ".Image) failed to load and AssetService could not fetch it either (it may be archived, private, or not an image).")
			return
		end
		local okSet = pcall(function()
			inst.ImageContent = Content.fromObject(editable)
		end)
		if not okSet then
			reportRepair(state, "Asset " .. id .. " (" .. className .. ".Image) failed to load and this client does not support ImageContent, so it could not be repaired.")
			return
		end
		pcall(function() inst.Image = "" end)
		reportRepair(state, "Asset " .. id .. " (" .. className .. ".Image) failed to load, repaired via AssetService (EditableImage -> ImageContent).")
		return
	end
	if kind == "decal" then
		local part = nil
		pcall(function() part = inst.Parent end)
		if not part or not part:IsA("BasePart") or part.Parent == nil then
			reportRepair(state, "Asset " .. id .. " (" .. className .. ".Texture) failed to load, but it is not on a part in the world, so no replacement image could be placed.")
			return
		end
		local okEdit, editable = pcall(function()
			return AssetService:CreateEditableImageAsync(Content.fromUri(contentId))
		end)
		if not okEdit or not editable then
			reportRepair(state, "Asset " .. id .. " (" .. className .. ".Texture) failed to load and AssetService could not fetch it either (it may be archived, private, or not an image).")
			return
		end
		local surfaceGui = nil
		local okGui = pcall(function()
			surfaceGui = createTrackedInstance(state, "SurfaceGui", part)
			surfaceGui.Face = inst.Face
			local label = createTrackedInstance(state, "ImageLabel", surfaceGui)
			label.Size = UDim2.new(1, 0, 1, 0)
			label.BackgroundTransparency = 1
			label.BorderSizePixel = 0
			label.ImageTransparency = inst.Transparency or 0
			label.ImageContent = Content.fromObject(editable)
		end)
		if not okGui or not surfaceGui then
			reportRepair(state, "Asset " .. id .. " (" .. className .. ".Texture) fetched via AssetService, but placing the replacement image failed.")
			return
		end
		pcall(function() inst.Transparency = 1 end)
		reportRepair(state, "Asset " .. id .. " (" .. className .. ".Texture) failed to load, repaired via AssetService (SurfaceGui image on the same face).")
		return
	end
	-- "report" kind: sounds, clothing, mesh textures, particle
	-- textures. There is no Content-type property for these, so
	-- AssetService cannot display them another way.
	reportRepair(state, "Asset " .. id .. " (" .. className .. "." .. property .. ") failed to load and has no AssetService repair path (sounds, clothing, and mesh textures cannot be replaced through AssetService; the asset may also be archived, private, or not approved).")
end

-- Manual trigger for instances a script did NOT create (for
-- example, clothing on an existing character): scripts can call
-- fixAsset(instance, "ShirtTemplate") and the same check runs.
-- It reports, but for report-only kinds it still cannot repair.
function Sandbox.fixAsset(state, inst, property)
	if typeof(inst) ~= "Instance" or type(property) ~= "string" then return end
	if not assetKind(inst.ClassName, property) then return end
	scheduleAssetCheck(state, inst, property)
end

--------------------------------------------------------------------------------
-- Env construction
--------------------------------------------------------------------------------

local function buildEnv(player, state, runId)
	ensureMouse(state)
	local realPlayer = player

	local function printToClient(prefix, ...)
		local args = table.pack(...)
		local parts = {}
		for i = 1, args.n do parts[#parts + 1] = tostring(args[i]) end
		local line = prefix .. table.concat(parts, " ")
		state.output[#state.output + 1] = line
		print("[ScriptBuilder][" .. realPlayer.Name .. "] " .. line)
	end

	-- Stop-on-Clear / stop-on-rerun: a task.wait wrapper that
	-- dies when a newer run (or Clear Builds) bumps runId, so a
	-- looping animation thread cannot outlive its build.
	local function guardedWait(seconds)
		if state.runId ~= runId then error("Script stopped (new run or Clear Builds)", 0) end
		local result = task.wait(seconds)
		if state.runId ~= runId then error("Script stopped (new run or Clear Builds)", 0) end
		return result
	end
	local function guardedSpawn(fn, ...)
		local args = table.pack(...)
		task.spawn(function()
			if state.runId ~= runId then return end
			fn(table.unpack(args, 1, args.n))
		end)
	end
	local function guardedDelay(seconds, fn, ...)
		local args = table.pack(...)
		task.delay(seconds, function()
			if state.runId ~= runId then return end
			fn(table.unpack(args, 1, args.n))
		end)
	end

	local taskEnv = {
		wait = guardedWait,
		spawn = guardedSpawn,
		delay = guardedDelay,
		defer = guardedSpawn,
		cancel = task.cancel,
	}

	-- Emulated mouse object: properties read live state, signals
	-- are the real BindableEvent signals from applyMouseInput.
	local mouseObject = {}
	do
		local mt = {}
		mt.__index = function(_, key)
			if state.mouseEvents[key] then
				return state.mouseEvents[key].Event
			end
			local ms = state.mouseState
			if key == "Hit" then return ms.hit end
			if key == "Target" then return ms.target end
			if key == "X" then return ms.x end
			if key == "Y" then return ms.y end
			if key == "ViewSizeX" then return ms.viewSizeX end
			if key == "ViewSizeY" then return ms.viewSizeY end
			if key == "UnitRay" then return ms.unitRay end
			return nil
		end
		mt.__newindex = function() end -- mouse properties are read-only to scripts
		setmetatable(mouseObject, mt)
	end

	local scriptProxy = makeScriptProxy(state)

	local function characterProxy()
		local char = realPlayer.Character
		if not char then return nil end
		return makeCharacterProxy(state, char)
	end

	local localPlayerProxy = {}
	do
		local mt = {}
		mt.__index = function(_, key)
			if key == "GetMouse" then
				return function() return mouseObject end
			end
			if key == "Character" then
				return characterProxy()
			end
			return realPlayer[key]
		end
		mt.__newindex = function(_, key, value)
			realPlayer[key] = value
		end
		setmetatable(localPlayerProxy, mt)
	end

	-- The LocalPlayer proxy is a table, like the R15 character
	-- proxies, so it must be registered here: __sbUnwrap maps
	-- it back to the real Player when a script hands it to the
	-- engine (see the PlayerToHideFrom fix in ScriptFixer).
	state.proxyReal = state.proxyReal or {}
	state.proxyReal[localPlayerProxy] = realPlayer

	local runService = game:GetService("RunService")
	local runServiceProxy = {
		Heartbeat = runService.Heartbeat,
		Stepped = runService.Heartbeat,
		RenderStepped = runService.Heartbeat,
		IsStudio = function() return runService:IsStudio() end,
		IsServer = function() return true end,
		IsClient = function() return false end,
		BindToRenderStep = function(_, name, priority, fn)
			return runService.Heartbeat:Connect(fn)
		end,
		UnbindFromRenderStep = function() end,
	}

	local userInputProxy = {
		InputBegan = state.uisEvents.InputBegan.Event,
		InputEnded = state.uisEvents.InputEnded.Event,
		InputChanged = state.uisEvents.InputChanged.Event,
		GetFocusedTextBox = function() return nil end,
		IsKeyDown = function(_, keyCode)
			local name
			if type(keyCode) == "string" then
				name = keyCode
			elseif typeof(keyCode) == "EnumItem" then
				name = keyCode.Name
			else
				return false
			end
			return state.downKeys[string.lower(name)] == true
		end,
	}

	local playersProxy = {
		LocalPlayer = localPlayerProxy,
		localPlayer = localPlayerProxy,
		GetPlayers = function() return Players:GetPlayers() end,
		GetPlayerByUserId = function(_, id) return Players:GetPlayerByUserId(id) end,
		GetPlayerFromCharacter = function(_, character)
			return Players:GetPlayerFromCharacter(unwrap(character, state))
		end,
		PlayerAdded = Players.PlayerAdded,
		PlayerRemoving = Players.PlayerRemoving,
	}

	-- InsertService proxy: user code calls :LoadAsset(id) the
	-- way old FE scripts did, but the load goes through
	-- AssetService, and anything it returns is tracked and
	-- watched like any script-created instance. A non-numeric
	-- argument errors instead of silently doing nothing.
	local insertProxy = {}
	insertProxy.LoadAsset = function(_, assetId)
		local id = nil
		if type(assetId) == "number" then
			id = assetId
		elseif type(assetId) == "string" then
			id = tonumber(assetId) or tonumber(assetId:match("[?&]id=(%d+)"))
		end
		if not id or id <= 0 then
			error("InsertService:LoadAsset expects a numeric asset id", 0)
		end
		local ok, model = pcall(function()
			return AssetService:LoadAssetAsync(id)
		end)
		if not ok or not model then
			error("InsertService:LoadAsset failed for asset " .. tostring(id) .. " (archived, private, or not approved)", 0)
		end
		state.created[#state.created + 1] = model
		local function watchTree(inst)
			connectAssetWatchers(state, inst)
			for _, child in ipairs(inst:GetChildren()) do
				watchTree(child)
			end
		end
		watchTree(model)
		return model
	end

	-- AssetService proxy: only the fetch paths a script can
	-- legitimately use. CreatePlaceAsync and the rest are
	-- deliberately absent, same as in the old allow-list.
	local assetProxy = {}
	assetProxy.LoadAssetAsync = function(_, assetId)
		return AssetService:LoadAssetAsync(assetId)
	end
	assetProxy.CreateEditableMeshAsync = function(_, content, options)
		return AssetService:CreateEditableMeshAsync(content, options)
	end
	assetProxy.CreateEditableImageAsync = function(_, content, options)
		return AssetService:CreateEditableImageAsync(content, options)
	end
	assetProxy.CreateMeshPartAsync = function(_, content, options)
		return AssetService:CreateMeshPartAsync(content, options)
	end
	assetProxy.CreateDecalAsync = function(_, content)
		return AssetService:CreateDecalAsync(content)
	end
	assetProxy.CreateTextureAsync = function(_, content)
		return AssetService:CreateTextureAsync(content)
	end

	local function getService(_, name)
		local allowed = {
			Workspace = workspace,
			Players = playersProxy,
			Lighting = game:GetService("Lighting"),
			ReplicatedStorage = game:GetService("ReplicatedStorage"),
			Chat = game:GetService("Chat"),
			Debris = game:GetService("Debris"),
			RunService = runServiceProxy,
			TweenService = game:GetService("TweenService"),
			SoundService = game:GetService("SoundService"),
			StarterGui = game:GetService("StarterGui"),
			StarterPack = game:GetService("StarterPack"),
			Teams = game:GetService("Teams"),
			UserInputService = userInputProxy,
			ContextActionService = nil, -- see below
			TextService = game:GetService("TextService"),
			CollectionService = game:GetService("CollectionService"),
			ServerStorage = game:GetService("ServerStorage"),
			InsertService = insertProxy,
			AssetService = assetProxy,
			ContentProvider = ContentProvider,
			ReplicatedFirst = game:GetService("ReplicatedFirst"),
			LogService = game:GetService("LogService"),
		}
		if name == "ContextActionService" then
			-- BindAction handlers run through the same Input
			-- remote as UserInputService: a Begin/End pair per
			-- key, with the action name first.
			local cas = {}
			state.casBindings = state.casBindings or {}
			cas.BindAction = function(_, actionName, fn, createTouchButton, ...)
				local keys = table.pack(...)
				local function matches(input)
					for i = 1, keys.n do
						local bound = keys[i]
						if bound == input.KeyCode then return true end
						if type(bound) == "string" and typeof(input.KeyCode) == "EnumItem"
							and string.lower(bound) == string.lower(input.KeyCode.Name) then
							return true
						end
					end
					return false
				end
				local function handler(input, gameProcessed)
					if not matches(input) then return end
					if input.UserInputState == Enum.UserInputState.Begin then
						fn(actionName, Enum.UserInputState.Begin, input)
					elseif input.UserInputState == Enum.UserInputState.End then
						fn(actionName, Enum.UserInputState.End, input)
					end
				end
				local connBegin = state.uisEvents.InputBegan.Event:Connect(handler)
				local connEnd = state.uisEvents.InputEnded.Event:Connect(handler)
				state.casBindings[actionName] = { connBegin, connEnd }
			end
			cas.UnbindAction = function(_, actionName)
				local bindings = state.casBindings and state.casBindings[actionName]
				if bindings then
					for _, conn in ipairs(bindings) do pcall(function() conn:Disconnect() end) end
					state.casBindings[actionName] = nil
				end
			end
			cas.UnbindAllActions = function()
				if state.casBindings then
					for _, bindings in pairs(state.casBindings) do
						for _, conn in ipairs(bindings) do pcall(function() conn:Disconnect() end) end
					end
					state.casBindings = {}
				end
			end
			return cas
		end
		if allowed[name] then return allowed[name] end
		error("GetService(" .. tostring(name) .. ") is not allowed in the sandbox", 0)
	end

	local gameProxy = {
		Workspace = workspace,
		Players = playersProxy,
		Lighting = game:GetService("Lighting"),
		Chat = game:GetService("Chat"),
		Debris = game:GetService("Debris"),
		RunService = runServiceProxy,
		InsertService = insertProxy,
		AssetService = assetProxy,
		ContentProvider = ContentProvider,
		ReplicatedFirst = game:GetService("ReplicatedFirst"),
		LogService = game:GetService("LogService"),
		ReplicatedStorage = game:GetService("ReplicatedStorage"),
		PlaceId = game.PlaceId,
		GetService = getService,
		service = getService,
	}

	local function instanceNew(className, parent)
		return createTrackedInstance(state, className, parent)
	end

	-- The env itself: a plain table, no metatable fallback, so
	-- anything not listed here is nil inside user code.
	local env = {}
	env.print = function(...) printToClient("", ...) end
	env.warn = function(...) printToClient("[warn] ", ...) end
	env.pairs = pairs
	env.ipairs = ipairs
	env.next = next
	env.pcall = pcall
	env.xpcall = xpcall
	env.select = select
	env.tostring = tostring
	env.tonumber = tonumber
	env.type = type
	env.typeof = typeof
	env.error = error
	env.assert = assert
	env.rawequal = rawequal
	env.rawget = rawget
	env.rawset = rawset
	env.setmetatable = setmetatable
	env.getmetatable = getmetatable
	env.unpack = table.unpack
	env.tick = os.clock
	env.time = os.clock
	env.elapsedTime = elapsedTime
	env.wait = guardedWait
	env.spawn = guardedSpawn
	env.delay = guardedDelay
	env.Spawn = guardedSpawn
	env.Delay = guardedDelay
	env.math = math
	env.string = string
	env.table = table
	env.coroutine = coroutine
	env.bit32 = bit32
	env.utf8 = utf8
	env.buffer = buffer
	env.vector = vector
	env.task = taskEnv
	env.os = { clock = os.clock, time = os.time, date = os.date, difftime = os.difftime }
	env.newproxy = function(withMeta)
		local proxy = {}
		if withMeta then
			local mt = {}
			setmetatable(proxy, mt)
		end
		return proxy
	end
	-- Safe getfenv: returns this sandbox env, never the host env.
	-- A host getfenv here would leak Main's real environment.
	env.getfenv = function() return env end
	env.setfenv = function(fn) return fn end
	env.game = gameProxy
	env.workspace = workspace
	env.Workspace = workspace
	env.player = localPlayerProxy
	env.script = scriptProxy
	env.Instance = { new = instanceNew }
	env.Content = Content
	-- NLS: the old script-builder helper for client code.
	-- NLS(source, parent) creates a real LocalScript from source,
	-- parented to parent (default: the player's Backpack), and
	-- returns it. The client runs it for real: a LocalScript
	-- inside a Tool in Backpack, or in PlayerGui, Backpack, or
	-- Character, executes on that player's client. The source
	-- goes through the client-safe Fixer pass first (old method
	-- spellings -> canonical), but NOT the server-side
	-- conversions (LocalPlayer stays LocalPlayer on the client)
	-- and NOT the proxy unwrap pass (the client has no
	-- __sbUnwrap). The LocalScript is tracked like any other
	-- created instance, so Clear Builds removes it.
	env.NLS = function(source, parent)
		if type(source) ~= "string" then
			error("NLS expects a string of client code, got " .. type(source), 0)
		end
		if #source >= 200000 then
			error("NLS source is " .. #source .. " chars, over the 200000-char Source limit for one script", 0)
		end
		local fixedClient = ScriptFixer.fixClientSource(source)
		local targetParent
		if parent == nil then
			targetParent = player.Backpack
		else
			targetParent = unwrap(parent, state)
		end
		local ls = createTrackedInstance(state, "LocalScript", nil, true)
		ls.Source = fixedClient
		ls.Parent = targetParent
		return ls
	end
	env.fixAsset = function(inst, property)
		Sandbox.fixAsset(state, inst, property)
	end
	-- __sbUnwrap: maps a sandbox proxy table back to the real
	-- Instance it stands for, and passes everything else
	-- through unchanged. ScriptFixer wraps assignments to
	-- Instance-typed properties in this (see its
	-- PlayerToHideFrom note): the engine rejects a table
	-- where it wants an Instance, and LocalPlayer / R15
	-- characters / script are tables inside the sandbox.
	env.__sbUnwrap = function(v)
		if type(v) == "table" then
			if state.proxyReal and state.proxyReal[v] then
				return state.proxyReal[v]
			end
			if v.__isScriptProxy then
				return state.folder
			end
		end
		return v
	end
	-- ypcall: the yieldable pcall old exploit-era scripts
	-- expect. Luau's pcall supports yielding, unlike Lua
	-- 5.1's, so plain pcall is the correct stand-in here.
	env.ypcall = pcall
	-- loadstring/load: compile through the same vLuau engine,
	-- into this same sandbox env, with its own step budget.
	-- Returns the function, or nil + an error message, like
	-- the real one. This is how old scripts' Script Tab and
	-- Explorer panels ran nested code; it is no more powerful
	-- than running the outer script, because the env it
	-- compiles into is this sandbox.
	local function loadstringImpl(source, chunkName)
		if type(source) ~= "string" then
			error("loadstring expects a string", 0)
		end
		local settings = vLuau.create_settings()
		settings.generalizedIteration = true
		local hooks = 0
		local windowStart = os.clock()
		settings.callHooks.interruptHook = function()
			hooks = hooks + 1
			local now = os.clock()
			if now - windowStart > 30 then
				windowStart = now
				hooks = 0
			elseif hooks > 2000000 then
				error("Script hit the run limit (infinite loop protection)", 0)
			end
		end
		local ok, fn = pcall(vLuau.luau_execute, source, env, chunkName or "loadstring", settings)
		if not ok then return nil, tostring(fn) end
		return fn
	end
	env.loadstring = loadstringImpl
	env.load = loadstringImpl
	env.Vector3 = Vector3
	env.Vector2 = Vector2
	env.CFrame = CFrame
	env.BrickColor = BrickColor
	env.Color3 = Color3
	env.UDim = UDim
	env.UDim2 = UDim2
	env.Enum = Enum
	env.Ray = Ray
	env.Rect = Rect
	env.NumberRange = NumberRange
	env.NumberSequence = NumberSequence
	env.NumberSequenceKeypoint = NumberSequenceKeypoint
	env.ColorSequence = ColorSequence
	env.ColorSequenceKeypoint = ColorSequenceKeypoint
	env.PhysicalProperties = PhysicalProperties
	env.TweenInfo = TweenInfo
	env.Random = Random
	env.Region3 = Region3
	env.RaycastParams = RaycastParams
	env.OverlapParams = OverlapParams
	env.Axes = Axes
	env.Faces = Faces
	env.Font = Font
	env.DateTime = DateTime
	return env
end

--------------------------------------------------------------------------------
-- Run
--------------------------------------------------------------------------------

-- Compiles and runs one fixed script for one player. Returns
-- ok, err. Print output lands in state.output; created
-- instances land in state.created (Main reports both).
function Sandbox.run(player, state, fixedSource, reportFn)
	state.runId = (state.runId or 0) + 1
	state.assetReportFn = reportFn
	state.assetChecked = {}
	state.assetRepairLog = {}
	state.assetReportScheduled = false
	local runId = state.runId
	local env = buildEnv(player, state, runId)

	-- Step budget via Fiu's interrupt hook, which fires on loop
	-- back-edges, calls, and returns. A tight infinite loop
	-- burns through the budget in under a second; a script
	-- that yields (task.wait, Heartbeat handlers) resets its
	-- window every 30 seconds, so a legit animation loop that
	-- runs for minutes is never killed for merely existing.
	local hooks = 0
	local windowStart = os.clock()
	local settings = vLuau.create_settings()
	settings.generalizedIteration = true
	settings.callHooks.interruptHook = function()
		hooks = hooks + 1
		local now = os.clock()
		if now - windowStart > 30 then
			windowStart = now
			hooks = 0
		elseif hooks > 2000000 then
			error("Script hit the run limit (infinite loop protection)", 0)
		end
	end

	local ok, fn = pcall(vLuau.luau_execute, fixedSource, env, "ScriptBuilder", settings)
	if not ok then
		return false, tostring(fn)
	end
	local ranOk, runErr = pcall(fn)
	if not ranOk then
		return false, tostring(runErr)
	end
	return true, nil
end

return Sandbox
