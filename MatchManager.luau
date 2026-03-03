local MatchManager = {}

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local workspace = game:GetService("Workspace")

-- getting the external modules that handle powerups and gamemode settings
local PowerupManager = require(script.Parent.PowerupManager)
local GamemodeManager = require(script.Parent.GamemodeManager)

-- this table holds all the data for matches currently running, using the match id as the key
local activeMatches = {}
-- a quick lookup table to find which match a specific player is in without searching every match
local playerToMatchId = {}
local totalMatchesCreated = 0

-- checking if we are in a vip server to disable saving stats, so people don't farm wins
local isPrivateServer = game.PrivateServerId ~= "" and game.PrivateServerId ~= nil

-- basic constants for how the game rules work
local ROUNDS_TO_WIN = 3
local ROUND_DURATION = 45
local FREEZE_DURATION = 5 -- how long players are stuck in place before the round starts
local BETWEEN_ROUNDS_DELAY = 4
local LOADING_SCREEN_DURATION = 6

-- rewards given to players after the match ends
local WIN_REWARD_COINS = 150
local LOSS_REWARD_COINS = 50
local WIN_REWARD_XP = 150
local LOSS_REWARD_XP = 50

-- elo rating settings. these numbers decide how much rank you gain or lose
-- based on whether you beat someone better or worse than you
local ELO_WIN_VS_HIGHER = {min = 35, max = 50}
local ELO_WIN_VS_SAME = {min = 25, max = 35}
local ELO_WIN_VS_LOWER = {min = 10, max = 25}
local ELO_LOSS_VS_HIGHER = {min = 15, max = 20}
local ELO_LOSS_VS_SAME = {min = 20, max = 25}
local ELO_LOSS_VS_LOWER = {min = 25, max = 30}

-- helper function to make sure remote events exist before we use them.
-- if the remote is missing, it creates it to prevent the script from crashing.
local function getOrCreateRemote(name)
	local remote = ReplicatedStorage:FindFirstChild(name)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = ReplicatedStorage
	end
	return remote
end

-- creating all the network events needed for the client and server to talk
local taggerChanged = getOrCreateRemote("TaggerChanged")
local matchStarted = getOrCreateRemote("MatchStarted")
local matchEnded = getOrCreateRemote("MatchEnded")
local updateRoundTimer = getOrCreateRemote("UpdateRoundTimer")
local updateScores = getOrCreateRemote("UpdateScores")
local showFreezeCountdown = getOrCreateRemote("ShowFreezeCountdown")
local showWinner = getOrCreateRemote("ShowWinner")
local showRoundGui = getOrCreateRemote("ShowRoundGui")
local hideRoundGui = getOrCreateRemote("HideRoundGui")
local initialTaggerSet = getOrCreateRemote("InitialTaggerSet")
local roundTimeUp = getOrCreateRemote("RoundTimeUp")
local showLoadingScreen = getOrCreateRemote("ShowLoadingScreen")
local spectateWinner = getOrCreateRemote("SpectateWinner")
local hideRoleText = getOrCreateRemote("HideRoleText")
local manipulateStamina = getOrCreateRemote("ManipulateStamina")
local updateGamemodeConfig = getOrCreateRemote("UpdateGamemodeConfig")

-- loading the map models so we can clone them later
local arena1 = workspace:WaitForChild("Revamp City Map (clockworknokia2020)")
local arena2 = workspace:WaitForChild("2nd arena")
local lobby = workspace:WaitForChild("lobby")

-- creating a folder to hold all the match maps so workspace doesn't get messy
local matchesFolder = workspace:FindFirstChild("MatchInstances")
if not matchesFolder then
	matchesFolder = Instance.new("Folder")
	matchesFolder.Name = "MatchInstances"
	matchesFolder.Parent = workspace
end

-- visual settings and gameplay cooldowns
local TAG_COOLDOWN = 2 -- seconds you have to wait before you can tag someone back
local TAGGER_COLOR = Color3.fromRGB(255, 0, 0)
local NORMAL_COLOR = Color3.fromRGB(0, 170, 255)
local PLAYER1_SCORE_COLOR = Color3.fromRGB(0, 170, 255)
local PLAYER2_SCORE_COLOR = Color3.fromRGB(150, 0, 2)
local PROMPT_DISTANCE = 10
local OUTLINE_TRANSPARENCY = 0.3

-- simple helper to find the player object from their character model
local function getPlayerFromCharacter(character)
	if not character then return nil end
	return Players:GetPlayerFromCharacter(character)
end

-- saves a status string on the player (like "Fighting") so other scripts know what they are doing
local function setPlayerStatus(player, status)
	if player and player.Parent then
		player:SetAttribute("ActivityStatus", status)
	end
end

-- forces a player to stop sitting.
-- we have to wait a split second after setting sit to false, otherwise the physics engine glitches
-- and snaps them back to the seat when we try to teleport them.
local function safeUnsit(character)
	if not character then return end
	local humanoid = character:FindFirstChild("Humanoid")
	if humanoid and humanoid.Sit then
		humanoid.Sit = false
		task.wait(0.1) 
	end
