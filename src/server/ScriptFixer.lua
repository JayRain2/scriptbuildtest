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
	{ "game%.Players%.localPlayer", "player", "game.Players.localPlayer -> player (server-side owner)", "server" },
	{ "game:GetService%(%s*\"Players\"%s*%)%.LocalPlayer", "player", 'game:GetService("Players").LocalPlayer -> player (server-side owner)', "server" },
	{ "game:GetService%(%s*'Players'%s*%)%.LocalPlayer", "player", "game:GetService('Players').LocalPlayer -> player (server-side owner)", "server" },
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
	{ ":isA%(", ":IsA(", "Old :isA() -> :IsA()" },
	{ ":lerp%(", ":Lerp(", "Old :lerp() -> :Lerp()" },
	{ ":inverse%(", ":Inverse(", "Old :inverse() -> :Inverse()" },
	{ ":getboundingbox%(", ":GetBoundingBox(", "Old :getboundingbox() -> :GetBoundingBox()" },
	{ ":getmass%(", ":GetMass(", "Old :getmass() -> :GetMass()" },
	{ ":getstate%(", ":GetState(", "Old :getstate() -> :GetState()" },
	{ ":changestate%(", ":ChangeState(", "Old :changestate() -> :ChangeState()" },
	{ ":setprimarypartcframe%(", ":SetPrimaryPartCFrame(", "Old :setprimarypartcframe() -> :SetPrimaryPartCFrame()" },
	{ ":pivoto%(", ":PivotTo(", "Old :pivoto() -> :PivotTo()" },
	{ ":pivotTo%(", ":PivotTo(", "Old :pivotTo() -> :PivotTo()" },
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
	{ "%.force%f[^%w_]", ".Force", "Old .force -> .Force (BodyForce)" },
	{ "%f[%w]wait%(", "task.wait(", "wait() -> task.wait()" },
	{ "%f[%w]spawn%(", "task.spawn(", "spawn() -> task.spawn()" },
	{ "%f[%w]delay%(", "task.delay(", "delay() -> task.delay()" },
}

