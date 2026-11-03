-- Gui (LocalScript, StarterGui)
-- Builds the whole editor UI in code, so there is nothing to lay out
-- by hand in Studio. The client NEVER creates game parts: Execute
-- only sends the text to the server, and the server runs it.
-- v3 also forwards this player's real input (keys, mouse buttons,
-- mouse position) to the server, but ONLY through that player's
-- own ScriptBuilderInput_<UserId>/Input remote, so a running
-- script's mouse.KeyDown / Button1Down / mouse.Hit actually work.
--
-- Syntax highlighting trick (standard for Roblox editors):
--   The editable TextBox sits on top with transparent text, and a
--   RichText TextLabel directly behind it shows the same text in
--   colour. Both use Enum.Font.Code at the same size, so they line
--   up. The TextBox still draws its caret and selection on top.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local ExecuteScript = ReplicatedStorage:WaitForChild("ExecuteScript")
local ScriptOutput = ReplicatedStorage:WaitForChild("ScriptOutput")
local ClearScripts = ReplicatedStorage:WaitForChild("ClearScripts")
local FetchScriptLink = ReplicatedStorage:WaitForChild("FetchScriptLink")
local ConvertScript = ReplicatedStorage:WaitForChild("ConvertScript")
local ConvertResult = ReplicatedStorage:WaitForChild("ConvertResult")
local AssetRepairReport = ReplicatedStorage:WaitForChild("AssetRepairReport")

--------------------------------------------------------------------------------
-- Highlighter (client-side only, for display)
--------------------------------------------------------------------------------

local KEYWORDS = {}
for _, k in ipairs({
	"and", "break", "do", "else", "elseif", "end", "false", "for",
	"function", "if", "in", "local", "nil", "not", "or", "repeat",
	"return", "then", "true", "until", "while",
}) do KEYWORDS[k] = true end

local BUILTINS = {}
for _, k in ipairs({
	"Instance", "Vector3", "Vector2", "CFrame", "BrickColor", "Color3",
	"UDim", "UDim2", "Enum", "workspace", "game", "script", "player",
	"print", "warn", "pairs", "ipairs", "tostring", "tonumber",
	"task", "wait", "spawn", "delay", "math", "string", "table",
}) do BUILTINS[k] = true end

local C = {
	keyword = "#FF7AB8", -- pink
	builtin = "#7AC7FF", -- blue
	string = "#A8E6A1", -- green
	comment = "#7D7D7D", -- grey
	number = "#FFC46B", -- orange
	plain = "#E8E8E8",
}

local function escapeRich(s)
	s = s:gsub("&", "&amp;")
	s = s:gsub("<", "&lt;")
	s = s:gsub(">", "&gt;")
	s = s:gsub('"', "&quot;")
	return s
end

local function wrap(color, text)
	return '<font color="' .. color .. '">' .. escapeRich(text) .. "</font>"
end