end

-- loops through everyone in the match and turns their abilities on or off.
-- useful for the freeze time before rounds or after the game ends.
local function toggleAbilities(matchData, canUse)
	for _, character in pairs(matchData.characters) do
		if character and character.Parent then
			character:SetAttribute("AbilitiesDisabled", not canUse)
		end
	end
end

-- builds a fake player model from scratch for testing.
-- we create the parts (head, torso) manually and weld them together.
-- the welds are important so the parts stick together and move as one unit instead of falling apart.
local function createTestDummy(spawnPosition, matchData)
	local dummy = Instance.new("Model")
	dummy.Name = matchData.botInfo.name or "Test Dummy"

	local rootPart = Instance.new("Part")
	rootPart.Name = "HumanoidRootPart"
	rootPart.Size = Vector3.new(2, 2, 1)
	rootPart.Position = spawnPosition
	rootPart.Anchored = false
	rootPart.CanCollide = true
	rootPart.Transparency = 1
	rootPart.Parent = dummy

	local head = Instance.new("Part")
	head.Name = "Head"
	head.Size = Vector3.new(2, 1, 1)
	head.Position = spawnPosition + Vector3.new(0, 2.5, 0)
	head.Anchored = false
	head.CanCollide = true
	head.BrickColor = BrickColor.new("Bright yellow")
	head.TopSurface = Enum.SurfaceType.Smooth
	head.BottomSurface = Enum.SurfaceType.Smooth
	head.Parent = dummy

	local face = Instance.new("Decal")
	face.Name = "face"
	face.Texture = "rbxasset://textures/face.png"
	face.Parent = head

	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2, 1)
	torso.Position = spawnPosition + Vector3.new(0, 1, 0)
	torso.Anchored = false
	torso.CanCollide = true
	torso.BrickColor = BrickColor.new("Bright blue")
	torso.TopSurface = Enum.SurfaceType.Smooth
	torso.BottomSurface = Enum.SurfaceType.Smooth
	torso.Parent = dummy

	local humanoid = Instance.new("Humanoid")
	humanoid.Health = 100
	humanoid.MaxHealth = 100
	humanoid.WalkSpeed = 0
	humanoid.Parent = dummy

	-- this helper function connects two parts together so they stay attached
	local function weld(p0, p1, c0)
		local w = Instance.new("Weld")
		w.Part0 = p0; w.Part1 = p1; w.C0 = c0; w.Parent = p0
	end
	weld(rootPart, torso, CFrame.new(0, 0, 0))
	weld(torso, head, CFrame.new(0, 1.5, 0))

	rootPart.Anchored = true
	dummy.PrimaryPart = rootPart
	dummy.Parent = matchData.arena
	return dummy
end

-- stops the player from moving completely.
-- we anchor the root part to kill all momentum and set walkspeed to 0 just in case.
local function freezeCharacter(character, freeze)
	if not character or not character.Parent then return end
	local humanoid = character:FindFirstChild("Humanoid")
	local rootPart = character:FindFirstChild("HumanoidRootPart")

	if not rootPart or not humanoid then return end

	local oldForce = rootPart:FindFirstChild("FreezeForce")
	if oldForce then oldForce:Destroy() end

	if freeze then
		humanoid.Sit = false 

		rootPart.Anchored = true
		rootPart.AssemblyLinearVelocity = Vector3.zero
		rootPart.AssemblyAngularVelocity = Vector3.zero

		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.AutoRotate = false
	else
		rootPart.Anchored = false
		humanoid.WalkSpeed = 16
		humanoid.JumpPower = 50
		humanoid.AutoRotate = true
	end
end

-- adds a glowing outline to the character so you can tell who is 'it'.
-- red for tagger, blue for runners.
local function setCharacterHighlight(character, color, matchData)
	if not character or not character.Parent then return end

	local highlightName = "MatchHighlight"

	local highlight = character:FindFirstChild(highlightName) or Instance.new("Highlight")
	highlight.Name = highlightName
	highlight.Parent = character

	matchData.highlights[character] = highlight

	highlight.FillTransparency = 1
	highlight.OutlineColor = color
	highlight.OutlineTransparency = OUTLINE_TRANSPARENCY
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop

	-- if the gamemode has stealth enabled, we hide the highlight so they are harder to see
	if character:GetAttribute("IsStealthed") == true then
		highlight.Enabled = false
	else
		highlight.Enabled = true
	end
end

-- updates the "press e to tag" prompt.
-- logic: you shouldn't see a prompt on yourself, and the tagger shouldn't see prompts on anyone but the runners.
local function updatePromptVisibility(matchData)
	for character, prompt in pairs(matchData.prompts) do
		if prompt and prompt.Parent then
			prompt.Enabled = (character ~= matchData.currentTagger)
		end
	end
end