-- Build a case-insensitive version of a Lua pattern, for
-- method/property spellings only. Letters outside % escapes
-- and [...] classes become [aA] classes; everything else
-- (%, brackets, digits, punctuation) is copied verbatim.
-- That closes the gap where the old interpreter's
-- case-insensitive lookup let scripts use :waitForChild,
-- :getchildren, :moveTo, :loadAnimation, etc., while the
-- Fixer only rewrote one casing of each (e.g. :waitforchild
-- but not :waitForChild, :getChildren but not :getchildren).
-- Normalising to the canonical spelling is safe either way:
-- canonical is always valid, so a script that already worked
-- is unchanged in effect, and one that relied on
-- case-insensitivity now gets the spelling real Luau wants.
local function makeCaseInsensitive(pattern)
	local out = {}
	local i = 1
	local n = #pattern
	while i <= n do
		local c = pattern:sub(i, i)
		if c == "%" then
			out[#out + 1] = pattern:sub(i, i + 1)
			i = i + 2
		elseif c == "[" then
			local close = pattern:find("]", i, true)
			if not close then
				out[#out + 1] = c
				i = i + 1
			else
				out[#out + 1] = pattern:sub(i, close)
				i = close + 1
			end
		elseif c:match("[%a]") then
			out[#out + 1] = "[" .. c:lower() .. c:upper() .. "]"
			i = i + 1
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

-- Replace only in code, never inside strings or comments.
-- Scanner states: code, string (' or "), longstring, linecomment, blockcomment.
local function replaceOutsideStringsAndComments(source, pattern, replacement)
	local out = {}
	local i = 1
	local n = #source
	local state = "code"
	local quote = nil
	local longLevel = 0
	-- Method spellings and .formFactor are matched
	-- case-insensitively (see makeCaseInsensitive); every
	-- other pattern (game.*, wait/spawn/delay) stays exact.
	-- Method calls and wait/spawn/delay are also matched
	-- with optional spaces: Lua allows `v: remove ( )`,
	-- `x:clone ( )` and `wait (1)`, and old scripts use
	-- those spaced forms (Flash uses them throughout).
	-- The spaces are consumed by the replacement, which is
	-- fine: `:Connect(` means the same as `:Connect (`.
	local searchPattern = pattern
	if pattern:sub(1, 1) == ":" or pattern:find("formFactor", 1, true) then
		searchPattern = makeCaseInsensitive(pattern)
	end
	if pattern:sub(1, 1) == ":" then
		searchPattern = ":" .. "%s*" .. searchPattern:sub(2)
	end
	-- Every pattern ending in "%(" is a method or a
	-- wait/spawn/delay call (game patterns end in "%)" or
	-- have no paren, formFactor ends in "]"), so this only
	-- affects those.
	if searchPattern:sub(-2) == "%(" then
		searchPattern = searchPattern:sub(1, -3) .. "%s*%("
	end

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
						local s, e = source:find("^" .. searchPattern, i)
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
	-- the index of its terminator and the trimmed right-hand
	-- side, or nil if the right-hand side is not safe to wrap.
	-- Terminators at depth 0: newline, ';', a line comment,
	-- a statement keyword (end / else / elseif / until, and
	-- any statement-starting word after a complete operand),
	-- or the start of a new statement after a complete
	-- operand. The last rule is the Flash-script fix: Lua
	-- does not require a separator between statements, so
	-- old one-line chains like
	--   fake.head.Parent = model fake.head.BrickColor = ...
	-- used to scan past `model` and wrap it as
	--   __sbUnwrap(model fake.head.BrickColor = ...)
	-- which the compiler rejected with "')' expected near
	-- 'fake'". The scanner now tracks whether the previous
	-- token completed an operand: after an operand, a word
	-- (other than and/or) or a number starts a new
	-- statement, so the right-hand side ends before it.
	-- Operators, suffixes (.name, [i], :m(), (args)) and
	-- call arguments in string/table form keep the operand
	-- open, so `x.Parent = foo(a, b)`, `x.Parent = a + b`,
	-- `x.Parent = foo "bar"` and `x.Parent = a.Parent`
	-- still wrap whole. The Krystal keyword rule is a
	-- special case of this: a keyword at depth 0, on a
	-- word boundary, ends the right-hand side; the keyword
	-- itself is left for the caller to emit unchanged.
	local function scanRhs(startPos)
		local depth = 0
		local blockDepth = 0
		local prevOperandEnd = false
		local started = false
		local awaitingLoopDo = false
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
					prevOperandEnd = true
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
					prevOperandEnd = true
					k = k + #closer
				else
					k = k + 1
				end
			else
				if depth == 0 then
					local prev = source:sub(k - 1, k - 1)
					local atWordStart = prev == "" or not prev:match("[%w_]")
					if atWordStart then
						local word = source:sub(k):match("^[%a_][%w_]*")
						if word then
							started = true
							-- A complete operand followed by
							-- a word that is not a binary
							-- operator: that word starts a
							-- new statement (an assignment,
							-- a call, local, if, for, while,
							-- repeat, do, return, break, a
							-- function statement, ...).
							if blockDepth == 0 and prevOperandEnd
								and word ~= "and" and word ~= "or" then
								local rhs = source:sub(startPos, k - 1):gsub("%s+$", "")
								if rhs == "" then return nil end
								return k, rhs
							end
							local handledWord = false
							-- `do`: a loop's `do` (for/while)
							-- is part of that loop's block,
							-- not a new block; a standalone
							-- `do` is a block of its own.
							-- awaitingLoopDo tracks a for/while
							-- whose `do` has not been seen
							-- yet, so `function() do x() end
							-- end` counts both blocks while
							-- `for i=1,10 do x() end` counts
							-- one. (Only reached when no
							-- operand just ended, as above.)
							if word == "do" then
								local after = source:sub(k + 2, k + 2)
								if after == "" or not after:match("[%w_]") then
									if awaitingLoopDo then
										awaitingLoopDo = false
									else
										blockDepth = blockDepth + 1
									end
									prevOperandEnd = false
									handledWord = true
								end
							end
							-- Block openers inside a right-hand
							-- side (only realistic case: a
							-- function literal as the value)
							-- open a block whose own `end`
							-- must not terminate the scan.
							-- (Only reached when no operand
							-- just ended, because the check
							-- above already returned for a
							-- word after an operand.)
							if not handledWord then
							for _, kw in ipairs({ "function", "if", "for", "while", "repeat" }) do
								if source:sub(k, k + #kw - 1) == kw then
									local after = source:sub(k + #kw, k + #kw)
									if after == "" or not after:match("[%w_]") then
										blockDepth = blockDepth + 1
										if kw == "for" or kw == "while" then
											awaitingLoopDo = true
										end
										prevOperandEnd = false
										handledWord = true
										break
									end
								end
							end
							end
							if not handledWord then
								for _, kw in ipairs({ "elseif", "else", "end", "until" }) do
									if source:sub(k, k + #kw - 1) == kw then
										local after = source:sub(k + #kw, k + #kw)
										if after == "" or not after:match("[%w_]") then
											if blockDepth > 0 then
												if kw == "end" or kw == "until" then
													blockDepth = blockDepth - 1
													prevOperandEnd = blockDepth == 0
												else
													prevOperandEnd = false
												end
												-- else/elseif belong to
												-- the inner block: keep
												-- scanning, do not end here.
											else
												local rhs = source:sub(startPos, k - 1):gsub("%s+$", "")
												if rhs == "" then return nil end
												return k, rhs
											end
											handledWord = true
										end
									end
								end
							end
							if not handledWord then
								if word == "and" or word == "or" or word == "not" then
									prevOperandEnd = false
								else
									prevOperandEnd = true
								end
							end
						end
					end
				end
				if two == "--" then
					if blockDepth > 0 then
						-- Inside a function literal, a comment
						-- is not a terminator: skip it and keep
						-- scanning the function body.
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
					elseif depth == 0 then
						local rhs = source:sub(startPos, k - 1):gsub("%s+$", "")
						if rhs == "" then return nil end
						return k, rhs
					else
						return nil
					end
				elseif ch == '"' or ch == "'" then
					inStr = ch
					started = true
					prevOperandEnd = false
					k = k + 1
				elseif ch == "[" then
					local level = source:sub(k):match("^%[(=*)%[")
					if level ~= nil then
						inLong = true
						longLvl = #level
						started = true
						prevOperandEnd = false
						k = k + 2 + longLvl
					else
						depth = depth + 1
						started = true
						prevOperandEnd = false
						k = k + 1
					end
				elseif ch == "(" or ch == "{" then
					depth = depth + 1
					started = true
					prevOperandEnd = false
					k = k + 1
				elseif ch == ")" or ch == "]" or ch == "}" then
					depth = depth - 1
					if depth < 0 then return nil end
					started = true
					prevOperandEnd = true
					k = k + 1
				elseif depth == 0 and blockDepth == 0 and ch:match("%d") and prevOperandEnd
					and not source:sub(k - 1, k - 1):match("[%w_.]") then
					-- A number starting a new statement after
					-- a complete operand (a bare number is not
					-- a call argument, unlike a string or a
					-- table, so it cannot continue the RHS).
					local rhs = source:sub(startPos, k - 1):gsub("%s+$", "")
					if rhs == "" then return nil end
					return k, rhs
				elseif ch:match("[%+%-%*/%%^<>~=#%.:]") then
					-- Binary/unary operator, field/index/method
					-- suffix, or '.'/'..': the operand is not
					-- complete yet, the next token continues it.
					started = true
					prevOperandEnd = false
					k = k + 1
				elseif ch:match("%d") then
					started = true
					prevOperandEnd = true
					k = k + 1
				elseif depth == 0 and ch == "\n" then
					-- A newline ends the RHS, except inside
					-- a function literal (where it only
					-- separates statements), before any
					-- token (RHS starting on the next line
					-- is not wrapped, as before), or after
					-- an operator/dot (Lua continues an
					-- expression after a trailing operator,
					-- so `w.Parent = a or\n b` wraps whole).
					if blockDepth > 0 then
						k = k + 1
					elseif not started then
						return nil
					elseif prevOperandEnd then
						local rhs = source:sub(startPos, k - 1):gsub("%s+$", "")
						if rhs == "" then return nil end
						return k, rhs
					else
						k = k + 1
					end
				elseif depth == 0 and ch == ";" then
					if blockDepth > 0 then
						k = k + 1
					else
						local rhs = source:sub(startPos, k - 1):gsub("%s+$", "")
						if rhs == "" then return nil end
						return k, rhs
					end
				elseif depth == 0 and ch == "," then
					if blockDepth > 0 then
						k = k + 1
					else
						return nil
					end
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
	-- brace depth, ';' as a field separator, or a line
	-- comment before the separator) and the trimmed value,
	-- or nil if it is not safe to wrap. Unlike scanRhs,
	-- newlines do not terminate (a field value may start
	-- on the next line), and ',' is the terminator, not an
	-- abort: that is what separates a field from a
	-- multi-assign. Block tracking mirrors scanRhs: a comma
	-- (or semicolon) inside a function literal's body does
	-- not terminate the field, so
	--   {Parent = function() local a, b = 1, 2 return a end, ...}
	-- wraps whole instead of closing at the body's comma.
	-- A line comment before the separator terminates the
	-- field (the wrapper's ')' must land before the
	-- comment, not on the comment line where it would be
	-- commented out); block comments are skipped as before.
	local function scanFieldRhs(startPos)
		local depth = 0
		local blockDepth = 0
		local awaitingLoopDo = false
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
				if depth == 0 then
					local prev = source:sub(k - 1, k - 1)
					local atWordStart = prev == "" or not prev:match("[%w_]")
					if atWordStart then
						local word = source:sub(k):match("^[%a_][%w_]*")
						if word then
							if word == "do" then
								local after = source:sub(k + 2, k + 2)
								if after == "" or not after:match("[%w_]") then
									if awaitingLoopDo then
										awaitingLoopDo = false
									else
										blockDepth = blockDepth + 1
									end
								end
							else
								for _, kw in ipairs({ "function", "if", "for", "while", "repeat" }) do
									if word == kw then
										blockDepth = blockDepth + 1
										if kw == "for" or kw == "while" then
											awaitingLoopDo = true
										end
										break
									end
								end
								for _, kw in ipairs({ "end", "until" }) do
									if word == kw and blockDepth > 0 then
										blockDepth = blockDepth - 1
										break
									end
								end
							end
						end
					end
				end
				if two == "--" then
					local level = source:sub(k + 2):match("^%[(=*)%[")
					if level == nil and depth == 0 and blockDepth == 0 then
						local rhs = source:sub(startPos, k - 1):gsub("%s+$", "")
						if rhs == "" then return nil end
						return k, rhs
					elseif level ~= nil then
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
					if blockDepth > 0 then
						k = k + 1
					else
						local rhs = source:sub(startPos, k - 1):gsub("%s+$", "")
						if rhs == "" then return nil end
						return k, rhs
					end
				elseif depth == 0 and ch == ";" then
					-- ';' is a valid table field separator in
					-- Lua, so it terminates the field just
					-- like ',' (it used to abort the wrap).
					if blockDepth > 0 then
						k = k + 1
					else
						local rhs = source:sub(startPos, k - 1):gsub("%s+$", "")
						if rhs == "" then return nil end
						return k, rhs
					end
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
						if source:sub(rhsEnd, rhsEnd + 1) == "--" or source:sub(rhsEnd, rhsEnd):match("[%w]") then
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
				-- previous significant character is '{', ',' or
				-- ';' (Lua allows ';' as a table field
				-- separator) and we are inside braces: that rules
				-- out `local Parent = ...` and bare `Parent = ...`
				-- assignments, which must keep the proxy.
				local word = source:sub(i):match("^[%a_][%w_]*")
				local matchedField = nil
				local eqEnd = nil
				if word and WRAP_PROPERTIES[word] and braceDepth > 0
					and (prevSig == "{" or prevSig == "," or prevSig == ";") then
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
						if source:sub(rhsEnd, rhsEnd + 1) == "--" then
							append(" ")
						end
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

-- v16.1 passes. These share one code-only scanner (strings,
-- comments and longstrings are copied verbatim, never
-- rewritten) so a pattern inside a string or comment can
-- never trigger a rewrite.

-- Shared code-only scanner: at each code position, tryMatch
-- (source, i, n) may return (startPos, endPos, replacement)
-- for a rewrite covering source[startPos..endPos]; nil
-- leaves the char alone. startPos may be BEFORE i (the
-- limb/mesh passes capture a receiver that ends at i), so
-- matches are collected first and spliced at the end --
-- emitting while scanning would duplicate the receiver,
-- which the scanner has already passed. Strings, comments
-- and longstrings are never matched inside.
local function scanCode(source, tryMatch)
	local matches = {}
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
				local level = source:sub(i + 2):match("^%[(=*)%[")
				if level ~= nil then
					state = "blockcomment"
					longLevel = #level
					i = i + 4 + longLevel
				else
					state = "linecomment"
					i = i + 2
				end
			elseif c == '"' or c == "'" then
				state = "string"
				quote = c
				i = i + 1
			elseif c == "[" then
				local level = source:sub(i):match("^%[(=*)%[")
				if level ~= nil then
					state = "longstring"
					longLevel = #level
					i = i + 2 + longLevel
				else
					i = i + 1
				end
			else
				local startPos, endPos, replacement = tryMatch(source, i, n)
				if replacement ~= nil then
					matches[#matches + 1] = { startPos, endPos, replacement }
					i = endPos + 1
				else
					i = i + 1
				end
			end
		elseif state == "string" then
			if c == "\\" and i < n then
				i = i + 2
			elseif c == quote then
				state = "code"
				i = i + 1
			else
				i = i + 1
			end
		elseif state == "linecomment" then
			if c == "\n" then state = "code" end
			i = i + 1
		else -- blockcomment or longstring
			local closer = "]" .. string.rep("=", longLevel) .. "]"
			if source:sub(i, i + #closer - 1) == closer then
				i = i + #closer
				state = "code"
			else
				i = i + 1
			end
		end
	end
	local out = {}
	local pos = 1
	for _, m in ipairs(matches) do
		if m[1] > pos then out[#out + 1] = source:sub(pos, m[1] - 1) end
		out[#out + 1] = m[3]
		pos = m[2] + 1
	end
	if pos <= n then out[#out + 1] = source:sub(pos, n) end
	return table.concat(out)
end

-- Capture the receiver expression ending just before `pos`
-- (the index of the `:` or `.` starting a call or index).
-- Returns the receiver text, or nil when it is not a simple
-- value (keyword-led, unbalanced, or split across lines):
-- those are left untouched rather than rewritten wrong.
-- Method calls bind tighter than binary operators, so the
-- receiver is the atom before the `:`/`.`, and operators,
-- commas, semicolons and `=` are boundaries, not part of
-- it. A `..` is also a boundary (the receiver is the value
-- after it), because dots otherwise swallow the concat.
local function captureReceiver(source, pos)
	local j = pos - 1
	if j < 1 then return nil end
	local depth = 0
	while j >= 1 do
		local c = source:sub(j, j)
		if c == ")" or c == "]" then
			depth = depth + 1
		elseif c == "(" or c == "[" then
			depth = depth - 1
			if depth < 0 then break end
		elseif depth == 0 then
			if c == "." and j > 1 and source:sub(j - 1, j - 1) == "." then
				break
			end
			if c == " " or c == "\t" or c == "\n" or c == "\r"
				or c == ";" or c == "," or c == "="
				or c == "+" or c == "-" or c == "*" or c == "/"
				or c == "%" or c == "^" or c == "#" or c == "<"
				or c == ">" or c == "~" then
				break
			end
		end
		j = j - 1
	end
	local receiver = source:sub(j + 1, pos - 1):gsub("%s+$", "")
	if receiver == "" then return nil end
	if receiver:find("\n") then return nil end
	if receiver:match("[%.:]$") then return nil end
	-- Strip short strings (escapes handled) and same-line
	-- longstrings, then the receiver must be balanced and
	-- free of top-level operators and keywords.
	local stripped = receiver:gsub("\\.", "")
	stripped = stripped:gsub('"[^"\n]*"', '""'):gsub("'[^'\n]*'", "''")
	stripped = stripped:gsub("%[%[.-%]%]", "")
	local bal = 0
	for k = 1, #stripped do
		local c = stripped:sub(k, k)
		if c == "(" or c == "[" then
			bal = bal + 1
		elseif c == ")" or c == "]" then
			bal = bal - 1
			if bal < 0 then return nil end
		end
	end
	if bal ~= 0 then return nil end
	local flat = stripped:gsub("%b()", ""):gsub("%b[]", "")
	if flat:find("%.%.") then return nil end
	if flat:find("[%+%-%*/%%^#<>~=]") then return nil end
	if flat:find("%f[%w]and%f[^%w]") or flat:find("%f[%w]or%f[^%w]")
		or flat:find("%f[%w]not%f[^%w]") then return nil end
	-- Leading keyword (return(x):... style) means the scan
	-- swallowed a statement keyword: leave it alone.
	local firstWord = receiver:match("^(%a+)")
	if firstWord == "return" or firstWord == "local" or firstWord == "if"
		or firstWord == "then" or firstWord == "else" or firstWord == "elseif"
		or firstWord == "while" or firstWord == "for" or firstWord == "do"
		or firstWord == "and" or firstWord == "or" or firstWord == "not"
		or firstWord == "function" or firstWord == "repeat" or firstWord == "until"
		or firstWord == "in" or firstWord == "break" then
		return nil
	end
	return receiver, j + 1
end

-- Find the ")" closing the call opened at `openPos`,
-- skipping strings, comments and longstrings.
local function findCloseParen(src, openPos, n)
	local depth = 1
	local m = openPos + 1
	local state = "code"
	local quote = nil
	local longLevel = 0
	while m <= n do
		local c = src:sub(m, m)
		local two = src:sub(m, m + 1)
		if state == "code" then
			if two == "--" then
				local level = src:sub(m + 2):match("^%[(=*)%[")
				if level ~= nil then
					state = "blockcomment"
					longLevel = #level
					m = m + 4 + longLevel
				else
					state = "linecomment"
					m = m + 2
				end
			elseif c == '"' or c == "'" then
				state = "string"
				quote = c
				m = m + 1
			elseif c == "[" then
				local level = src:sub(m):match("^%[(=*)%[")
				if level ~= nil then
					state = "longstring"
					longLevel = #level
					m = m + 2 + longLevel
				else
					m = m + 1
				end
			elseif c == "(" then
				depth = depth + 1
				m = m + 1
			elseif c == ")" then
				depth = depth - 1
				if depth == 0 then return m end
				m = m + 1
			else
				m = m + 1
			end
		elseif state == "string" then
			if c == "\\" then m = m + 2
			elseif c == quote then state = "code"; m = m + 1
			else m = m + 1 end
		elseif state == "linecomment" then
			if c == "\n" then state = "code" end
			m = m + 1
		else -- blockcomment or longstring
			local closer = "]" .. string.rep("=", longLevel) .. "]"
			if src:sub(m, m + #closer - 1) == closer then
				state = "code"
				m = m + #closer
			else
				m = m + 1
			end
		end
	end
	return nil
end

-- Method spellings that can also be called with a string
-- literal and no parens (:findFirstChild'Torso'), which the
-- REPLACEMENTS paren patterns miss. Built from REPLACEMENTS
-- so the two stay in sync: lowercase method name ->
-- canonical ":Name" (the pass adds the paren back).
local METHOD_STRINGCALL = {}
for _, r in ipairs(REPLACEMENTS) do
	if r[1]:sub(1, 1) == ":" and r[1]:sub(-2) == "%(" then
		METHOD_STRINGCALL[r[1]:sub(2, -3):lower()] = r[2]:sub(1, -2)
	end
end

-- :method'STR' / :method"STR" -> :Method('STR') / :Method("STR").
-- Without this, :findFirstChild'Torso' reaches a real
-- Instance untouched and dies on the lowercase spelling.
local function fixStringCallMethods(source)
	return scanCode(source, function(src, i, n)
		if src:sub(i, i) ~= ":" then return nil end
		local name = src:match("^[A-Za-z]+", i + 1)
		if name == nil then return nil end
		local canon = METHOD_STRINGCALL[name:lower()]
		if canon == nil then return nil end
		local j = i + 1 + #name
		while src:sub(j, j) == " " or src:sub(j, j) == "\t" do j = j + 1 end
		local q = src:sub(j, j)
		if q ~= '"' and q ~= "'" then return nil end
		local k = j + 1
		while k <= n do
			local ch = src:sub(k, k)
			if ch == "\\" then k = k + 2
			elseif ch == q then break
			elseif ch == "\n" then break
			else k = k + 1 end
		end
		if src:sub(k, k) ~= q then return nil end
		return i, k, canon .. "(" .. src:sub(j, k) .. ")"
	end)
end

-- R6 limb names that also need an R15 fallback when the
-- lookup runs on a REAL model (another player's character,
-- where the R6 character proxy does not apply).
local LIMB_NAMES = {
	Torso = true,
	["Left Arm"] = true,
	["Right Arm"] = true,
	["Left Leg"] = true,
	["Right Leg"] = true,
}

-- X:FindFirstChild("Torso"[, recursive]) ->
-- __sbFindLimb(X, "Torso"[, recursive]). The literal name
-- is tried first inside the helper, so R6 characters are
-- unchanged and R15 characters resolve to UpperTorso etc.
local function fixLimbLookups(source)
	return scanCode(source, function(src, i, n)
		if src:sub(i, i) ~= ":" then return nil end
		if src:sub(i, i + 14) ~= ":FindFirstChild" then return nil end
		local j = i + 15
		while src:sub(j, j) == " " or src:sub(j, j) == "\t" do j = j + 1 end
		if src:sub(j, j) ~= "(" then return nil end
		local openParen = j
		j = j + 1
		while src:sub(j, j) == " " or src:sub(j, j) == "\t" do j = j + 1 end
		local q = src:sub(j, j)
		if q ~= '"' and q ~= "'" then return nil end
		local k = j + 1
		local name = nil
		while k <= n do
			local ch = src:sub(k, k)
			if ch == "\\" then k = k + 2
			elseif ch == q then name = src:sub(j + 1, k - 1); break
			elseif ch == "\n" then break
			else k = k + 1 end
		end
		if name == nil or not LIMB_NAMES[name] then return nil end
		local closePos = findCloseParen(src, openParen, n)
		if closePos == nil then return nil end
		local receiver, recvStart = captureReceiver(src, i)
		if receiver == nil then return nil end
		local rest = src:sub(k + 1, closePos - 1)
		return recvStart, closePos, "__sbFindLimb(" .. receiver .. ", " .. src:sub(j, k) .. rest .. ")"
	end)
end

-- X.Mesh (old child-dot access) -> __sbMesh(X). No Instance
-- has a Mesh property, so a dotted .Mesh is always a child
-- lookup in old scripts; writes (X.Mesh = ...) are left
-- alone because a call result cannot be assigned to.
local function fixMeshAccess(source)
	return scanCode(source, function(src, i, n)
		if src:sub(i, i) ~= "." then return nil end
		if src:sub(i, i + 4) ~= ".Mesh" then return nil end
		if src:sub(i + 5, i + 5):match("[%w_]") then return nil end
		local j = i + 5
		while src:sub(j, j) == " " or src:sub(j, j) == "\t" do j = j + 1 end
		if src:sub(j, j) == "=" and src:sub(j + 1, j + 1) ~= "=" then return nil end
		local receiver, recvStart = captureReceiver(src, i)
		if receiver == nil then return nil end
		return recvStart, i + 4, "__sbMesh(" .. receiver .. ")"
	end)
end

-- Enum-typed properties assigned a literal in old scripts.
-- Modern Luau requires an EnumItem there: a number or a
-- string errors. numbers lists the value for 0, 1, 2, ...
-- (only for properties old scripts actually set by number);
-- names lists the valid string spellings. Anything else
-- (an expression, an unknown string, an out-of-range
-- number) is left alone.
local SURFACE_NAMES = {
	Smooth = true, Glue = true, Weld = true, Studs = true,
	Inlet = true, Universal = true, Hinge = true, Motor = true,
	SteppingMotor = true, SmoothNoOutlines = true,
}
local SURFACE_NUMBERS = {
	"Smooth", "Glue", "Weld", "Studs", "Inlet",
	"Universal", "Hinge", "Motor", "SteppingMotor",
}
local ENUM_PROPS = {
	TopSurface = { enum = "SurfaceType", names = SURFACE_NAMES, numbers = SURFACE_NUMBERS },
	BottomSurface = { enum = "SurfaceType", names = SURFACE_NAMES, numbers = SURFACE_NUMBERS },
	LeftSurface = { enum = "SurfaceType", names = SURFACE_NAMES, numbers = SURFACE_NUMBERS },
	RightSurface = { enum = "SurfaceType", names = SURFACE_NAMES, numbers = SURFACE_NUMBERS },
	FrontSurface = { enum = "SurfaceType", names = SURFACE_NAMES, numbers = SURFACE_NUMBERS },
	BackSurface = { enum = "SurfaceType", names = SURFACE_NAMES, numbers = SURFACE_NUMBERS },
	FormFactor = { enum = "FormFactor",
		names = { Symmetric = true, Brick = true, Plate = true, Custom = true },
		numbers = { "Symmetric", "Brick", "Plate", "Custom" } },
	MeshType = { enum = "MeshType",
		names = { Head = true, Torso = true, Wedge = true, Sphere = true,
			Cylinder = true, FileMesh = true, Brick = true, Prism = true,
			Pyramid = true, ParallelRamp = true, RightAngleRamp = true,
			CornerWedge = true } },
	FontSize = { enum = "FontSize",
		names = { Size8 = true, Size9 = true, Size10 = true, Size11 = true,
			Size12 = true, Size14 = true, Size18 = true, Size24 = true,
			Size28 = true, Size32 = true, Size36 = true, Size48 = true,
			Size60 = true, Size96 = true } },
	Font = { enum = "Font",
		names = { Legacy = true, Arial = true, ArialBold = true,
			SourceSans = true, SourceSansBold = true, SourceSansSemibold = true,
			SourceSansLight = true, SourceSansItalic = true, Gotham = true,
			GothamBold = true, GothamSemibold = true, GothamMedium = true,
			GothamBlack = true, Code = true, Cartoon = true, Fantasy = true } },
	Material = { enum = "Material",
		names = { Plastic = true, SmoothPlastic = true, Neon = true,
			Wood = true, WoodPlanks = true, Marble = true, Slate = true,
			Concrete = true, Metal = true, DiamondPlate = true, Foil = true,
			Grass = true, Ice = true, Glass = true, Granite = true,
			Brick = true, Cobblestone = true, Rock = true, Sand = true,
			Snow = true, Cardboard = true, Clay = true } },
	BinType = { enum = "BinType",
		names = { Script = true, GameTool = true, Grab = true,
			Clone = true, Hammer = true },
		numbers = { "Script", "GameTool", "Grab", "Clone", "Hammer" } },
	Shape = { enum = "PartType",
		names = { Ball = true, Block = true, Cylinder = true } },
}

local function fixEnumLiterals(source)
	return scanCode(source, function(src, i, n)
		if src:sub(i, i) ~= "." then return nil end
		local prop = src:match("^([A-Z][%w_]*)", i + 1)
		if prop == nil then return nil end
		local spec = ENUM_PROPS[prop]
		if spec == nil then return nil end
		local j = i + 1 + #prop
		if src:sub(j, j):match("[%w_]") then return nil end
		while src:sub(j, j) == " " or src:sub(j, j) == "\t" do j = j + 1 end
		if src:sub(j, j) ~= "=" then return nil end
		if src:sub(j + 1, j + 1) == "=" then return nil end
		j = j + 1
		while src:sub(j, j) == " " or src:sub(j, j) == "\t" do j = j + 1 end
		local ch = src:sub(j, j)
		local enumName = nil
		local nextI = nil
		if ch == '"' or ch == "'" then
			local k = j + 1
			while k <= n do
				local c2 = src:sub(k, k)
				if c2 == "\\" then k = k + 2
				elseif c2 == ch then break
				elseif c2 == "\n" then break
				else k = k + 1 end
			end
			if src:sub(k, k) ~= ch then return nil end
			local val = src:sub(j + 1, k - 1)
			if not spec.names[val] then return nil end
			enumName = val
			nextI = k + 1
		elseif ch:match("%d") then
			local numStr = src:match("^(%d+)", j)
			if numStr == nil then return nil end
			if src:sub(j + #numStr, j + #numStr):match("[%w_%.]") then return nil end
			if spec.numbers == nil then return nil end
			enumName = spec.numbers[tonumber(numStr) + 1]
			if enumName == nil then return nil end
			nextI = j + #numStr
		else
			return nil
		end
		return i, nextI - 1, "." .. prop .. " = Enum." .. spec.enum .. "." .. enumName
	end)
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

	-- v16.1 passes (order matters: string-call first so the
	-- limb pass sees paren form; limb/mesh/enum before the
	-- proxy unwrap so it wraps their final right-hand sides).
	local rewritten = fixStringCallMethods(fixed)
	if rewritten ~= fixed then
		fixed = rewritten
		notes[#notes + 1] = "Old string-call methods (:findFirstChild'Torso') -> paren form."
	end
	rewritten = fixLimbLookups(fixed)
	if rewritten ~= fixed then
		fixed = rewritten
		notes[#notes + 1] = "R6 limb lookups (:FindFirstChild(\"Torso\") etc.) -> __sbFindLimb, so they also find the R15 part."
	end
	rewritten = fixMeshAccess(fixed)
	if rewritten ~= fixed then
		fixed = rewritten
		notes[#notes + 1] = "Old child-dot access (.Mesh) -> __sbMesh."
	end
	rewritten = fixEnumLiterals(fixed)
	if rewritten ~= fixed then
		fixed = rewritten
		notes[#notes + 1] = "Old enum literals (.TopSurface = 0, .MeshType = \"Wedge\", .FontSize = \"Size12\") -> Enum items."
	end

	local wrapped = wrapProxyAssignments(fixed)
	if wrapped ~= fixed then
		fixed = wrapped
		notes[#notes + 1] = "Sandbox proxy tables unwrapped for .Parent / .PlayerToHideFrom / .Adornee, including table fields like {Parent = script} (LocalPlayer and R15 characters are proxy tables; the engine needs real Instances there)."
	end

	-- Hard blocks, reported as notes (the sandbox enforces them too).
	if fixed:find("Instance%.new%(%s*[\"']Script[\"']") or fixed:find("Instance%.new%(%s*[\"']LocalScript[\"']") then
		notes[#notes + 1] = "Creating Script/LocalScript objects with Instance.new runs them through the sandbox (server Scripts in a fresh sandbox env, LocalScripts through NLS) once Source and Parent are both set."
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

	-- v16.1 passes (same as the server pass, minus the proxy
	-- unwrap: the client has no __sbUnwrap, and NLS defines
	-- __sbFindLimb/__sbMesh at the top when they are used).
	local rewritten = fixStringCallMethods(fixed)
	if rewritten ~= fixed then
		fixed = rewritten
		notes[#notes + 1] = "Old string-call methods (:findFirstChild'Torso') -> paren form."
	end
	rewritten = fixLimbLookups(fixed)
	if rewritten ~= fixed then
		fixed = rewritten
		notes[#notes + 1] = "R6 limb lookups (:FindFirstChild(\"Torso\") etc.) -> __sbFindLimb, so they also find the R15 part."
	end
	rewritten = fixMeshAccess(fixed)
	if rewritten ~= fixed then
		fixed = rewritten
		notes[#notes + 1] = "Old child-dot access (.Mesh) -> __sbMesh."
	end
	rewritten = fixEnumLiterals(fixed)
	if rewritten ~= fixed then
		fixed = rewritten
		notes[#notes + 1] = "Old enum literals (.TopSurface = 0, .MeshType = \"Wedge\", .FontSize = \"Size12\") -> Enum items."
	end

	return fixed, notes
end

return Fixer
