-- ScriptFixer (ModuleScript, ServerScriptService)
-- The "FE fix" layer. It does NOT try to make client code replicate.
-- Instead it normalises old Filtering-Disabled-era source so the
-- server-side interpreter below can run it as-is, on the server,
-- where every Instance it creates replicates to clients for real.
--
-- Why this is the correct fix, not a per-line RemoteEvent rewrite:
--   Old SB: client created a Part -> it replicated instantly (FE off).
--   Modern: client creation does NOT replicate. The only sound fix is
--   to stop creating things on the client at all. The client in this
--   game only sends the *text*. The server interprets it and creates
--   the parts. Replication then happens through Roblox itself, with
--   no RemoteEvent-per-part hack and no desync.

local Fixer = {}

local REPLACEMENTS = {
	-- {pattern, replacement, note, scope} scope is "server" for
	-- conversions that only make sense on the server; the client
	-- pass (fixClientSource, used by NLS) skips those.
	{ "game%.Players%.LocalPlayer", "player", "game.Players.LocalPlayer -> player (server-side owner)", "server" },
	{ "game%.Workspace", "workspace", "game.Workspace -> workspace", "server" },
	{ "game:GetService%(%s*\"Workspace\"%s*%)", "workspace", 'game:GetService("Workspace") -> workspace', "server" },
	{ "game:GetService%(%s*'Workspace'%s*%)", "workspace", "game:GetService('Workspace') -> workspace", "server" },
	{ ":connect%(", ":Connect(", "Old lowercase :connect() -> :Connect()" },
	{ ":disconnect%(", ":Disconnect(", "Old lowercase :disconnect() -> :Disconnect()" },
	-- Old method spellings -> canonical ones. With a real Luau
	-- VM (v12), methods run on real Instances, which are
	-- case-sensitive, so these rewrites replace the old
	-- interpreter's case-insensitive method lookup.
	{ ":clone%(", ":Clone(", "Old :clone() -> :Clone()" },
	{ ":remove%(", ":Destroy(", "Old :remove() -> :Destroy()" },
	{ ":destroy%(", ":Destroy(", "Old :destroy() -> :Destroy()" },
	{ ":findfirstchild%(", ":FindFirstChild(", "Old :findfirstchild() -> :FindFirstChild()" },
	{ ":findFirstChild%(", ":FindFirstChild(", "Old :findFirstChild() -> :FindFirstChild()" },
	{ ":findFirstChildOfClass%(", ":FindFirstChildOfClass(", "Old :findFirstChildOfClass() -> :FindFirstChildOfClass()" },
	{ ":findFirstChildWhichIsA%(", ":FindFirstChildWhichIsA(", "Old :findFirstChildWhichIsA() -> :FindFirstChildWhichIsA()" },
	{ ":getChildren%(", ":GetChildren(", "Old :getChildren() -> :GetChildren()" },
	{ ":children%(", ":GetChildren(", "Old :children() -> :GetChildren()" },
	{ ":getDescendants%(", ":GetDescendants(", "Old :getDescendants() -> :GetDescendants()" },
	{ ":waitforchild%(", ":WaitForChild(", "Old :waitforchild() -> :WaitForChild()" },
	{ ":wait%(", ":Wait(", "Old :wait() -> :Wait()" },
	{ ":breakjoints%(", ":BreakJoints(", "Old :breakjoints() -> :BreakJoints()" },
	{ ":breakJoints%(", ":BreakJoints(", "Old :breakJoints() -> :BreakJoints()" },
	{ ":play%(", ":Play(", "Old :play() -> :Play()" },
	{ ":stop%(", ":Stop(", "Old :stop() -> :Stop()" },
	{ ":pause%(", ":Pause(", "Old :pause() -> :Pause()" },
	{ ":resume%(", ":Resume(", "Old :resume() -> :Resume()" },
	{ ":fire%(", ":Fire(", "Old :fire() -> :Fire()" },
	{ ":loadanimation%(", ":LoadAnimation(", "Old :loadanimation() -> :LoadAnimation()" },
	{ ":adjustspeed%(", ":AdjustSpeed(", "Old :adjustspeed() -> :AdjustSpeed()" },
	{ ":moveto%(", ":MoveTo(", "Old :moveto() -> :MoveTo()" },
	{ ":getplayerfromcharacter%(", ":GetPlayerFromCharacter(", "Old :getplayerfromcharacter() -> :GetPlayerFromCharacter()" },
	{ ":getplayinganimationtracks%(", ":GetPlayingAnimationTracks(", "Old :getplayinganimationtracks() -> :GetPlayingAnimationTracks()" },
	{ ":gettouchingparts%(", ":GetTouchingParts(", "Old :gettouchingparts() -> :GetTouchingParts()" },
	{ ":applyimpulse%(", ":ApplyImpulse(", "Old :applyimpulse() -> :ApplyImpulse()" },
	{ ":getpropertychangedsignal%(", ":GetPropertyChangedSignal(", "Old :getpropertychangedsignal() -> :GetPropertyChangedSignal()" },
	{ ":findfirstdescendant%(", ":FindFirstDescendant(", "Old :findfirstdescendant() -> :FindFirstDescendant()" },
	{ ":getboundingbox%(", ":GetBoundingBox(", "Old :getboundingbox() -> :GetBoundingBox()" },
	{ ":getmass%(", ":GetMass(", "Old :getmass() -> :GetMass()" },
	{ ":getstate%(", ":GetState(", "Old :getstate() -> :GetState()" },
	{ ":changestate%(", ":ChangeState(", "Old :changestate() -> :ChangeState()" },
	{ ":setprimarypartcframe%(", ":SetPrimaryPartCFrame(", "Old :setprimarypartcframe() -> :SetPrimaryPartCFrame()" },
	{ ":pivoto%(", ":PivotTo(", "Old :pivoto() -> :PivotTo()" },
	{ ":clearcharacterappearance%(", ":ClearCharacterAppearance(", "Old :clearcharacterappearance() -> :ClearCharacterAppearance()" },
	{ ":isancestorof%(", ":IsAncestorOf(", "Old :isancestorof() -> :IsAncestorOf()" },
	{ ":findpartsonraywithignorelist%(", ":FindPartsInRegion3WithIgnoreList(", "Old :findpartsonraywithignorelist() -> :FindPartsInRegion3WithIgnoreList()" },
	{ ":findPartsInRegion3WithIgnoreList%(", ":FindPartsInRegion3WithIgnoreList(", "Old :findPartsInRegion3WithIgnoreList() -> :FindPartsInRegion3WithIgnoreList()" },
	{ ":filterstringforbroadcast%(", ":FilterStringForBroadcast(", "Old :filterstringforbroadcast() -> :FilterStringForBroadcast()" },
	{ ":emit%(", ":Emit(", "Old :emit() -> :Emit()" },
	{ ":additem%(", ":AddItem(", "Old :additem() -> :AddItem()" },
	{ ":setnetworkowner%(", ":SetNetworkOwner(", "Old :setnetworkowner() -> :SetNetworkOwner()" },
	{ ":equiptool%(", ":EquipTool(", "Old :equiptool() -> :EquipTool()" },
	{ ":unequiptools%(", ":UnequipTools(", "Old :unequiptools() -> :UnequipTools()" },
	{ ":sit%(", ":Sit(", "Old :sit() -> :Sit()" },
	{ ":gethumanoiddescription%(", ":GetHumanoidDescription(", "Old :gethumanoiddescription() -> :GetHumanoidDescription()" },
	{ ":applydescription%(", ":ApplyDescription(", "Old :applydescription() -> :ApplyDescription()" },
	{ ":findpartonray%(", ":FindPartOnRay(", "Old :findpartonray() -> :FindPartOnRay()" },
	{ ":findPartOnRay%(", ":FindPartOnRay(", "Old :findPartOnRay() -> :FindPartOnRay()" },
	{ ":findPartOnRayWithIgnoreList%(", ":FindPartOnRayWithIgnoreList(", "Old :findPartOnRayWithIgnoreList() -> :FindPartOnRayWithIgnoreList()" },
	{ "%.formFactor%f[^%w_]", ".FormFactor", "Old .formFactor -> .FormFactor" },
	{ "%f[%w]wait%(", "task.wait(", "wait() -> task.wait()" },
	{ "%f[%w]spawn%(", "task.spawn(", "spawn() -> task.spawn()" },
	{ "%f[%w]delay%(", "task.delay(", "delay() -> task.delay()" },
}