-- switches the roles. the old tagger becomes a runner, and the new character becomes the tagger.
-- this updates visuals (highlights), sounds, and tells all clients to update their screen text.
local function setTagger(character, matchData, isInitial)
	local previousTagger = matchData.currentTagger
	if previousTagger then setCharacterHighlight(previousTagger, NORMAL_COLOR, matchData) end

	matchData.currentTagger = character
	setCharacterHighlight(matchData.currentTagger, TAGGER_COLOR, matchData)
	updatePromptVisibility(matchData)

	-- play a custom sound if the user owns one, otherwise default to 0 (no sound)
	local customTagSoundId = "0"
	local soundSourceCharacter = isInitial and character or previousTagger
	local soundPlayer = getPlayerFromCharacter(soundSourceCharacter)

	if soundPlayer and matchData.soundCache and matchData.soundCache[soundPlayer.UserId] then
		customTagSoundId = matchData.soundCache[soundPlayer.UserId]
	end

	-- notify all clients about the role swap
	for _, player in pairs(matchData.players) do
		if player then
			local roleName = (player.Character == character) and "Tagger" or "Runner"
			local targetCharacter = nil
			for _, char in pairs(matchData.characters) do
				if player.Character and char ~= player.Character then
					targetCharacter = char
					break
				end
			end
			taggerChanged:FireClient(player, character, customTagSoundId, roleName, targetCharacter)
		end
	end

	if isInitial then
		for _, player in pairs(matchData.players) do if player then initialTaggerSet:FireClient(player) end end
	end
	
	-- give the person who was just 'it' a short cooldown so they don't accidentally tag back instantly
	if previousTagger then
		matchData.cooldowns[previousTagger] = true
		task.delay(TAG_COOLDOWN, function() matchData.cooldowns[previousTagger] = nil end)
	end
end

-- logic that runs when a player touches another player and hits the tag button.
-- validates that the tag is legal (not on cooldown, not invincible) before switching roles.
local function onTagged(tagger, tagged, matchData)
	if not tagger or not tagged or tagger == tagged or matchData.roundEnded then return end
	if tagged:GetAttribute("Invincible") == true then return end

	-- prevents spamming the tag function multiple times in the same frame
	if matchData.tagInProgress then return end
	matchData.tagInProgress = true

	local taggerPlayer = getPlayerFromCharacter(tagger)
	local taggedPlayer = getPlayerFromCharacter(tagged)
	if taggerPlayer and taggedPlayer and taggerPlayer == taggedPlayer then
		matchData.tagInProgress = false
		return
	end

	-- verify the person tagging is actually the current tagger
	if tagger ~= matchData.currentTagger then
		matchData.tagInProgress = false
		return
	end
	if matchData.cooldowns[tagged] then
		matchData.tagInProgress = false
		return
	end

	if not isPrivateServer and not matchData.isPracticeBotMatch and _G.StatsTracker_OnTag then
		_G.StatsTracker_OnTag(taggerPlayer, taggedPlayer)
	end

	setTagger(tagged, matchData, false)

	task.delay(0.1, function()
		matchData.tagInProgress = false
	end)
end

-- sets up the proximity prompt on a character so they can be tagged.
-- we connect the 'triggered' event to our ontagged function here.
local function setupCharacterForMatch(character, matchData)
	if not character or not character.Parent then return end
	local root = character:WaitForChild("HumanoidRootPart", 5)
	if not root then return end

	setCharacterHighlight(character, NORMAL_COLOR, matchData)
	if root:FindFirstChild("MatchTagPrompt") then root.MatchTagPrompt:Destroy() end

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "MatchTagPrompt"
	prompt.MaxActivationDistance = PROMPT_DISTANCE
	prompt.ActionText = "Tag"
	prompt.ObjectText = character.Name
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.RequiresLineOfSight = false
	prompt.HoldDuration = 0
	prompt.Enabled = false
	prompt.Parent = root
	prompt.Style = Enum.ProximityPromptStyle.Custom
	matchData.prompts[character] = prompt

	local characterOwner = getPlayerFromCharacter(character)
	prompt.Triggered:Connect(function(playerWhoTriggered)
		if characterOwner and playerWhoTriggered == characterOwner then return end
		if playerWhoTriggered.Character then onTagged(playerWhoTriggered.Character, character, matchData) end
	end)
end

-- looks for spawn locations inside the map model.
-- if it can't find any, it calculates a safe spot based on the model's size.
local function findSpawnPositions(arenaModel)
	local spawns = {}
	for _, descendant in pairs(arenaModel:GetDescendants()) do
		if descendant:IsA("SpawnLocation") or descendant.Name == "Spawn" then
			table.insert(spawns, descendant.Position + Vector3.new(0, 5, 0))
		end
	end
	if #spawns == 0 then
		local cf = arenaModel:GetBoundingBox()
		table.insert(spawns, cf.Position + Vector3.new(0, 10, 0))
		table.insert(spawns, cf.Position + Vector3.new(20, 10, 20))
	end
	return spawns
end

-- visual effect for when a player loses a round. creates an explosion at their position.
local function explodeCharacter(character)
	if not character or not character.Parent then return end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root then
		local ex = Instance.new("Explosion", workspace)
		ex.Position = root.Position
		ex.BlastRadius = 10
		ex.BlastPressure = 0
		ex.DestroyJointRadiusPercent = 0
	end
	freezeCharacter(character, true)