local function highlight(source)
	local out = {}
	local i = 1
	local n = #source
	while i <= n do
		local c = source:sub(i, i)
		local two = source:sub(i, i + 1)
		if two == "--" then
			local level = source:sub(i + 2):match("^%[(=*)%[")
			if level ~= nil then
				local closer = "]" .. level .. "]"
				local closeAt = source:find(closer, i + 4 + #level, true)
				local chunk = closeAt and source:sub(i, closeAt + #closer - 1) or source:sub(i)
				out[#out + 1] = wrap(C.comment, chunk)
				i = closeAt and (closeAt + #closer) or (n + 1)
			else
				local nl = source:find("\n", i, true)
				local chunk = nl and source:sub(i, nl - 1) or source:sub(i)
				out[#out + 1] = wrap(C.comment, chunk)
				i = nl and nl or (n + 1)
			end
		elseif c == '"' or c == "'" then
			local quote = c
			local j = i + 1
			while j <= n do
				local ch = source:sub(j, j)
				if ch == "\\" then j = j + 2
				elseif ch == quote then break
				else j = j + 1 end
			end
			local chunk = source:sub(i, math.min(j, n))
			out[#out + 1] = wrap(C.string, chunk)
			i = j + 1
		elseif c == "[" then
			local level = source:sub(i):match("^%[(=*)%[")
			if level ~= nil then
				local closer = "]" .. level .. "]"
				local closeAt = source:find(closer, i + 2 + #level, true)
				local chunk = closeAt and source:sub(i, closeAt + #closer - 1) or source:sub(i)
				out[#out + 1] = wrap(C.string, chunk)
				i = closeAt and (closeAt + #closer) or (n + 1)
			else
				out[#out + 1] = escapeRich(c)
				i = i + 1
			end
		elseif c:match("%d") or (c == "." and source:sub(i + 1, i + 1):match("%d")) then
			local num = source:sub(i):match("^0[xX][0-9a-fA-F]+")
				or source:sub(i):match("^%.%d+[eE][%+%-]?%d+")
				or source:sub(i):match("^%.%d+")
				or source:sub(i):match("^%d+%.?%d*[eE][%+%-]?%d+")
				or source:sub(i):match("^%d+%.%d*")
				or source:sub(i):match("^%d+")
			if num then
				out[#out + 1] = wrap(C.number, num)
				i = i + #num
			else
				out[#out + 1] = escapeRich(c)
				i = i + 1
			end
		elseif c:match("[%a_]") then
			local word = source:sub(i):match("^[%a_][%w_]*")
			if KEYWORDS[word] then
				out[#out + 1] = wrap(C.keyword, word)
			elseif BUILTINS[word] then
				out[#out + 1] = wrap(C.builtin, word)
			else
				out[#out + 1] = escapeRich(word)
			end
			i = i + #word
		else
			out[#out + 1] = escapeRich(c)
			i = i + 1
		end
	end
	return table.concat(out)
end

local function splitLines(s)
	local lines = {}
	for line in (s .. "\n"):gmatch("([^\n]*)\n") do
		lines[#lines + 1] = line
	end
	return lines
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

-- Exactly one builder GUI (v16.1): this LocalScript lives in
-- StarterGui, so it re-runs on every respawn, while the GUI
-- itself survives respawn (ResetOnSpawn = false below).
-- Without this cleanup each death stacked another full
-- window (and another Open Builder button). The old
-- window's editor text and open/closed state are captured
-- first, so the replacement keeps what the player was
-- doing; with several stale windows (from before this fix)
-- the first one's state wins.
local savedText = nil
local savedMainVisible = nil
local savedMiniVisible = nil
local capturedOld = false
for _, existing in ipairs(playerGui:GetChildren()) do
	if existing:IsA("ScreenGui") and existing.Name == "ScriptBuilderGui" then
		if not capturedOld then
			capturedOld = true
			local oldMain = existing:FindFirstChild("Main", true)
			if oldMain then
				savedMainVisible = oldMain.Visible
				local oldCode = oldMain:FindFirstChild("CodeBox", true)
				if oldCode then savedText = oldCode.Text end
			end
			local oldMini = existing:FindFirstChild("OpenBuilder", true)
			if oldMini then savedMiniVisible = oldMini.Visible end
		end
		existing:Destroy()
	end
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "ScriptBuilderGui"
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

local main = Instance.new("Frame")
main.Name = "Main"
main.AnchorPoint = Vector2.new(0.5, 0.5)
main.Position = UDim2.new(0.5, 0, 0.5, 0)
-- Smaller than before: 640x440 instead of 760x520.
main.Size = UDim2.new(0, 640, 0, 440)
main.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
main.BorderSizePixel = 0
main.Parent = screenGui

-- Small reopen button, bottom-right corner, hidden until the
-- main window is closed with the X.
local miniButton = Instance.new("TextButton")
miniButton.Name = "OpenBuilder"
miniButton.Size = UDim2.new(0, 110, 0, 36)
miniButton.Position = UDim2.new(1, -120, 1, -46)
miniButton.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
miniButton.BorderSizePixel = 0
miniButton.Font = Enum.Font.GothamBold
miniButton.TextSize = 13
miniButton.TextColor3 = Color3.fromRGB(255, 255, 255)
miniButton.Text = "Open Builder"
miniButton.Visible = false
miniButton.Parent = screenGui

local topBar = Instance.new("Frame")
topBar.Name = "TopBar"
topBar.Size = UDim2.new(1, 0, 0, 40)
topBar.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
topBar.BorderSizePixel = 0
topBar.Active = true
topBar.Parent = main

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -290, 1, 0)
title.Position = UDim2.new(0, 12, 0, 0)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = Color3.fromRGB(240, 240, 240)
title.Text = "Script Builder"
title.Parent = topBar

local function makeButton(name, text, x, width, color)
	local b = Instance.new("TextButton")
	b.Name = name
	b.Size = UDim2.new(0, width, 0, 28)
	b.Position = UDim2.new(1, x, 0, 6)
	b.BackgroundColor3 = color
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamBold
	b.TextSize = 13
	b.TextColor3 = Color3.fromRGB(255, 255, 255)
	b.Text = text
	b.Parent = topBar
	return b
end

local executeButton = makeButton("Execute", "Execute", -268, 70, Color3.fromRGB(46, 160, 67))
local clearButton = makeButton("Clear", "Clear", -194, 60, Color3.fromRGB(180, 60, 60))
local clearBuildsButton = makeButton("ClearBuilds", "Clear Builds", -112, 76, Color3.fromRGB(90, 90, 110))
local closeButton = makeButton("Close", "X", -36, 30, Color3.fromRGB(60, 60, 70))

closeButton.MouseButton1Click:Connect(function()
	main.Visible = false
	miniButton.Visible = true
end)

miniButton.MouseButton1Click:Connect(function()
	miniButton.Visible = false
	main.Visible = true
end)

-- Link bar (v12, second row): a URL field + Fetch, a Convert
-- button, and page navigation. The editor below it is paged
-- (see Paging below), so no single Text property ever holds a
-- whole huge script - that is what broke the GUI on long pastes.

local linkBar = Instance.new("Frame")
linkBar.Name = "LinkBar"
linkBar.Position = UDim2.new(0, 0, 0, 40)
linkBar.Size = UDim2.new(1, 0, 0, 28)
linkBar.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
linkBar.BorderSizePixel = 0
linkBar.Parent = main

local linkBox = Instance.new("TextBox")
linkBox.Name = "LinkBox"
linkBox.Position = UDim2.new(0, 8, 0, 4)
linkBox.Size = UDim2.new(0, 300, 0, 20)
linkBox.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
linkBox.BorderSizePixel = 0
linkBox.Font = Enum.Font.Code
linkBox.TextSize = 12
linkBox.TextXAlignment = Enum.TextXAlignment.Left
linkBox.ClearTextOnFocus = false
linkBox.TextColor3 = Color3.fromRGB(220, 220, 220)
linkBox.PlaceholderColor3 = Color3.fromRGB(130, 130, 140)
linkBox.PlaceholderText = "Paste a script link (pastebin / github raw...)"
linkBox.Text = ""
linkBox.Parent = linkBar

local function makeLinkButton(name, text, x, width, color)
	local b = Instance.new("TextButton")
	b.Name = name
	b.Size = UDim2.new(0, width, 0, 20)
	b.Position = UDim2.new(0, x, 0, 4)
	b.BackgroundColor3 = color
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamBold
	b.TextSize = 12
	b.TextColor3 = Color3.fromRGB(255, 255, 255)
	b.Text = text
	b.Parent = linkBar
	return b
end

local fetchButton = makeLinkButton("Fetch", "Fetch", 314, 60, Color3.fromRGB(46, 120, 200))
local convertButton = makeLinkButton("Convert", "Convert", 380, 70, Color3.fromRGB(140, 90, 180))
local prevPageButton = makeLinkButton("PrevPage", "<", 460, 30, Color3.fromRGB(60, 60, 70))
local pageLabel = Instance.new("TextLabel")
pageLabel.Name = "PageLabel"
pageLabel.Position = UDim2.new(0, 494, 0, 4)
pageLabel.Size = UDim2.new(0, 70, 0, 20)
pageLabel.BackgroundTransparency = 1
pageLabel.Font = Enum.Font.Code
pageLabel.TextSize = 12
pageLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
pageLabel.Text = "Page 1 of 1"
pageLabel.Parent = linkBar
local nextPageButton = makeLinkButton("NextPage", ">", 568, 30, Color3.fromRGB(60, 60, 70))

-- Dragging: drag by the top bar only, so selecting text in the
-- editor never moves the window. Custom dragging (not the
-- deprecated GuiObject.Draggable) so it works on mouse and touch.
local dragging = false
local dragStart = Vector2.new(0, 0)
local startPos = main.Position
local function startDrag(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging = true
		dragStart = input.Position
		startPos = main.Position
	end
end
topBar.InputBegan:Connect(startDrag)
title.InputBegan:Connect(startDrag)
UserInputService.InputChanged:Connect(function(input)
	if not dragging then return end
	if input.UserInputType == Enum.UserInputType.MouseMovement
		or input.UserInputType == Enum.UserInputType.Touch then
		local delta = input.Position - dragStart
		main.Position = UDim2.new(
			startPos.X.Scale, startPos.X.Offset + delta.X,
			startPos.Y.Scale, startPos.Y.Offset + delta.Y
		)
	end
end)
UserInputService.InputEnded:Connect(function(input)
	if input.UserInputType == Enum.UserInputType.MouseButton1
		or input.UserInputType == Enum.UserInputType.Touch then
		dragging = false
	end
end)

local editorScroll = Instance.new("ScrollingFrame")
editorScroll.Name = "EditorScroll"
editorScroll.Position = UDim2.new(0, 0, 0, 68)
editorScroll.Size = UDim2.new(1, 0, 1, -112)
editorScroll.BackgroundColor3 = Color3.fromRGB(18, 18, 24)
editorScroll.BorderSizePixel = 0
editorScroll.ScrollBarThickness = 6
editorScroll.CanvasSize = UDim2.new(0, 0, 0, 340)
editorScroll.Parent = main

local lineNumbers = Instance.new("TextLabel")
lineNumbers.Name = "LineNumbers"
lineNumbers.Size = UDim2.new(0, 44, 1, 0)
lineNumbers.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
lineNumbers.BorderSizePixel = 0
lineNumbers.Font = Enum.Font.Code
lineNumbers.TextSize = 14
lineNumbers.TextXAlignment = Enum.TextXAlignment.Right
lineNumbers.TextYAlignment = Enum.TextYAlignment.Top
lineNumbers.TextColor3 = Color3.fromRGB(120, 120, 130)
lineNumbers.Text = "1"
lineNumbers.Parent = editorScroll

local highlightLabel = Instance.new("TextLabel")
highlightLabel.Name = "Highlight"
highlightLabel.Position = UDim2.new(0, 52, 0, 4)
highlightLabel.Size = UDim2.new(1, -60, 0, 340)
highlightLabel.BackgroundTransparency = 1
highlightLabel.Font = Enum.Font.Code
highlightLabel.TextSize = 14
highlightLabel.TextXAlignment = Enum.TextXAlignment.Left
highlightLabel.TextYAlignment = Enum.TextYAlignment.Top
highlightLabel.TextWrapped = true
highlightLabel.RichText = true
highlightLabel.TextColor3 = Color3.fromRGB(232, 232, 232)
highlightLabel.Text = ""
highlightLabel.Parent = editorScroll

local codeBox = Instance.new("TextBox")
codeBox.Name = "CodeBox"
codeBox.Position = UDim2.new(0, 52, 0, 4)
codeBox.Size = UDim2.new(1, -60, 0, 340)
codeBox.BackgroundTransparency = 1
codeBox.Font = Enum.Font.Code
codeBox.TextSize = 14
codeBox.TextXAlignment = Enum.TextXAlignment.Left
codeBox.TextYAlignment = Enum.TextYAlignment.Top
codeBox.TextWrapped = true
codeBox.MultiLine = true
codeBox.ClearTextOnFocus = false
codeBox.TextColor3 = Color3.fromRGB(255, 255, 255)
-- Transparent text: the highlight label behind provides the colour.
-- The caret and selection from this box still draw on top.
codeBox.TextTransparency = 1
codeBox.PlaceholderColor3 = Color3.fromRGB(130, 130, 140)
codeBox.Text = [[-- Try me: press Execute.
local part = Instance.new("Part")
part.Parent = workspace
part.Size = Vector3.new(8, 1, 8)
part.Position = Vector3.new(0, 5, 0)
part.BrickColor = BrickColor.new("Bright red")
part.Anchored = true

for i = 1, 5 do
	local p = Instance.new("Part")
	p.Parent = workspace
	p.Size = Vector3.new(4, 1, 4)
	p.Position = Vector3.new(0, 6 + i * 2, 0)
	p.BrickColor = BrickColor.new("Bright blue")
	p.Anchored = true
	task.wait(0.1)
end

print("Built a tower!")
]]
codeBox.Parent = editorScroll

local status = Instance.new("TextLabel")
status.Name = "Status"
status.Position = UDim2.new(0, 0, 1, -44)
status.Size = UDim2.new(1, 0, 0, 44)
status.BackgroundColor3 = Color3.fromRGB(20, 20, 26)
status.BorderSizePixel = 0
status.Font = Enum.Font.Code
status.TextSize = 13
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.TextWrapped = true
status.TextColor3 = Color3.fromRGB(200, 200, 200)
status.Text = "Ready. Paste an old script-builder script, then press Execute."
status.Parent = main

--------------------------------------------------------------------------------
-- Sync: line numbers + highlighting + height
--------------------------------------------------------------------------------

local updating = false
local currentLineOffset = 1
local function refreshEditor()
	if updating then return end
	updating = true
	local source = codeBox.Text
	local lines = splitLines(source)
	local numbers = {}
	for i = 1, #lines do numbers[i] = tostring(currentLineOffset + i - 1) end
	lineNumbers.Text = table.concat(numbers, "\n")

	-- Keep the gutter tall enough to match the code area.
	local editorWidth = math.max(200, main.AbsoluteSize.X - 70)
	local measured = TextService:GetTextSize(
		source ~= "" and source or " ",
		14,
		Enum.Font.Code,
		Vector2.new(editorWidth, 100000)
	)
	local height = math.max(340, math.ceil(measured.Y) + 16)
	highlightLabel.Size = UDim2.new(1, -60, 0, height)
	codeBox.Size = UDim2.new(1, -60, 0, height)
	lineNumbers.Size = UDim2.new(0, 44, 0, height)
	editorScroll.CanvasSize = UDim2.new(0, 0, 0, height + 8)
	-- Large-script fallback: Roblox Text caps at 200,000 chars.
	-- Even with plain tokens un-wrapped, a 200k script's
	-- highlighted form is over that cap, and the old code
	-- errored here with a 972,103-char string. For large
	-- scripts, show the codeBox text itself (visible, no
	-- colours) instead of a highlight label that cannot hold it.
	if #source > 150000 then
		codeBox.TextTransparency = 0
		highlightLabel.Text = ""
	else
		codeBox.TextTransparency = 1
		local highlighted = highlight(source)
		if #highlighted > 190000 then
			codeBox.TextTransparency = 0
			highlightLabel.Text = ""
		else
			local ok = pcall(function() highlightLabel.Text = highlighted end)
			if not ok then
				codeBox.TextTransparency = 0
				highlightLabel.Text = ""
			end
		end
	end
	updating = false
end

codeBox:GetPropertyChangedSignal("Text"):Connect(refreshEditor)

--------------------------------------------------------------------------------
-- Paging: any amount of text
--------------------------------------------------------------------------------
-- Roblox caps any single Text string at 200,000 characters, and
-- the old editor put the whole script in one TextBox + one
-- RichText label, so a huge paste broke the GUI. Now the full
-- script lives only in this client-side string (never assigned
-- to a Text property), split into pages of at most 500 lines
-- AND 50,000 characters, cut on line boundaries where possible
-- (a single line longer than 50,000 is hard-split by chars).
-- Concatenating the pages reproduces the source exactly, so
-- paging is lossless. Editing a page stores that page as-is;
-- re-splitting happens on load (initial, fetched, converted).

local fullSource = ""
local pages = { "" }
local currentPage = 1

local function splitIntoPages(source)
	local result = {}
	local pos = 1
	local n = #source
	if n == 0 then return { "" } end
	while pos <= n do
		local endPos = pos
		local lines = 0
		while endPos <= n and (endPos - pos) < 50000 and lines < 500 do
			if source:sub(endPos, endPos) == "\n" then
				lines = lines + 1
			end
			endPos = endPos + 1
		end
		result[#result + 1] = source:sub(pos, endPos - 1)
		pos = endPos
	end
	return result
end

local function pageLineOffset(pageIndex)
	local offset = 1
	for i = 1, pageIndex - 1 do
		local _, count = pages[i]:gsub("\n", "")
		offset = offset + count
	end
	return offset
end

local function showPage()
	currentLineOffset = pageLineOffset(currentPage)
	codeBox.Text = pages[currentPage] or ""
	pageLabel.Text = "Page " .. currentPage .. " of " .. #pages
		.. " (" .. #fullSource .. " chars)"
	refreshEditor()
end

local function savePage()
	pages[currentPage] = codeBox.Text
	fullSource = table.concat(pages)
end

local function loadSource(source)
	fullSource = source or ""
	pages = splitIntoPages(fullSource)
	currentPage = 1
	showPage()
end

loadSource(codeBox.Text)

-- v16.1 respawn restore: the guard above destroyed the old
-- window, so put its editor text and open/closed state back.
-- loadSource re-splits into pages, so the restored text
-- survives page switches too.
if savedText ~= nil then
	loadSource(savedText)
end
if savedMainVisible ~= nil then
	main.Visible = savedMainVisible
	if savedMiniVisible ~= nil then
		miniButton.Visible = savedMiniVisible
	end
end

--------------------------------------------------------------------------------
-- Buttons / server replies
--------------------------------------------------------------------------------

-- Scripts over one remote-sized fire are split into 8,192-char
-- chunks, matching Main.server.lua. Small scripts still go in
-- one FireServer, exactly as before, so old behaviour is kept.
local CHUNK_SIZE = 8192

local function sendInChunks(remote, source)
	if #source <= CHUNK_SIZE then
		remote:FireServer(source)
		return
	end
	local total = math.ceil(#source / CHUNK_SIZE)
	local uploadId = tostring(os.time()) .. "-" .. tostring(math.random(1, 999999))
	for i = 1, total do
		local chunk = source:sub((i - 1) * CHUNK_SIZE + 1, i * CHUNK_SIZE)
		remote:FireServer({
			chunkUpload = true,
			id = uploadId,
			index = i,
			total = total,
			chunk = chunk,
		})
		-- A beat between fires, so the server can queue them
		-- in order instead of dropping a burst.
		if i < total then task.wait(0.02) end
	end
end

executeButton.MouseButton1Click:Connect(function()
	savePage()
	local source = fullSource
	executeButton.Text = "Running..."
	if #source <= CHUNK_SIZE then
		status.Text = "Compiling with vLuau, then running on the server..."
		ExecuteScript:FireServer(source)
	else
		local total = math.ceil(#source / CHUNK_SIZE)
		status.Text = "Uploading " .. total .. " chunks, then compiling and running..."
		sendInChunks(ExecuteScript, source)
		status.Text = "Uploaded. Compiling with vLuau, then running..."
	end
	task.delay(1, function()
		executeButton.Text = "Execute"
	end)
end)

clearButton.MouseButton1Click:Connect(function()
	fullSource = ""
	pages = { "" }
	currentPage = 1
	showPage()
	status.Text = "Editor cleared. (Your builds stay until you press Clear Builds.)"
end)

clearBuildsButton.MouseButton1Click:Connect(function()
	status.Text = "Clearing your builds..."
	ClearScripts:FireServer()
end)

fetchButton.MouseButton1Click:Connect(function()
	local url = linkBox.Text
	if url == "" then
		status.Text = "Paste a link in the link field first."
		return
	end
	status.Text = "Fetching link (server-side, needs HTTP enabled)..."
	FetchScriptLink:FireServer(url)
end)

convertButton.MouseButton1Click:Connect(function()
	savePage()
	status.Text = "Converting (FE-off -> FE-on)..."
	sendInChunks(ConvertScript, fullSource)
end)

prevPageButton.MouseButton1Click:Connect(function()
	if currentPage <= 1 then return end
	savePage()
	currentPage = currentPage - 1
	showPage()
end)

nextPageButton.MouseButton1Click:Connect(function()
	if currentPage >= #pages then return end
	savePage()
	currentPage = currentPage + 1
	showPage()
end)

ConvertResult.OnClientEvent:Connect(function(fixed, notes)
	loadSource(fixed)
	local parts = { "Converted. The editor now holds the converted version - press Execute to run it, or copy it out." }
	if notes then
		for _, note in ipairs(notes) do
			parts[#parts + 1] = "• " .. note
		end
	end
	status.Text = table.concat(parts, "\n")
	status.TextColor3 = Color3.fromRGB(170, 230, 170)
end)

ScriptOutput.OnClientEvent:Connect(function(success, message, notes, outputLines, fetchedSource)
	if fetchedSource ~= nil then
		-- A fetched link: load it into the editor pages first,
		-- so the user can see (and edit) what just ran.
		loadSource(fetchedSource)
	end
	local parts = {}
	if success then
		parts[#parts + 1] = "OK: " .. tostring(message)
	else
		parts[#parts + 1] = tostring(message)
	end
	if outputLines then
		for _, line in ipairs(outputLines) do
			parts[#parts + 1] = line
		end
	end
	if notes then
		for _, note in ipairs(notes) do
			parts[#parts + 1] = "• " .. note
		end
	end
	local joined = table.concat(parts, "\n")
	if #joined > 50000 then joined = joined:sub(1, 50000) .. "\n... (output truncated)" end
	status.Text = joined
	status.TextColor3 = success and Color3.fromRGB(170, 230, 170) or Color3.fromRGB(255, 170, 170)
end)

-- Asset repair reports arrive after the run finished, on their
-- own remote, so they APPEND to whatever the status bar shows
-- instead of replacing the "Ran OK" message. The bar keeps
-- its tail, capped at 50000 chars, so a long repair log does
-- not push the run result out of view.
AssetRepairReport.OnClientEvent:Connect(function(text)
	local current = status.Text or ""
	local joined = current .. "\n" .. tostring(text)
	if #joined > 50000 then joined = "... (older output truncated)\n" .. joined:sub(#joined - 49999) end
	status.Text = joined
end)

--------------------------------------------------------------------------------
-- Per-player input forwarding (v3)
--------------------------------------------------------------------------------
-- Why this exists: mouse and keys cannot exist on the server, but
-- they can be SENT to the server when they happen, and that is
-- exactly what old scripts expect from mouse.KeyDown, Button1Down,
-- mouse.Hit, and mouse.Target. The server created one Input
-- remote for this player only; this client waits for that remote
-- and never touches another player's. Forwarding runs whether
-- the builder window is open or closed, so attacks work after
-- you close it with the X.

local inputRemote = nil

-- The server creates the folder on PlayerAdded, so it should
-- already exist, but retry instead of giving up on a race.
task.spawn(function()
	while not inputRemote do
		local folder = ReplicatedStorage:WaitForChild("ScriptBuilderInput_" .. player.UserId, 5)
		if folder then
			inputRemote = folder:WaitForChild("Input", 5)
		end
		if not inputRemote then task.wait(1) end
	end
end)

-- Old mouse.KeyDown keys are strings, not KeyCodes: "h", "y",
-- "4". Map KeyCode.Name to that string, so scripts checking
-- key == "h" or string.byte(key) == 52 keep working.
local KEY_STRING = {
	Zero = "0", One = "1", Two = "2", Three = "3", Four = "4",
	Five = "5", Six = "6", Seven = "7", Eight = "8", Nine = "9",
	Minus = "-", Equals = "=", LeftBracket = "[", RightBracket = "]",
	Backslash = "\\", Semicolon = ";", Quote = "'", Comma = ",",
	Period = ".", Slash = "/", Backquote = "`", Space = " ",
	Tab = "\t", Return = "\r",
}
local function oldKeyString(keyCode)
	local name = keyCode.Name
	if KEY_STRING[name] then return KEY_STRING[name] end
	-- Single letters come through as "H", "Y", and so on.
	return string.lower(name)
end

-- Never forward a key while the player is typing, in the editor
-- or anywhere else. Without this, typing "h" in a script would
-- fire a script's h-attack, and clicking Execute would fire
-- its Button1Down. gameProcessedEvent covers GUI clicks; the
-- focused TextBox check covers typing.
local function shouldForward(gameProcessed)
	if gameProcessed then return false end
	if UserInputService:GetFocusedTextBox() ~= nil then return false end
	return true
end

local realMouse = player:GetMouse()
local lastMouseSent = 0

local function sendMouse(force)
	if not inputRemote then return end
	local now = os.clock()
	if not force and now - lastMouseSent < 0.05 then return end
	lastMouseSent = now
	local camera = workspace.CurrentCamera
	local viewSizeX, viewSizeY = 0, 0
	if camera then
		viewSizeX = camera.ViewportSize.X
		viewSizeY = camera.ViewportSize.Y
	end
	inputRemote:FireServer({
		type = "mouse",
		hit = realMouse.Hit,
		target = realMouse.Target,
		x = realMouse.X,
		y = realMouse.Y,
		viewSizeX = viewSizeX,
		viewSizeY = viewSizeY,
		rayOrigin = realMouse.UnitRay.Origin,
		rayDirection = realMouse.UnitRay.Direction,
	})
end

realMouse.Move:Connect(function()
	sendMouse(false)
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if not shouldForward(gameProcessed) or not inputRemote then return end
	if input.UserInputType == Enum.UserInputType.Keyboard then
		inputRemote:FireServer({ type = "keyDown", key = oldKeyString(input.KeyCode) })
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		sendMouse(true)
		inputRemote:FireServer({ type = "button1Down" })
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		sendMouse(true)
		inputRemote:FireServer({ type = "button2Down" })
	end
end)

UserInputService.InputEnded:Connect(function(input, gameProcessed)
	if not shouldForward(gameProcessed) or not inputRemote then return end
	if input.UserInputType == Enum.UserInputType.Keyboard then
		inputRemote:FireServer({ type = "keyUp", key = oldKeyString(input.KeyCode) })
	elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
		inputRemote:FireServer({ type = "button1Up" })
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		inputRemote:FireServer({ type = "button2Up" })
	end
end)

UserInputService.InputChanged:Connect(function(input, gameProcessed)
	if not shouldForward(gameProcessed) or not inputRemote then return end
	if input.UserInputType == Enum.UserInputType.MouseWheel then
		if input.Position.Z > 0 then
			inputRemote:FireServer({ type = "wheelForward" })
		elseif input.Position.Z < 0 then
			inputRemote:FireServer({ type = "wheelBackward" })
		end
	end
end)

--------------------------------------------------------------------------------
-- HopperBin selection forwarding (v16.1)
--------------------------------------------------------------------------------
-- Bin tools run on the server in the builder, but a bin's
-- Selected/Deselected only fires reliably on the client, so
-- the client forwards it: every HopperBin the builder made
-- (marked with an SB_BinId attribute) gets its local
-- Selected/Deselected connected, and each equip/unequip
-- sends one packet down the same Input remote. The server
-- fires the script's select() with the emulated mouse. Bins
-- without the attribute (game bins, not builder bins) are
-- left alone. Forwarding runs whether the builder window is
-- open or closed, like the mouse/key forwarding above.

task.spawn(function()
	local backpack = player:WaitForChild("Backpack")
	local binConnections = {}
	local function watchBin(bin)
		if not bin:IsA("HopperBin") then return end
		if binConnections[bin] ~= nil then return end
		local binId = bin:GetAttribute("SB_BinId")
		if binId == nil then return end
		local selConn = bin.Selected:Connect(function()
			if inputRemote then
				inputRemote:FireServer({ type = "bin", binId = binId, action = "selected" })
			end
		end)
		local deselConn = bin.Deselected:Connect(function()
			if inputRemote then
				inputRemote:FireServer({ type = "bin", binId = binId, action = "deselected" })
			end
		end)
		binConnections[bin] = { selConn, deselConn }
	end
	for _, child in ipairs(backpack:GetChildren()) do
		watchBin(child)
	end
	backpack.ChildAdded:Connect(watchBin)
	backpack.ChildRemoved:Connect(function(bin)
		local conns = binConnections[bin]
		if conns then
			for _, c in ipairs(conns) do
				pcall(function() c:Disconnect() end)
			end
			binConnections[bin] = nil
		end
	end)
end)
