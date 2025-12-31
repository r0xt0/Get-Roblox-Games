--!strict
--@author: r0xt0
--@date: 12/27/25
--[[@description
	get all info for a player game.
]]

--------------------------------
-- SERVICES --
--------------------------------
-- core roblox services
local BadgeService = game:GetService("BadgeService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

--------------------------------
-- DEPENDENCIES --
--------------------------------
-- timer utility used for periodic updates
local Timer = require(ReplicatedStorage.Packages.Timer) -- sleitnick!

-- internal services
local BetterBadgeService = require(script.Parent.BetterBadgeService)
local Network = require(ReplicatedStorage.Modules.Network)
local DataService = require(script.Parent.DataService)
local UpdateEvent = ReplicatedStorage.Remotes.Update

--------------------------------
-- TYPES --
--------------------------------
local Types = require(ReplicatedStorage:WaitForChild("Modules"):WaitForChild("Types"))

--------------------------------
-- MODULE --
--------------------------------
local GameInfoService = {}

--------------------------------
-- STATE --
--------------------------------
-- per-player cache for basic info
GameInfoService.Cache = {} :: {[Player]: Types.PlayerCache}

-- cache of universeId -> icon url
GameInfoService.UniverseIconCache = {} :: {[number]: string}

-- stores fetched games per player so we don’t re-fetch constantly
GameInfoService.PlayerGamesCache = {} :: {[Player]: {Timestamp: number, Payload: {any}}}

-- stores total visits + ccu cache
GameInfoService.PlayerTotalsCache = {} :: {[Player]: {Timestamp: number, TotalVisits: number, TotalPlaying: number}}

-- update timer
local TimerInstance = Timer.new(60)

-- cache lifetimes how long it takes for it to update
local PlayerGamesCacheTtlSeconds = 60
local PlayerTotalsCacheTtlSeconds = 55

-- retry delays if roblox api rate limits
local RateLimitRetryDelaysSeconds = {0.5, 1, 2} :: {number}

-- queued update jobs explained more when queuing
local PendingUpdates = {} :: {{Player: Player, Notify: boolean?}}
local IsWorkerRunning = false

--------------------------------
-- UTIL --
--------------------------------

-- safely decode json without hard crashing
local function SafeJsonDecode(Json: string): any?
	local Decoded: any = nil
	local Ok = pcall(function()
		Decoded = HttpService:JSONDecode(Json)
	end)
	if not Ok then
		return nil
	end
	return Decoded
end

-- checks if the error was a rate limit
local function IsRateLimitError(Err: any): boolean
	local Message = tostring(Err)
	Message = string.lower(Message)
	return string.find(Message, "429") ~= nil or string.find(Message, "too many requests") ~= nil
end

-- wrapper for http get that retries on rate limit
local function SafeGetJson(Url: string): any?
	for Attempt = 1, (#RateLimitRetryDelaysSeconds + 1) do
		local Ok, BodyOrErr = pcall(function()
			return HttpService:GetAsync(Url)
		end)

		if Ok and type(BodyOrErr) == "string" then
			return SafeJsonDecode(BodyOrErr)
		end

		if (not Ok) and IsRateLimitError(BodyOrErr) and Attempt <= #RateLimitRetryDelaysSeconds then
			task.wait(RateLimitRetryDelaysSeconds[Attempt])
			continue
		end

		break
	end

	return nil
end

-- makes sure a player has a cache table
local function EnsurePlayerCache(Player: Player): Types.PlayerCache
	local Existing = GameInfoService.Cache[Player]
	if Existing then
		return Existing
	end
	local NewCache: Types.PlayerCache = {}
	GameInfoService.Cache[Player] = NewCache
	return NewCache
end

-- handles paginated api results
local function FetchAllPages(BaseUrl: string): {any}
	local Results = {}
	local Cursor: string? = nil

	while true do
		local Url = BaseUrl
		if Cursor ~= nil and Cursor ~= "" then
			Url = Url .. "&cursor=" .. HttpService:UrlEncode(Cursor)
		end

		local Json = SafeGetJson(Url)
		if type(Json) ~= "table" then
			break
		end

		if type(Json.data) == "table" then
			for _, Item in ipairs(Json.data) do
				table.insert(Results, Item)
			end
		end

		local NextCursor = Json.nextPageCursor
		if type(NextCursor) ~= "string" or NextCursor == "" then
			break
		end

		Cursor = NextCursor
	end

	return Results
end

-- help with api limiting
local function ChunkNumbers(Values: {number}, ChunkSize: number): {{number}}
	local Chunks: {{number}} = {}
	local Index = 1

	while Index <= #Values do
		local Chunk: {number} = {}
		for I = Index, math.min(Index + ChunkSize - 1, #Values) do
			table.insert(Chunk, Values[I])
		end
		table.insert(Chunks, Chunk)
		Index += ChunkSize
	end

	return Chunks
end

--------------------------------
-- ICONS --
--------------------------------
-- fetches and caches a universe icon
local function FetchUniverseIcon(UniverseId: number): string?
	local Cached = GameInfoService.UniverseIconCache[UniverseId]
	if Cached then
		return Cached
	end

	local Url =
		"https://thumbnails.roproxy.com/v1/games/icons?universeIds="
		.. tostring(UniverseId)
		.. "&size=512x512&format=Png&isCircular=false"

	local Json = SafeGetJson(Url)
	if type(Json) ~= "table" or type(Json.data) ~= "table" or type(Json.data[1]) ~= "table" then
		return nil
	end

	local ImageUrl = Json.data[1].imageUrl
	if type(ImageUrl) == "string" and ImageUrl ~= "" then
		GameInfoService.UniverseIconCache[UniverseId] = ImageUrl
		return ImageUrl
	end

	return nil
end

-- fills missing icons for game entries
local function FillIcons(Games: {Types.PublicGameEntry})
	local MissingIds = {} :: {number}

	for _, Entry in ipairs(Games) do
		if not GameInfoService.UniverseIconCache[Entry.UniverseId] then
			table.insert(MissingIds, Entry.UniverseId)
		end
	end

	local ChunkSize = 100
	local Index = 1

	while Index <= #MissingIds do
		local Ids = {}
		for I = Index, math.min(Index + ChunkSize - 1, #MissingIds) do
			table.insert(Ids, tostring(MissingIds[I]))
		end

		local Url =
			"https://thumbnails.roproxy.com/v1/games/icons?universeIds="
			.. table.concat(Ids, ",")
			.. "&size=512x512&format=Png&isCircular=false"

		local Json = SafeGetJson(Url)
		if type(Json) == "table" and type(Json.data) == "table" then
			for _, Row in ipairs(Json.data) do
				local Uid = tonumber(Row.targetId)
				local ImageUrl = Row.imageUrl
				if Uid and type(ImageUrl) == "string" and ImageUrl ~= "" then
					GameInfoService.UniverseIconCache[Uid] = ImageUrl
				end
			end
		end

		Index += ChunkSize
	end

	for _, Entry in ipairs(Games) do
		Entry.ImageUrl = GameInfoService.UniverseIconCache[Entry.UniverseId] or FetchUniverseIcon(Entry.UniverseId)
	end
end

--------------------------------
-- USER GAMES --
--------------------------------
-- grabs the games that the user directly owns / created
local function GetUserCreatedGames(UserId: number): {Types.PublicGameEntry}
	local BaseUrl =
		"https://games.roproxy.com/v2/users/"
		.. tostring(UserId)
		.. "/games?accessFilter=2&limit=50&sortOrder=Asc" -- accessFilter=2 is basically "public" stuff

	-- pulls every page so we don’t miss games if they got a lot
	local Items = FetchAllPages(BaseUrl)
	local Output: {Types.PublicGameEntry} = {}

	for _, Item in ipairs(Items) do
		local UniverseId = tonumber(Item.id)
		if UniverseId then
			-- converting api rows into our own clean entry format
			table.insert(Output, {
				UniverseId = UniverseId,
				Name = Item.name,
				Description = Item.description,
				Visits = tonumber(Item.visits),
				RootPlaceId = tonumber(Item.rootPlaceId),
				ImageUrl = nil -- icons get filled later
			})
		end
	end

	return Output
end


-- finds groups the user is in where they’re probably involved with dev stuff
local function GetEligibleGroupIds(UserId: number): {number}
	local Url = "https://groups.roproxy.com/v1/users/" .. tostring(UserId) .. "/groups/roles"
	local Json = SafeGetJson(Url)
	if type(Json) ~= "table" or type(Json.data) ~= "table" then
		return {}
	end

	local Output = {} :: {number}

	for _, Row in ipairs(Json.data) do
		local Group = Row.group
		local Role = Row.role

		local GroupId = (type(Group) == "table") and tonumber(Group.id) or nil
		local RoleName = (type(Role) == "table" and type(Role.name) == "string") and string.lower(Role.name) or ""
		local IsOwner = (type(Row.isOwner) == "boolean") and Row.isOwner or false
		
		if GroupId and GroupId > 0 then
			-- keyword based group roles, these are the big ones i could think of
			local IsDev = string.find(RoleName, "developer") ~= nil
			local IsContributor = string.find(RoleName, "contributor") ~= nil
			local IsCoOwner = string.find(RoleName, "coowner") ~= nil
			local IsScripter = string.find(RoleName, "scripter") ~= nil
			local IsBuilder = string.find(RoleName, "builder") ~= nil
			local IsModeler = string.find(RoleName, "modeler") ~= nil
			local IsAdmin = string.find(RoleName, "admin") ~= nil
			local IsDevTeam = string.find(RoleName, "development team") ~= nil
			
			-- might be spelled differently between groups
			if not IsCoOwner then
				IsCoOwner = string.find(RoleName, "co-owner") ~= nil
			end
			
			-- if any of these match, we treat the group as eligible
			if IsOwner or IsDevTeam or IsDev or IsContributor or IsCoOwner or IsScripter or IsBuilder or IsModeler or IsAdmin then
				table.insert(Output, GroupId)
			end
		end
	end

	return Output
end

-- grabs all games owned by a specific group
local function GetGroupGames(GroupId: number): {Types.PublicGameEntry}
	local BaseUrl =
		"https://games.roproxy.com/v2/groups/"
		.. tostring(GroupId)
		.. "/games?accessFilter=2&limit=50&sortOrder=Asc"

	local Items = FetchAllPages(BaseUrl)
	local Output: {Types.PublicGameEntry} = {}

	for _, Item in ipairs(Items) do
		local UniverseId = tonumber(Item.id)
		if UniverseId then
			table.insert(Output, {
				UniverseId = UniverseId,
				Name = Item.name,
				Description = Item.description,
				Visits = tonumber(Item.visits),
				RootPlaceId = tonumber(Item.rootPlaceId),
				ImageUrl = nil
			})
		end
	end

	return Output
end

-- combines all eligible groups and pulls their games too
local function GetEligibleGroupGames(UserId: number): {Types.PublicGameEntry}
	local GroupIds = GetEligibleGroupIds(UserId)
	local Output: {Types.PublicGameEntry} = {}

	for _, GroupId in ipairs(GroupIds) do
		local GroupGames = GetGroupGames(GroupId)
		for _, Entry in ipairs(GroupGames) do
			table.insert(Output, Entry)
		end
	end

	return Output
end

--------------------------------
-- MERGE + PAYLOAD --
--------------------------------
-- merges two game lists without duplicates, using universeId as the key
local function MergeUniqueByUniverseId(A: {Types.PublicGameEntry}, B: {Types.PublicGameEntry}): {Types.PublicGameEntry}
	local Seen = {} :: {[number]: boolean}
	local Output: {Types.PublicGameEntry} = {}

	for _, Entry in ipairs(A) do
		if not Seen[Entry.UniverseId] then
			Seen[Entry.UniverseId] = true
			table.insert(Output, Entry)
		end
	end

	for _, Entry in ipairs(B) do
		if not Seen[Entry.UniverseId] then
			Seen[Entry.UniverseId] = true
			table.insert(Output, Entry)
		end
	end

	return Output
end

-- converts the owned game entries into a lighter payload format (what you actually send/use)
local function BuildOwnedPayload(Owned: {Types.PublicGameEntry}): {any}
	local Output = {}

	for _, Entry in ipairs(Owned) do
		table.insert(Output, {
			UniverseId = Entry.UniverseId,
			RootPlaceId = Entry.RootPlaceId or 0,
			ImageUrl = Entry.ImageUrl or "",
			Name = Entry.Name or "",
			Description = Entry.Description or "",
			Visits = Entry.Visits or 0
		})
	end

	return Output
end

-- main internal fetch function that uses caching so we don’t spam the api
local function GetAllGameInfoInternal(Player: Player): {any}
	local Cached = GameInfoService.PlayerGamesCache[Player]
	local Now = os.clock()

	-- if cache is still fresh, return it instantly
	if Cached and (Now - Cached.Timestamp) < PlayerGamesCacheTtlSeconds then
		return Cached.Payload
	end

	local UserId = Player.UserId

	-- pull both user-owned games and group-owned games
	local UserGames = GetUserCreatedGames(UserId)
	local GroupGames = GetEligibleGroupGames(UserId)
	local Owned = MergeUniqueByUniverseId(UserGames, GroupGames)

	-- add icons after so we only do thumbnails once
	FillIcons(Owned)

	local Payload = BuildOwnedPayload(Owned)

	-- store in cache
	GameInfoService.PlayerGamesCache[Player] = {
		Timestamp = Now,
		Payload = Payload
	}

	return Payload
end

-- quick check: does the cached payload contain this universe?
local function PlayerOwnsUniverse(Player: Player, UniverseId: number): boolean
	local Cached = GameInfoService.PlayerGamesCache[Player]
	if not Cached or type(Cached.Payload) ~= "table" then
		return false
	end

	for _, Entry in ipairs(Cached.Payload) do
		if tonumber(Entry.UniverseId) == UniverseId then
			return true
		end
	end

	return false
end

--------------------------------
-- TOTALS --
--------------------------------
-- fetches live info (playing + visits) for a list of universe ids
local function FetchGamesInfoByUniverseIds(UniverseIds: {number}): {any}
	if #UniverseIds <= 0 then
		return {}
	end

	local Url = "https://games.roproxy.com/v1/games?universeIds=" .. table.concat(UniverseIds, ",")
	local Json = SafeGetJson(Url)

	if type(Json) ~= "table" or type(Json.data) ~= "table" then
		return {}
	end

	return Json.data
end

-- sums up total playing + total visits across every owned game or contributed
local function ComputeTotalsFromOwned(OwnedPayload: {any}, Notify: boolean?, Player: Player?): {TotalPlaying: number, TotalVisits: number}
	local UniverseIds: {number} = {}

	-- just gathering ids from payload
	for _, Entry in ipairs(OwnedPayload) do
		local Uid = tonumber(Entry.UniverseId)
		if Uid and Uid > 0 then
			table.insert(UniverseIds, Uid)
		end
	end

	local TotalPlaying = 0
	local TotalVisits = 0

	local Chunks = ChunkNumbers(UniverseIds, 100)
	for _, Chunk in ipairs(Chunks) do
		local Data = FetchGamesInfoByUniverseIds(Chunk)
		for _, Info in ipairs(Data) do
			if Notify == true and Player then
				-- used to notify for testing but not used anymore
				--Network.Notification:FireClient(Player, "Loading " .. tostring(Info.name), Color3.fromRGB(159, 159, 159))
			end
			TotalPlaying += tonumber(Info.playing) or 0
			TotalVisits += tonumber(Info.visits) or 0
		end
	end

	return {
		TotalPlaying = TotalPlaying,
		TotalVisits = TotalVisits
	}
end

-- caches totals so if i need to get total it doesnt run all the methods again
local function GetOrComputeTotals(Player: Player, Notify: boolean?): (number, number)
	local Cached = GameInfoService.PlayerTotalsCache[Player]
	local Now = os.clock()

	-- totals cache is separate and slightly shorter ttl
	if Cached and (Now - Cached.Timestamp) < PlayerTotalsCacheTtlSeconds then
		return Cached.TotalVisits, Cached.TotalPlaying
	end

	local OwnedPayload = GetAllGameInfoInternal(Player)
	local Totals = ComputeTotalsFromOwned(OwnedPayload, Notify, Player)

	local TotalVisits = tonumber(Totals.TotalVisits) or 0
	local TotalPlaying = tonumber(Totals.TotalPlaying) or 0

	GameInfoService.PlayerTotalsCache[Player] = {
		Timestamp = Now,
		TotalVisits = TotalVisits,
		TotalPlaying = TotalPlaying
	}

	return TotalVisits, TotalPlaying
end

--------------------------------
-- UPDATE WORKER --
--------------------------------
-- job worker that processes queued updates one by one when i tested if 50 plays join at the same time it will just break
local function RunUpdateWorker()
	if IsWorkerRunning then
		return
	end

	IsWorkerRunning = true

	task.spawn(function()
		while #PendingUpdates > 0 do
			local Job = table.remove(PendingUpdates, 1)
			local Player = Job.Player
			local Notify = Job.Notify

			-- only update if player is still actually in the game because error if left
			if Player and Player:IsDescendantOf(Players) then
				local Ok, Err = pcall(function()
					local Leaderstats = Player:WaitForChild("leaderstats")

					local Visits = Leaderstats:FindFirstChild("Visits")
					local Ccu = Leaderstats:FindFirstChild("CCU")

					local TotalVisits, TotalPlaying = GetOrComputeTotals(Player, Notify)

					-- badge milestones
					if TotalVisits >= 1000 then
						BetterBadgeService:AwardBadge(Player, "OneThousandVisits")
					end
					if TotalVisits >= 10000 then
						BetterBadgeService:AwardBadge(Player, "TenThousandVisits")
					end
					if TotalVisits >= 100000 then
						BetterBadgeService:AwardBadge(Player, "OneHundredThousandVisits")
					end
					if TotalVisits >= 1000000 then
						BetterBadgeService:AwardBadge(Player, "OneMillionVists")
					end

					-- updates leaderstats values if they exist because mabye data service failed?
					if Visits and Visits:IsA("NumberValue") then
						Visits.Value = TotalVisits
					end
					if Ccu and Ccu:IsA("NumberValue") then
						Ccu.Value = TotalPlaying
					end
				end)

				if not Ok then
					
					warn("error")
				end
			end
		end

		IsWorkerRunning = false
	end)
end

-- queues an update and starts worker if needed
local function EnqueueUpdate(Player: Player, Notify: boolean?)
	table.insert(PendingUpdates, {Player = Player, Notify = Notify})
	RunUpdateWorker()
end

--------------------------------
-- PUBLIC API --
--------------------------------
function GameInfoService.GetInfo(Player: Player): Types.PlayerCache
	return EnsurePlayerCache(Player)
end

-- returns all owned games payload (cached)
function GameInfoService.GetAllGameInfo(Player: Player): {any}
	return GetAllGameInfoInternal(Player)
end

-- returns the currently equipped game entry based on DataService.CurrentGame
function GameInfoService.GetCurrentGameInfo(Player: Player): Types.PublicGameEntry?
	local Data = DataService:GetData(Player)
	if not Data or not Data.CurrentGame then
		return nil
	end

	local UniverseId = Data.CurrentGame

	-- makes sure we have cache before searching
	local Cached = GameInfoService.PlayerGamesCache[Player]
	if not Cached or type(Cached.Payload) ~= "table" then
		Cached = {
			Timestamp = os.clock(),
			Payload = GetAllGameInfoInternal(Player)
		}
		GameInfoService.PlayerGamesCache[Player] = Cached
	end

	-- finds the matching entry
	for _, Entry in ipairs(Cached.Payload) do
		if tonumber(Entry.UniverseId) == tonumber(UniverseId) then
			return Entry
		end
	end

	return nil
end

-- public update call, just queues it
function GameInfoService.UpdateInfo(Player: Player, Notify: boolean?)
	EnqueueUpdate(Player, Notify)
end

function GameInfoService.Init()
	Players.PlayerAdded:Connect(function(Player: Player)
		-- welcome badge on join better badge service handles if it is already owned
		BetterBadgeService:AwardBadge(Player, "Welcome")
		task.spawn(EnsurePlayerCache, Player)

		-- sends the joining player everyone else’s equipped game info so their ui can update
		for _, LoopPlayer in ipairs(Players:GetPlayers()) do
			if LoopPlayer == Player then
				continue
			end
			local Info = GameInfoService.GetCurrentGameInfo(LoopPlayer)
			if Info then
				UpdateEvent:FireClient(Player, LoopPlayer, Info)
			end
		end

		task.wait(2)

		-- initial update 
		GameInfoService.UpdateInfo(Player, true)

		-- if they already have something tell client so they can update
		local IsEquipped = GameInfoService.GetCurrentGameInfo(Player)
		if IsEquipped then
			UpdateEvent:FireAllClients(Player, IsEquipped)
		end
		
		-- so client can get rid of loading screen because their data has loadded
		local Loaded = Instance.new("BoolValue", Player)
		Loaded.Name = "Loaded"
	end)

	Players.PlayerRemoving:Connect(function(Player: Player)
		-- cleanup so memory doesn’t build up forever
		GameInfoService.Cache[Player] = nil
		GameInfoService.PlayerGamesCache[Player] = nil
		GameInfoService.PlayerTotalsCache[Player] = nil

		-- also remove their pending jobs
		for Index = #PendingUpdates, 1, -1 do
			if PendingUpdates[Index].Player == Player then
				table.remove(PendingUpdates, Index)
			end
		end
	end)

	-- remote to get all games i use pcall just incase it breaks
	ReplicatedStorage.Remotes.GetAllGames.OnServerInvoke = function(Player: Player)
		local Ok, Result = pcall(function()
			return GetAllGameInfoInternal(Player)
		end)
		if not Ok then
			return {}
		end
		return Result
	end

	-- remote for equipping a game
	ReplicatedStorage.Remotes.TryEquipGame.OnServerInvoke = function(Player: Player, UniverseId: number)
		local ParsedUniverseId = tonumber(UniverseId)
		if not ParsedUniverseId or ParsedUniverseId <= 0 then
			return false
		end

		local Data = DataService:GetData(Player)
		if not Data then
			return false
		end

		-- don’t let them equip the same game again because its pointless
		if Data.CurrentGame == ParsedUniverseId then
			Network.Notification:FireClient(Player, "Already your current game!", Color3.fromRGB(255, 0, 4))
			return false
		end

		-- validate ownership 
		if not PlayerOwnsUniverse(Player, ParsedUniverseId) then
			GetAllGameInfoInternal(Player)
			if not PlayerOwnsUniverse(Player, ParsedUniverseId) then
				return false
			end
		end

		-- set equipped game
		Data.CurrentGame = ParsedUniverseId

		-- fetch the entry for the equipped game
		local NewInfo = GameInfoService.GetCurrentGameInfo(Player)
		if not NewInfo then
			GetAllGameInfoInternal(Player)
			NewInfo = GameInfoService.GetCurrentGameInfo(Player)
		end

		-- broadcast to everyone so they see the change
		if NewInfo then
			UpdateEvent:FireAllClients(Player, NewInfo)
		else
			warn("error")
		end

		return true
	end

	-- remote that returns current equipped game info
	ReplicatedStorage.Remotes.GetPlayerGameInfo.OnServerInvoke = function(Player: Player)
		return GameInfoService.GetCurrentGameInfo(Player)
	end
end

function GameInfoService.Start()
	TimerInstance:Start()

	-- every tick using sleitnick's timer clear totals cache and queue updates
	TimerInstance.Tick:Connect(function()
		for _, Player in ipairs(Players:GetPlayers()) do
			GameInfoService.PlayerTotalsCache[Player] = nil
			GameInfoService.UpdateInfo(Player, false)
		end
	end)
end

return GameInfoService