end

-- sends the current score (e.g., 2-1) to all players so their gui updates.
local function broadcastScores(matchData)
	for _, player in pairs(matchData.players) do
		if player then
			updateScores:FireClient(player, matchData.scores[matchData.characters[1]] or 0, matchData.scores[matchData.characters[2]] or 0, PLAYER1_SCORE_COLOR, PLAYER2_SCORE_COLOR)
		end
	end
end

-- checks if the practice bot exists. if it got deleted for some reason, we make a new one.
local function ensureDummyExists(matchData)
	if not matchData.isTestMatch then return end
	if matchData.testDummy and matchData.testDummy.Parent then return end

	local dummySpawn = matchData.spawns[2]
	local newDummy = createTestDummy(dummySpawn, matchData)
	matchData.testDummy = newDummy
	local oldDummy = matchData.characters[2]
	matchData.characters[2] = newDummy

	if oldDummy and matchData.scores[oldDummy] then
		matchData.scores[newDummy] = matchData.scores[oldDummy]
		matchData.scores[oldDummy] = nil
	end
	setupCharacterForMatch(newDummy, matchData)
end

-- this function handles the start of a new round.
-- it resets positions, applies gamemode settings, runs the freeze timer, and then enables controls.
local function startRound(matchData)
	if matchData.matchOver then return end
	matchData.currentRound = matchData.currentRound + 1
	matchData.roundEnded = false

	if matchData.currentRound == 1 then PowerupManager.StartMatch(matchData) end
	ensureDummyExists(matchData)

	-- disable abilities during the freeze countdown
	toggleAbilities(matchData, false)

	-- decide who starts as tagger. we alternate: round 1 is p1, round 2 is p2, etc.
	local starterIndex = ((matchData.currentRound - 1) % 2) + 1
	local starter = matchData.characters[starterIndex]
	local starterPlayer = getPlayerFromCharacter(starter)

	-- update the ui for all players to show "round starting in X seconds"
	for _, player in pairs(matchData.players) do
		if player then
			local roleName = (starterPlayer and player == starterPlayer) and "Tagger" or "Runner"

			local targetCharacter = nil
			for _, char in pairs(matchData.characters) do
				if player.Character and char ~= player.Character then targetCharacter = char; break end
			end

			showFreezeCountdown:FireClient(player, FREEZE_DURATION, nil, roleName, targetCharacter)
			showRoundGui:FireClient(player, matchData.playerInfo)
			updateGamemodeConfig:FireClient(player, matchData.gamemodeConfig)
		end
	end

	-- teleport players to their spawns and freeze them in place
	for i, character in pairs(matchData.characters) do
		if character and character.Parent then
			local root = character:FindFirstChild("HumanoidRootPart")
			if root then
				root.CFrame = CFrame.new(matchData.spawns[i])
				freezeCharacter(character, true)
			end

			-- reading settings from the gamemode config (like fast speed or low gravity)
			-- and saving them as attributes for other scripts to use
			local cooldownMult = matchData.gamemodeConfig.abilityCooldownMultiplier or 1.0
			local staminaDrainMult = matchData.gamemodeConfig.staminaDrainMultiplier or 1.0
			local movementSpeedMult = matchData.gamemodeConfig.movementSpeedMultiplier or 1.0
			character:SetAttribute("AbilityCooldownMultiplier", cooldownMult)
			character:SetAttribute("StaminaDrainMultiplier", staminaDrainMult)
			character:SetAttribute("MovementSpeedMultiplier", movementSpeedMult)

			if matchData.gamemodeConfig.nametagsEnabled == false then
				character:SetAttribute("IsStealthed", true)
			else
				character:SetAttribute("IsStealthed", nil)
			end

			local highlightColor = (character == matchData.currentTagger) and TAGGER_COLOR or NORMAL_COLOR
			setCharacterHighlight(character, highlightColor, matchData)
		end
	end

	broadcastScores(matchData)

	-- wait for the freeze timer to finish
	task.wait(FREEZE_DURATION)

	if matchData.matchOver then return end

	-- re-enable abilities if the gamemode allows it
	if matchData.gamemodeConfig.abilitiesEnabled then
		toggleAbilities(matchData, true)
	end

	-- unfreeze everyone and officially start the tag game
	for _, character in pairs(matchData.characters) do freezeCharacter(character, false) end
	setTagger(starter, matchData, true)

	if not isPrivateServer and not matchData.isPracticeBotMatch and _G.StatsTracker_OnRoundStart then
		for i, character in pairs(matchData.characters) do
			local p = getPlayerFromCharacter(character)
			if p then _G.StatsTracker_OnRoundStart(p, (character == starter)) end
		end
	end

	-- start the round timer on the client side
	local roundDuration = matchData.roundDuration or ROUND_DURATION
	for _, player in pairs(matchData.players) do if player then updateRoundTimer:FireClient(player, roundDuration) end end

	-- wait for the round to end
	task.wait(roundDuration)

	if not matchData.matchOver then endRound(matchData) end