-- Replace only in code, never inside strings or comments.
-- Scanner states: code, string (' or "), longstring, linecomment, blockcomment.
local function replaceOutsideStringsAndComments(source, pattern, replacement)
	local out = {}
	local i = 1
	local n = #source
	local state = "code"
	local quote = nil
	local longLevel = 0

	while i <= n do
		local c = source:sub(i, i)
		local two = source:sub(i, i + 1)

		if state == "code" then
			if two == "--" then
				-- Check for block comment --[[ or --[==[
				local level = source:sub(i + 2):match("^%[(=*)%[")
				if level ~= nil then
					state = "blockcomment"
					longLevel = #level
					out[#out + 1] = two .. "[" .. level .. "["
					i = i + 4 + longLevel
				else
					state = "linecomment"
					out[#out + 1] = two
					i = i + 2
				end
			elseif c == '"' or c == "'" then
				state = "string"
				quote = c
				out[#out + 1] = c
				i = i + 1
			elseif c == "[" then
				local level = source:sub(i):match("^%[(=*)%[")
				if level ~= nil then
					state = "longstring"
					longLevel = #level
					out[#out + 1] = "[" .. level .. "["
					i = i + 2 + longLevel
				else
					out[#out + 1] = c
					i = i + 1
				end
			else
				-- Try every replacement at this position, in code only.
				local matched = false
				for _, r in ipairs(REPLACEMENTS) do
					if r[1] == pattern then
						local s, e = source:find("^" .. pattern, i)
						if s then
							-- BUG FIX (was: task.wait -> task.task.wait):
							-- %f[%w] only blocks a *word* character before
							-- wait/spawn/delay. A '.' is not a word char,
							-- so "task.wait(" matched "wait(" and became
							-- "task.task.wait(", whose "task.task" is nil
							-- -- hence "Tried to index nil with 'wait'".
							-- So for task.* replacements, also block a
							-- preceding '.', ':', or word character.
							-- That leaves already-modern task.wait(),
							-- task.spawn(), task.delay(), and also
							-- obj.wait() / obj:wait(), untouched, while
							-- a bare wait() / spawn() / delay() still
							-- converts to task.wait() / etc.
							local needsGuard = replacement:sub(1, 5) == "task."
								or pattern:sub(1, 4) == "game"
							local prev = source:sub(s - 1, s - 1)
							local blocked = needsGuard
								and prev ~= ""
								and prev:match("[%w_%.:]") ~= nil
							if not blocked then
								out[#out + 1] = replacement
								i = e + 1
								matched = true
								break
							end
						end
					end
				end
				if not matched then
					out[#out + 1] = c
					i = i + 1
				end
			end
		elseif state == "string" then
			out[#out + 1] = c
			if c == "\\" and i < n then
				out[#out + 1] = source:sub(i + 1, i + 1)
				i = i + 2
			elseif c == quote then
				state = "code"
				i = i + 1
			else
				i = i + 1
			end
		elseif state == "linecomment" then
			out[#out + 1] = c
			if c == "\n" then state = "code" end
			i = i + 1
		elseif state == "blockcomment" then
			local closer = "]" .. string.rep("=", longLevel) .. "]"
			if source:sub(i, i + #closer - 1) == closer then
				out[#out + 1] = closer
				i = i + #closer
				state = "code"
			else
				out[#out + 1] = c
				i = i + 1
			end
		elseif state == "longstring" then
			local closer = "]" .. string.rep("=", longLevel) .. "]"
			if source:sub(i, i + #closer - 1) == closer then
				out[#out + 1] = closer
				i = i + #closer
				state = "code"
			else
				out[#out + 1] = c
				i = i + 1
			end
		end
	end

	return table.concat(out)
end

-- Wrap the value of an assignment to an Instance-typed
-- property in __sbUnwrap(), when that value is often a
-- sandbox proxy table rather than a real Instance.
-- The case that forced this: Warden sets
--   billboardGui.PlayerToHideFrom = Player
-- where Player is game.Players.LocalPlayer, which the sandbox
-- must serve as a proxy table (it carries GetMouse and the
-- R6 character mapping). The engine rejects a table for an
-- Instance property: "Unable to assign property
-- PlayerToHideFrom. Instance expected, got table", and the
-- whole run dies at that line. __sbUnwrap maps a known proxy
-- back to its real Instance and passes everything else through
-- unchanged, so the rewrite is safe for real values too.
-- Only right-hand sides with balanced brackets and no
-- top-level comma are rewritten; anything else
-- (multi-assignments, comparisons, strings, comments,
-- table-constructor fields, unbalanced expressions) is left
-- exactly as written rather than risk breaking it. A balanced
-- right-hand side may span lines; wrapping it whole is still
-- correct, because Lua only continues an expression past a
-- newline inside brackets.
local WRAP_PROPERTIES = { PlayerToHideFrom = true, Adornee = true, Parent = true }

local function wrapProxyAssignments(source)
	local out = {}
	local i = 1
	local n = #source
	local state = "code"
	local quote = nil
	local longLevel = 0
	local braceDepth = 0
	local prevSig = nil

	local function append(s) out[#out + 1] = s end

	-- Scans a right-hand side starting at startPos. Returns
	-- the index of its terminator (newline, ';', or a line
	-- comment) and the trimmed right-hand side, or nil if the
	-- right-hand side is not safe to wrap.
	local function scanRhs(startPos)
		local depth = 0
		local k = startPos
		local inStr = nil
		local inLong = false
		local longLvl = 0
		while k <= n do
			local ch = source:sub(k, k)
			local two = source:sub(k, k + 1)
			if inStr then
				if ch == "\\" then
					k = k + 2
				elseif ch == inStr then
					inStr = nil
					k = k + 1
				elseif ch == "\n" then
					return nil
				else
					k = k + 1
				end
			elseif inLong then
				local closer = "]" .. string.rep("=", longLvl) .. "]"
				if source:sub(k, k + #closer - 1) == closer then
					inLong = false
					k = k + #closer
				else
					k = k + 1
				end
			else
				if two == "--" then
					if depth == 0 then
						local rhs = source:sub(startPos, k - 1):gsub("%s+$", "")
						if rhs == "" then return nil end
						return k, rhs
					end
					return nil
				elseif ch == '"' or ch == "'" then
					inStr = ch
					k = k + 1
				elseif ch == "[" then
					local level = source:sub(k):match("^%[(=*)%[")
					if level ~= nil then
						inLong = true
						longLvl = #level
						k = k + 2 + longLvl
					else
						depth = depth + 1
						k = k + 1
					end
				elseif ch == "(" or ch == "{" then
					depth = depth + 1
					k = k + 1
				elseif ch == ")" or ch == "]" or ch == "}" then
					depth = depth - 1
					if depth < 0 then return nil end
					k = k + 1
				elseif depth == 0 and ch == "\n" then
					local rhs = source:sub(startPos, k - 1):gsub("%s+$", "")
					if rhs == "" then return nil end
					return k, rhs
				elseif depth == 0 and ch == ";" then
					local rhs = source:sub(startPos, k - 1):gsub("%s+$", "")
					if rhs == "" then return nil end
					return k, rhs
				elseif depth == 0 and ch == "," then
					return nil
				else
					k = k + 1
				end
			end
		end
		if depth ~= 0 or inStr or inLong then return nil end
		local rhs = source:sub(startPos, n):gsub("%s+$", "")
		if rhs == "" then return nil end
		return n + 1, rhs
	end

	-- Scans a table-field value starting at startPos. Returns
	-- the index of its terminator (',' or '}' at the field's
	-- brace depth) and the trimmed value, or nil if it is not
	-- safe to wrap. Unlike scanRhs, newlines do not terminate
	-- (a field value may start on the next line), line comments
	-- are skipped, and ',' is the terminator, not an abort:
	-- that is what separates a field from a multi-assign.
	local function scanFieldRhs(startPos)
		local depth = 0
		local k = startPos
		local inStr = nil
		local inLong = false
		local longLvl = 0
		while k <= n do
			local ch = source:sub(k, k)
			local two = source:sub(k, k + 1)
			if inStr then
				if ch == "\\" then
					k = k + 2
				elseif ch == inStr then
					inStr = nil
					k = k + 1
				elseif ch == "\n" then
					return nil
				else
					k = k + 1
				end
			elseif inLong then
				local closer = "]" .. string.rep("=", longLvl) .. "]"
				if source:sub(k, k + #closer - 1) == closer then
					inLong = false
					k = k + #closer
				else
					k = k + 1
				end
			else
				if two == "--" then
					local level = source:sub(k + 2):match("^%[(=*)%[")
					if level ~= nil then
						local closer = "]" .. level .. "]"
						local closeAt = source:find(closer, k + 4 + #level, true)
						if not closeAt then return nil end
						k = closeAt + #closer
					else
						local nl = source:find("\n", k, true)
						if not nl then return nil end
						k = nl + 1
					end
				elseif ch == '"' or ch == "'" then
					inStr = ch
					k = k + 1
				elseif ch == "[" then
					local level = source:sub(k):match("^%[(=*)%[")
					if level ~= nil then
						inLong = true
						longLvl = #level
						k = k + 2 + longLvl
					else
						depth = depth + 1
						k = k + 1
					end
				elseif ch == "(" or ch == "{" then
					depth = depth + 1
					k = k + 1
				elseif ch == ")" or ch == "]" then
					depth = depth - 1
					if depth < 0 then return nil end
					k = k + 1
				elseif ch == "}" then
					if depth == 0 then
						local rhs = source:sub(startPos, k - 1):gsub("%s+$", "")
						if rhs == "" then return nil end
						return k, rhs
					end
					depth = depth - 1
					k = k + 1
				elseif depth == 0 and ch == "," then
					local rhs = source:sub(startPos, k - 1):gsub("%s+$", "")
					if rhs == "" then return nil end
					return k, rhs
				elseif depth == 0 and ch == ";" then
					return nil
				else
					k = k + 1
				end
			end
		end
		return nil
	end

	while i <= n do
		local c = source:sub(i, i)
		local two = source:sub(i, i + 1)
		if state == "code" then
			if two == "--" then
				local level = source:sub(i + 2):match("^%[(=*)%[")
				if level ~= nil then
					state = "blockcomment"
					longLevel = #level
					append(two .. "[" .. level .. "[")
					i = i + 4 + longLevel
				else
					state = "linecomment"
					append(two)
					i = i + 2
				end
			elseif c == '"' or c == "'" then
				state = "string"
				quote = c
				append(c)
				i = i + 1
			elseif c == "[" then
				local level = source:sub(i):match("^%[(=*)%[")
				if level ~= nil then
					state = "longstring"
					longLevel = #level
					append("[" .. level .. "[")
					i = i + 2 + longLevel
				else
					append(c)
					i = i + 1
				end
			elseif c == "." and source:sub(i - 1, i - 1) ~= "." then
				local matchedProp = nil
				local propEnd = nil
				for prop in pairs(WRAP_PROPERTIES) do
					local s, e = source:find("^%.%s*" .. prop .. "%s*=", i)
					if s and source:sub(e + 1, e + 1) ~= "=" then
						matchedProp = prop
						propEnd = e
						break
					end
				end
				if matchedProp then
					local j = propEnd + 1
					while j <= n do
						local sp = source:sub(j, j)
						if sp == " " or sp == "\t" or sp == "\r" then
							j = j + 1
						else
							break
						end
					end
					local rhsEnd, rhs = scanRhs(j)
					if rhsEnd and not rhs:find("^__sbUnwrap%(") then
						append(source:sub(i, propEnd))
						append(" __sbUnwrap(")
						append(rhs)
						append(")")
						if source:sub(rhsEnd, rhsEnd + 1) == "--" then
							append(" ")
						end
						prevSig = ")"
						i = rhsEnd
					else
						append(c)
						prevSig = "."
						i = i + 1
					end
				else
					append(c)
					prevSig = "."
					i = i + 1
				end
			elseif c:match("[%a_]") then
				-- Table field: Parent / Adornee / PlayerToHideFrom
				-- as a key inside {...}, e.g. the props tables
				-- old Create helpers take: Create("Part")({
				-- Parent = script, Name = "X" }). Only when the
				-- previous significant character is '{' or ','
				-- and we are inside braces: that rules out
				-- `local Parent = ...` and bare `Parent = ...`
				-- assignments, which must keep the proxy.
				local word = source:sub(i):match("^[%a_][%w_]*")
				local matchedField = nil
				local eqEnd = nil
				if word and WRAP_PROPERTIES[word] and braceDepth > 0
					and (prevSig == "{" or prevSig == ",") then
					local s, e = source:find("^" .. word .. "%s*=", i)
					if s and source:sub(e + 1, e + 1) ~= "=" then
						matchedField = word
						eqEnd = e
					end
				end
				if matchedField then
					local j = eqEnd + 1
					while j <= n do
						local sp = source:sub(j, j)
						if sp == " " or sp == "\t" or sp == "\r" or sp == "\n" then
							j = j + 1
						else
							break
						end
					end
					local rhsEnd, rhs = scanFieldRhs(j)
					if rhsEnd and not rhs:find("^__sbUnwrap%(") then
						append(source:sub(i, eqEnd))
						append(" __sbUnwrap(")
						append(rhs)
						append(")")
						prevSig = ")"
						i = rhsEnd
					else
						append(word)
						prevSig = word:sub(-1)
						i = i + #word
					end
				else
					append(word)
					prevSig = word:sub(-1)
					i = i + #word
				end
			else
				append(c)
				if c == "{" then
					braceDepth = braceDepth + 1
					prevSig = "{"
				elseif c == "}" then
					braceDepth = braceDepth - 1
					prevSig = "}"
				elseif c ~= " " and c ~= "\t" and c ~= "\r" and c ~= "\n" then
					prevSig = c
				end
				i = i + 1
			end
		elseif state == "string" then
			append(c)
			if c == "\\" and i < n then
				append(source:sub(i + 1, i + 1))
				i = i + 2
			elseif c == quote then
				state = "code"
				i = i + 1
			else
				i = i + 1
			end
		elseif state == "linecomment" then
			append(c)
			if c == "\n" then state = "code" end
			i = i + 1
		elseif state == "blockcomment" then
			local closer = "]" .. string.rep("=", longLevel) .. "]"
			if source:sub(i, i + #closer - 1) == closer then
				append(closer)
				i = i + #closer
				state = "code"
			else
				append(c)
				i = i + 1
			end
		elseif state == "longstring" then
			local closer = "]" .. string.rep("=", longLevel) .. "]"
			if source:sub(i, i + #closer - 1) == closer then
				append(closer)
				i = i + #closer
				state = "code"
			else
				append(c)
				i = i + 1
			end
		end
	end

	return table.concat(out)
end

function Fixer.fix(source)
	local notes = {}
	local fixed = source

	for _, r in ipairs(REPLACEMENTS) do
		local before = fixed
		fixed = replaceOutsideStringsAndComments(fixed, r[1], r[2])
		if fixed ~= before then
			notes[#notes + 1] = r[3]
		end
	end

	local wrapped = wrapProxyAssignments(fixed)
	if wrapped ~= fixed then
		fixed = wrapped
		notes[#notes + 1] = "Sandbox proxy tables unwrapped for .Parent / .PlayerToHideFrom / .Adornee, including table fields like {Parent = script} (LocalPlayer and R15 characters are proxy tables; the engine needs real Instances there)."
	end

	-- Hard blocks, reported as notes (the sandbox enforces them too).
	if fixed:find("Instance%.new%(%s*[\"']Script[\"']") or fixed:find("Instance%.new%(%s*[\"']LocalScript[\"']") then
		notes[#notes + 1] = "Creating Script/LocalScript objects with Instance.new is blocked by the sandbox; use NLS(source, parent) for client code."
	end
	notes[#notes + 1] = "Runs on the server through vLuau (a real Luau compiler + VM), not the client: every Part/Model it creates replicates normally under FilteringEnabled."
	notes[#notes + 1] = "script.Parent points at your per-player build folder. game.Players.LocalPlayer is the player who pressed Execute."

	return fixed, notes
end

-- Client-side pass, used by NLS. Applies only the rewrites that
-- are safe on a real client: old method spellings, .formFactor,
-- and wait/spawn/delay -> task.*. It deliberately does NOT apply
-- the server-side conversions (game.Players.LocalPlayer ->
-- player, game.Workspace -> workspace), because on the client
-- LocalPlayer is valid and `player` is undefined. It also does
-- NOT apply the proxy unwrap pass: the client has no __sbUnwrap.
function Fixer.fixClientSource(source)
	local notes = {}
	local fixed = source

	for _, r in ipairs(REPLACEMENTS) do
		if r[4] ~= "server" then
			local before = fixed
			fixed = replaceOutsideStringsAndComments(fixed, r[1], r[2])
			if fixed ~= before then
				notes[#notes + 1] = r[3]
			end
		end
	end

	return fixed, notes
end

return Fixer