end

-- this runs when the round timer hits zero.
-- we figure out who won (the person who wasn't 'it'), explode the loser, and update scores.
function endRound(matchData)
	if matchData.roundEnded then return end
	matchData.roundEnded = true

	toggleAbilities(matchData, false)

	-- reset stamina and hide ui text for the break between rounds
	for _, player in pairs(matchData.players) do
		if player then
			hideRoleText:FireClient(player)
			manipulateStamina:FireClient(player, {type = "Restore", amount = 200})
		end
	end

	-- clean up stealth attributes so everyone is visible again
	for _, character in pairs(matchData.characters) do
		if character then
			character:SetAttribute("IsStealthed", nil)
			local highlightColor = (character == matchData.currentTagger) and TAGGER_COLOR or NORMAL_COLOR
			setCharacterHighlight(character, highlightColor, matchData)
		end
	end

	-- determine winner: whoever is currently the tagger is the loser
	local loser = matchData.currentTagger
	local winner = nil
	for _, character in pairs(matchData.characters) do
		if character ~= loser and character.Parent then winner = character; break end
	end

	if loser then
		explodeCharacter(loser)
	end

	-- check score conditions
	local currentScore = matchData.scores[winner] or 0
	local potentialScore = currentScore + 1
	local isFinalWin = (potentialScore >= ROUNDS_TO_WIN)

	-- if someone won the round but not the whole game yet, we show a camera effect focusing on them
	if winner and not isFinalWin then
		for _, player in pairs(matchData.players) do
			if player then
				spectateWinner:FireClient(player, winner, false)
			end
		end
	end

	if winner then matchData.scores[winner] = potentialScore end

	-- logging stats for analytics
	if not isPrivateServer and not matchData.isPracticeBotMatch and _G.StatsTracker_OnRoundEnd then
		for _, character in pairs(matchData.characters) do
			local p = getPlayerFromCharacter(character)
			if p then _G.StatsTracker_OnRoundEnd(p, (character == winner), (character == loser)) end
		end
	end

	broadcastScores(matchData)

	-- check if anyone has enough wins to end the entire match
	local matchWon = false
	local finalWinner = nil
	for character, score in pairs(matchData.scores) do
		if score >= ROUNDS_TO_WIN then
			matchWon = true
			finalWinner = character
			break
		end
	end

	-- if no one won the whole game yet, we wait a bit and start the next round.
	-- otherwise, we call endMatch.
	if not matchWon then
		local customWinSoundId = nil
		local winnerPlayer = getPlayerFromCharacter(winner)
		if not winnerPlayer and matchData.players then
			for _, p in pairs(matchData.players) do
				if p.Character == winner then winnerPlayer = p break end
			end
		end

		if winnerPlayer and _G.GetPlayerData then
			local data = _G.GetPlayerData(winnerPlayer)
			if data and data.settings and data.settings.customWinSound ~= "" then
				customWinSoundId = tostring(data.settings.customWinSound)
			end
		end

		for _, player in pairs(matchData.players) do
			if player then
				roundTimeUp:FireClient(player, customWinSoundId)
			end
		end

		task.wait(BETWEEN_ROUNDS_DELAY)
		startRound(matchData)
	else
		endMatch(matchData, finalWinner)
	end
end

-- this handles the final cleanup when the game is totally over.
-- it calculates rewards (xp/coins) and updates ranking (elo) based on who won.
function endMatch(matchData, winnerCharacter, leaverPlayer)
	if matchData.matchOver then return end
	matchData.matchOver = true

	toggleAbilities(matchData, false)

	-- stop all character animations so they look like statues at the end
	for _, char in pairs(matchData.characters) do
		if char and char.Parent then
			freezeCharacter(char, true)
			local hum = char:FindFirstChild("Humanoid")
			if hum then
				for _, track in pairs(hum:GetPlayingAnimationTracks()) do
					track:Stop()
				end
			end
		end
	end

	local winnerPlayer = getPlayerFromCharacter(winnerCharacter)
	local loserCharacter = nil
	local loserPlayer = nil

	-- figure out who the loser is. if someone left the game (leaverPlayer), they are automatically the loser.
	if leaverPlayer then
		loserPlayer = leaverPlayer
	else
		for _, char in pairs(matchData.characters) do
			if char ~= winnerCharacter then loserCharacter = char; break end
		end
		loserPlayer = getPlayerFromCharacter(loserCharacter)
	end

	-- make the loser invisible
	if loserCharacter then
		for _, obj in pairs(loserCharacter:GetDescendants()) do
			if obj:IsA("BasePart") or obj:IsA("Decal") then
				obj.Transparency = 1
			end
		end
	end

	local winEloGain = 0
	local loseEloLoss = 0

	-- elo rating logic:
	-- checks the rank difference between players.
	-- if you beat a higher rank player, you get more points. if you beat a lower rank, you get fewer.
	if not isPrivateServer and not matchData.isPracticeBotMatch then
		if matchData.rankedInfo and matchData.rankedInfo.isRanked then
			local rankedInfo = matchData.rankedInfo
			local winnerIsPlayer1 = (winnerPlayer == matchData.players[1])

			local winnerRankIndex, loserRankIndex
			if winnerIsPlayer1 then
				winnerRankIndex = rankedInfo.player1RankIndex or 1
				loserRankIndex = rankedInfo.player2RankIndex or 1
			else
				winnerRankIndex = rankedInfo.player2RankIndex or 1
				loserRankIndex = rankedInfo.player1RankIndex or 1
			end

			local rankDiff = loserRankIndex - winnerRankIndex

			if rankDiff > 0 then
				winEloGain = math.random(ELO_WIN_VS_HIGHER.min, ELO_WIN_VS_HIGHER.max)
				loseEloLoss = math.random(ELO_LOSS_VS_LOWER.min, ELO_LOSS_VS_LOWER.max)
			elseif rankDiff < 0 then
				winEloGain = math.random(ELO_WIN_VS_LOWER.min, ELO_WIN_VS_LOWER.max)
				loseEloLoss = math.random(ELO_LOSS_VS_HIGHER.min, ELO_LOSS_VS_HIGHER.max)
			else
				winEloGain = math.random(ELO_WIN_VS_SAME.min, ELO_WIN_VS_SAME.max)
				loseEloLoss = math.random(ELO_LOSS_VS_SAME.min, ELO_LOSS_VS_SAME.max)
			end

			-- quitting punishment: if you leave mid-match, you lose 25% more points than a normal loss
			if leaverPlayer and loserPlayer == leaverPlayer then
				loseEloLoss = math.floor(loseEloLoss * 1.25)
			end

			-- save the new ranks to the global database
			if winnerPlayer and _G.UpdateRankData then _G.UpdateRankData(winnerPlayer, winEloGain, true) end
			if loserPlayer and loserPlayer.Parent and _G.UpdateRankData then _G.UpdateRankData(loserPlayer, -loseEloLoss, false) end
		end
	end

	local customWinSoundId = nil
	if winnerPlayer and _G.GetPlayerData then
		local data = _G.GetPlayerData(winnerPlayer)
		if data and data.settings and data.settings.customWinSound ~= "" then
			customWinSoundId = tostring(data.settings.customWinSound)
		end
	end

	-- calculate how many coins/xp to show on the result screen.
	-- if it's a private server or practice, we show 0 because rewards are disabled.
	local noRewards = isPrivateServer or matchData.isPracticeBotMatch
	local displayWinCoins = noRewards and 0 or WIN_REWARD_COINS
	local displayWinXP = noRewards and 0 or WIN_REWARD_XP
	local displayLossCoins = noRewards and 0 or LOSS_REWARD_COINS
	local displayLossXP = noRewards and 0 or LOSS_REWARD_XP
	local displayWinElo = noRewards and 0 or winEloGain
	local displayLossElo = noRewards and 0 or -loseEloLoss

	for _, player in pairs(matchData.players) do
		if player then
			spectateWinner:FireClient(player, winnerCharacter, true)
		end
	end

	-- give actual rewards to the winner
	if winnerPlayer then
		if not noRewards then
			if _G.AddPlayerMoney then _G.AddPlayerMoney(winnerPlayer, WIN_REWARD_COINS) end
			if _G.AddPlayerXP then _G.AddPlayerXP(winnerPlayer, WIN_REWARD_XP) end
			if _G.IncrementWinStreak then _G.IncrementWinStreak(winnerPlayer) end
		end

		showWinner:FireClient(
			winnerPlayer,
			winnerCharacter.Name,
			customWinSoundId,
			displayWinXP,
			displayWinElo,
			displayWinCoins
		)
	end

	-- give pity rewards to the loser (unless they rage quit)
	if loserPlayer and loserPlayer.Parent then
		if not noRewards then
			if not leaverPlayer then
				if _G.AddPlayerMoney then _G.AddPlayerMoney(loserPlayer, LOSS_REWARD_COINS) end
				if _G.AddPlayerXP then _G.AddPlayerXP(loserPlayer, LOSS_REWARD_XP) end
			end
			if _G.ResetWinStreak then _G.ResetWinStreak(loserPlayer) end
		end

		local winnerName = (matchData.isTestMatch and winnerCharacter == matchData.testDummy) and matchData.botInfo.name or winnerCharacter.Name

		showWinner:FireClient(
			loserPlayer,
			winnerName,
			customWinSoundId,
			displayLossXP,
			displayLossElo,
			displayLossCoins
		)
	end

	PowerupManager.EndMatch(matchData)

	if not isPrivateServer and not matchData.isPracticeBotMatch then
		if _G.StatsTracker_OnMatchEnd then
			for _, character in pairs(matchData.characters) do
				local p = getPlayerFromCharacter(character)
				if p then _G.StatsTracker_OnMatchEnd(p, (character == winnerCharacter)) end
			end
		end
	end

	-- wait a bit so players can see the results screen before kicking them back to lobby
	task.wait(8.5)
	MatchManager.EndMatch(matchData.matchId)
end

-- this is the main function called to start a new game.
-- it creates a unique match id, clones the map, and initializes all the data.
function MatchManager.StartMatch(player1, player2, arenaChoice, botInfo, rankedInfo, isPracticeBotMatch, gamemode, wasGamemodeTie)
	local isRanked = (rankedInfo and rankedInfo.isRanked)

	-- small delays to let the ui fade out properly before starting
	if not isRanked then
		if wasGamemodeTie then
			task.wait(6.5)
		else
			task.wait(2.5)
		end
	else
		task.wait(0.5)
	end

	local matchId = "Match_" .. tick() .. "_" .. math.random(1,1000)
	local isTestMatch = (player2 == nil)

	local gamemodeId = gamemode or "Normal"
	local gamemodeConfig = GamemodeManager.GetGamemodeById(gamemodeId)

	-- choose the map and clone it into the workspace
	local arenaTemplate = (arenaChoice == 1) and arena1 or arena2
	local arenaClone = arenaTemplate:Clone()
	arenaClone.Name = matchId
	arenaClone.Parent = matchesFolder

	-- we move the map really far up/down based on how many matches exist.
	-- this prevents players in one match from seeing or interfering with another match.
	totalMatchesCreated = totalMatchesCreated + 1
	local offset = Vector3.new(0, 1000 * totalMatchesCreated, 0)

	for _, part in pairs(arenaClone:GetDescendants()) do
		if part:IsA("BasePart") then part.CFrame = part.CFrame + offset end
	end

	local spawns = findSpawnPositions(arenaClone)

	showLoadingScreen:FireClient(player1, arenaChoice, matchId)

	if not isTestMatch and player2 then showLoadingScreen:FireClient(player2, arenaChoice, matchId) end

	setPlayerStatus(player1, "Fighting")
	if player2 then setPlayerStatus(player2, "Fighting") end

	local soundCache = {}

	-- fetch player data (rank/level) to display on the versus screen
	local p1Level, p1RankIndex, p1ELO = 1, 1, 0
	if player1 and _G.GetPlayerData then
		local data = _G.GetPlayerData(player1)
		if data then
			p1Level = data.level or 1
			if data.ranked then p1RankIndex = data.ranked.rankIndex or 1; p1ELO = data.ranked.currentELO or 0 end
		end
	end

	local p2Level, p2RankIndex, p2ELO = 1, 1, 0
	if not isTestMatch and player2 and _G.GetPlayerData then
		local data = _G.GetPlayerData(player2)
		if data then
			p2Level = data.level or 1
			if data.ranked then p2RankIndex = data.ranked.rankIndex or 1; p2ELO = data.ranked.currentELO or 0 end
		end
	end

	local isRankedMatch = (rankedInfo and rankedInfo.isRanked) or false

	local playerInfo = {
		isRanked = isRankedMatch,
		player1 = { name = player1.Name, userId = player1.UserId, level = p1Level, rankIndex = p1RankIndex, elo = p1ELO },
		player2 = { name = isTestMatch and botInfo.name or player2.Name, userId = isTestMatch and botInfo.userId or player2.UserId, level = p2Level, rankIndex = p2RankIndex, elo = p2ELO }
	}

	-- initialize the main data table for this specific match
	local matchData = {
		matchId = matchId, players = {player1}, characters = {}, arena = arenaClone, arenaChoice = arenaChoice,
		currentTagger = nil, cooldowns = {}, prompts = {}, highlights = {}, scores = {},
		currentRound = 0, roundEnded = false, matchOver = false, isTestMatch = isTestMatch,
		testDummy = nil, spawns = spawns, botInfo = botInfo or {name = "Test Bot", userId = 1},
		playerInfo = playerInfo,
		invinciblePlayers = {},
		soundCache = soundCache,
		rankedInfo = rankedInfo,
		isPracticeBotMatch = isPracticeBotMatch or false,
		gamemodeId = gamemodeId,
		gamemodeConfig = gamemodeConfig,
		roundDuration = gamemodeConfig.roundDuration or ROUND_DURATION,
	}

	activeMatches[matchId] = matchData
	playerToMatchId[player1] = matchId
	if not isTestMatch then playerToMatchId[player2] = matchId; table.insert(matchData.players, player2) end

	matchStarted:FireClient(player1, soundCache)
	if not isTestMatch then matchStarted:FireClient(player2, soundCache) end

	task.wait(LOADING_SCREEN_DURATION)

	-- safety check: if player 1 left while the loading screen was up, cancel everything
	if not player1 or not player1.Parent then MatchManager.EndMatch(matchId) return end

	-- teleport player 1
	if player1.Character then
		safeUnsit(player1.Character)

		player1.Character.HumanoidRootPart.CFrame = CFrame.new(spawns[1])
		freezeCharacter(player1.Character, true)
		setupCharacterForMatch(player1.Character, matchData)
		table.insert(matchData.characters, player1.Character)
		matchData.scores[player1.Character] = 0
	end

	-- teleport player 2 (or create the dummy bot if it's practice mode)
	if isTestMatch then
		local dummy = createTestDummy(spawns[2] or (spawns[1] + Vector3.new(10, 0, 10)), matchData)
		matchData.testDummy = dummy
		task.wait(0.5)
		setupCharacterForMatch(dummy, matchData)
		table.insert(matchData.characters, dummy)
		matchData.scores[dummy] = 0
	else
		if player2 and player2.Character then
			safeUnsit(player2.Character)

			player2.Character.HumanoidRootPart.CFrame = CFrame.new(spawns[2] or (spawns[1] + Vector3.new(10, 0, 10)))
			freezeCharacter(player2.Character, true)
			setupCharacterForMatch(player2.Character, matchData)
			table.insert(matchData.characters, player2.Character)
			matchData.scores[player2.Character] = 0
		elseif not isTestMatch then
			endMatch(matchData, player1.Character, player2)
			return
		end
	end

	if not isPrivateServer and not matchData.isPracticeBotMatch and _G.StatsTracker_OnMatchStart then
		for _, player in pairs(matchData.players) do if player then _G.StatsTracker_OnMatchStart(player) end end
	end

	startRound(matchData)
end

-- cleans everything up when the match is done.
-- moves players back to the lobby, heals them, and destroys the match map to free up memory.
function MatchManager.EndMatch(matchId)
	local matchData = activeMatches[matchId]
	if not matchData then return end
	matchData.matchOver = true
	PowerupManager.EndMatch(matchData)

	if matchData.gamemodeConfig.abilitiesEnabled then
		toggleAbilities(matchData, true)
	end

	local lobbySpawns = lobby.Lobby:FindFirstChild("Spawns")
	local lobbySpawn = (lobbySpawns and lobbySpawns:FindFirstChildOfClass("SpawnLocation")) and lobbySpawns:FindFirstChildOfClass("SpawnLocation").Position + Vector3.new(0, 5, 0) or Vector3.new(890, 251, -379)

	for _, player in pairs(matchData.players) do
		if player and player.Character then
			local root = player.Character:FindFirstChild("HumanoidRootPart")
			if root then
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
			end
		end
	end
	task.wait(0.05)

	-- teleport players back to lobby
	for _, player in pairs(matchData.players) do
		if player and player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
			safeUnsit(player.Character)
			player.Character.HumanoidRootPart.CFrame = CFrame.new(lobbySpawn)
		end
	end
	task.wait(0.1)

	for _, player in pairs(matchData.players) do
		if player and player.Character and player.Character.Parent == matchData.arena then
			player.Character.Parent = workspace
		end
	end
	task.wait(0.1)

	-- reset character visuals (unhide them, fix health, remove highlights)
	for _, player in pairs(matchData.players) do
		if player then
			playerToMatchId[player] = nil
			setPlayerStatus(player, nil)
			hideRoundGui:FireClient(player)
			if player.Parent then
				matchEnded:FireClient(player)
				if player.Character then
					freezeCharacter(player.Character, false)

					local hum = player.Character:FindFirstChild("Humanoid")
					if hum then
						hum.Health = hum.MaxHealth
						hum:ChangeState(Enum.HumanoidStateType.Landed)
						pcall(function()
							hum:SetNetworkOwner(player)
						end)
					end

					-- loop through all parts and make sure they are visible again
					for _, obj in pairs(player.Character:GetDescendants()) do
						if obj:IsA("BasePart") then
							if obj.Name ~= "HumanoidRootPart" and not obj.Name:match("Anchor") then 
								obj.Transparency = 0
							end
						elseif obj:IsA("Decal") then
							obj.Transparency = 0
						end
					end

					if player.Character:FindFirstChild("HumanoidRootPart") then
						local prompt = player.Character.HumanoidRootPart:FindFirstChild("MatchTagPrompt")
						if prompt then prompt:Destroy() end
					end

					local hl = player.Character:FindFirstChildOfClass("Highlight")
					if hl and matchData.highlights[player.Character] == hl then hl:Destroy() end
				end
			end
		end
	end
	task.wait(0.1)

	-- destroy the map and dummy to prevent memory leaks
	if matchData.testDummy then matchData.testDummy:Destroy() end
	if matchData.arena then matchData.arena:Destroy() end
	activeMatches[matchId] = nil
end

-- event listener that detects when a player leaves the game entirely.
-- if they leave while in a match, we treat it as a forfeit/loss.
Players.PlayerRemoving:Connect(function(player)
	local matchId = playerToMatchId[player]
	if matchId then
		local matchData = activeMatches[matchId]
		if matchData and not matchData.matchOver then
			local winnerCharacter = matchData.isTestMatch and matchData.testDummy or nil

			if not winnerCharacter then
				for _, p in pairs(matchData.players) do
					if p ~= player and p.Character then
						winnerCharacter = p.Character
						break
					end
				end
			end

			if winnerCharacter then
				endMatch(matchData, winnerCharacter, player)
			else
				MatchManager.EndMatch(matchId)
			end
		end
	end
end)

return MatchManager
