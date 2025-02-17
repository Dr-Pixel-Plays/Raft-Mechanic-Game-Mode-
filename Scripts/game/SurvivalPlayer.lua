dofile( "$GAME_DATA/Scripts/game/BasePlayer.lua" )
dofile( "$CONTENT_DATA/Scripts/game/managers/QuestManager.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/survival_camera.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/survival_constants.lua" )
dofile( "$SURVIVAL_DATA/Scripts/game/util/Timer.lua" )
dofile( "$SURVIVAL_DATA/Scripts/util.lua" )
dofile( "$SURVIVAL_DATA/scripts/game/quest_util.lua" )

dofile( "$CONTENT_DATA/scripts/game/raft_items.lua" )
dofile( "$CONTENT_DATA/scripts/game/interactables/Barrel.lua" )
dofile "$CONTENT_DATA/Scripts/game/raft_loot.lua"


SurvivalPlayer = class( BasePlayer )


local StatsTickRate = 40

local PerSecond = StatsTickRate / 40
local PerMinute = StatsTickRate / ( 40 * 60 )

local FoodRecoveryThreshold = 5 -- Recover hp when food is above this value
local FastFoodRecoveryThreshold = 50 -- Recover hp fast when food is above this value
local HpRecovery = 50 * PerMinute
local FastHpRecovery = 75 * PerMinute
local FoodCostPerHpRecovery = 0.2
local FastFoodCostPerHpRecovery = 0.2

local FoodCostPerStamina = 0.02
local WaterCostPerStamina = 0.1
local SprintStaminaCost = 0.7 / 40 -- Per tick while sprinting
local CarryStaminaCost = 1.4 / 40 -- Per tick while carrying

local FoodLostPerSecond = 100 / 3.5 / 24 / 60
local WaterLostPerSecond = 100 / 2.5 / 24 / 60

local BreathLostPerTick = ( 100 / 60 ) / 40

local FatigueDamageHp = 1 * PerSecond
local FatigueDamageWater = 2 * PerSecond
local DrownDamage = 5
local DrownDamageCooldown = 40

local RespawnTimeout = 60 * 40

local RespawnFadeDuration = 0.45
local RespawnEndFadeDuration = 0.45

local RespawnFadeTimeout = 5.0
local RespawnDelay = RespawnFadeDuration * 40
local RespawnEndDelay = 1.0 * 40

local BaguetteSteps = 9

function SurvivalPlayer.server_onCreate( self )
	self.sv = {}
	self.sv.saved = self.storage:load()
	if self.sv.saved == nil then
		self.sv.saved = {}
		self.sv.saved.stats = self.sv.saved.stats or {
			hp = 100, maxhp = 100,
			food = 100, maxfood = 100,
			water = 100, maxwater = 100,
			breath = 100, maxbreath = 100
		}
		self.sv.saved.isConscious = self.sv.saved.isConscious or true
		self.sv.saved.hasRevivalItem = self.sv.saved.hasRevivalItem or false
		self.sv.saved.isNewPlayer = self.sv.saved.isNewPlayer or true
		self.sv.saved.inChemical = self.sv.saved.inChemical or false
		self.sv.saved.inOil = self.sv.saved.inOil or false
		self.sv.saved.tutorialsWatched = self.sv.saved.tutorialsWatched or {}
		self.storage:save( self.sv.saved )
	end

	self:sv_init()
	self.network:setClientData( self.sv.saved )
end

function SurvivalPlayer.server_onRefresh( self )
	self:sv_init()
	self.network:setClientData( self.sv.saved )
end

function SurvivalPlayer.sv_init( self )
	BasePlayer.sv_init( self )
	self.sv.staminaSpend = 0

	self.sv.statsTimer = Timer()
	self.sv.statsTimer:start( StatsTickRate )

	self.sv.drownTimer = Timer()
	self.sv.drownTimer:stop()

	self.sv.spawnparams = {}

	--RAFT
	self.sv.raft = {}
	self.sv.raft.oxygenTankCount = 0
	self.sv.checkRenderables = true
	self.sv.lampObtainTick = nil
	self.sv.lampLifeTime = nil
end

function SurvivalPlayer.client_onCreate( self )
	BasePlayer.client_onCreate( self )
	self.cl = self.cl or {}
	if self.player == sm.localPlayer.getPlayer() then
		if g_survivalHud then
			g_survivalHud:open()
		end

		self.cl.hungryEffect = sm.effect.createEffect( "Mechanic - StatusHungry" )
		self.cl.thirstyEffect = sm.effect.createEffect( "Mechanic - StatusThirsty" )
		self.cl.underwaterEffect = sm.effect.createEffect( "Mechanic - StatusUnderwater" )
		self.cl.followCutscene = 0.0
		self.cl.tutorialsWatched = {}
	end

	self:cl_init()
end

function SurvivalPlayer.client_onRefresh( self )
	self:cl_init()

	sm.gui.hideGui( false )
	sm.camera.setCameraState( sm.camera.state.default )
	sm.localPlayer.setLockedControls( false )
end

function SurvivalPlayer.cl_init( self )
	self.useCutsceneCamera = false
	self.progress = 0
	self.nodeIndex = 1
	self.currentCutscene = {}

	self.cl.revivalChewCount = 0
end

function SurvivalPlayer.client_onClientDataUpdate( self, data )
	BasePlayer.client_onClientDataUpdate( self, data )
	if sm.localPlayer.getPlayer() == self.player then

		if self.cl.stats == nil then self.cl.stats = data.stats end -- First time copy to avoid nil errors

		if g_survivalHud then
			g_survivalHud:setSliderData( "Health", data.stats.maxhp * 10 + 1, data.stats.hp * 10 )
			g_survivalHud:setSliderData( "Food", data.stats.maxfood * 10 + 1, data.stats.food * 10 )
			g_survivalHud:setSliderData( "Water", data.stats.maxwater * 10 + 1, data.stats.water * 10 )
			g_survivalHud:setSliderData( "Breath", data.stats.maxbreath * 10 + 1, data.stats.breath * 10 )
		end

		if self.cl.hasRevivalItem ~= data.hasRevivalItem then
			self.cl.revivalChewCount = 0
		end

		if self.player.character then
			local charParam = self.player:isMale() and 1 or 2
			self.cl.underwaterEffect:setParameter( "char", charParam )
			self.cl.hungryEffect:setParameter( "char", charParam )
			self.cl.thirstyEffect:setParameter( "char", charParam )

			if data.stats.breath <= 15 and not self.cl.underwaterEffect:isPlaying() and data.isConscious then
				self.cl.underwaterEffect:start()
			elseif ( data.stats.breath > 15 or not data.isConscious ) and self.cl.underwaterEffect:isPlaying() then
				self.cl.underwaterEffect:stop()
			end
			if data.stats.food <= 5 and not self.cl.hungryEffect:isPlaying() and data.isConscious then
				self.cl.hungryEffect:start()
			elseif ( data.stats.food > 5 or not data.isConscious ) and self.cl.hungryEffect:isPlaying() then
				self.cl.hungryEffect:stop()
			end
			if data.stats.water <= 5 and not self.cl.thirstyEffect:isPlaying() and data.isConscious then
				self.cl.thirstyEffect:start()
			elseif ( data.stats.water > 5 or not data.isConscious ) and self.cl.thirstyEffect:isPlaying() then
				self.cl.thirstyEffect:stop()
			end
		end

		if data.stats.food <= 5 and self.cl.stats.food > 5 then
			sm.gui.displayAlertText( "#{ALERT_HUNGER}", 5 )
		end
		if data.stats.water <= 5 and self.cl.stats.water > 5 then
			sm.gui.displayAlertText( "#{ALERT_THIRST}", 5 )
		end

		if data.stats.hp < self.cl.stats.hp and data.stats.breath == 0 then
			sm.gui.displayAlertText( "#{DAMAGE_BREATH}", 1 )
		elseif data.stats.hp < self.cl.stats.hp and data.stats.food == 0 then
			sm.gui.displayAlertText( "#{DAMAGE_HUNGER}", 1 )
		elseif data.stats.hp < self.cl.stats.hp and data.stats.water == 0 then
			sm.gui.displayAlertText( "#{DAMAGE_THIRST}", 1 )
		end

		self.cl.stats = data.stats
		self.cl.isConscious = data.isConscious
		self.cl.hasRevivalItem = data.hasRevivalItem

		sm.localPlayer.setBlockSprinting( data.stats.food == 0 or data.stats.water == 0 )

		for tutorialKey, _ in pairs( data.tutorialsWatched ) do
			-- Merge saved tutorials and avoid resetting client tutorials
			self.cl.tutorialsWatched[tutorialKey] = true
		end
		if not g_disableTutorialHints then
			

			--RAFT
			if not self.cl.tutorialsWatched["hunger"] and data.stats.food < 60 then
				if not self.cl.tutorialGui then
					self.cl.tutorialGui = sm.gui.createGuiFromLayout( "$GAME_DATA/Gui/Layouts/Tutorial/PopUp_Tutorial.layout", true, { isHud = true, isInteractive = false, needsCursor = false } )
					self.cl.tutorialGui:setText( "TextTitle", language_tag("Tutorial_Food") )
					self.cl.tutorialGui:setText( "TextMessage", language_tag("Tutorial_FoodText") )
					local keyBindingText = sm.gui.getKeyBinding( "Use", false )
					self.cl.tutorialGui:setText( "TextDismiss", string.format(language_tag("Tutorial_Dismiss"), keyBindingText) )
					self.cl.tutorialGui:setImage( "ImageTutorial", "$CONTENT_DATA/Gui/Tutorial/gui_tutorial_image_food.png" )
					self.cl.tutorialGui:setOnCloseCallback( "cl_onCloseTutorialHungerGui" )
					self.cl.tutorialGui:open()
				end
			elseif not self.cl.tutorialsWatched["thirst"] and data.stats.water < 60 then
				if not self.cl.tutorialGui then
					self.cl.tutorialGui = sm.gui.createGuiFromLayout( "$GAME_DATA/Gui/Layouts/Tutorial/PopUp_Tutorial.layout", true, { isHud = true, isInteractive = false, needsCursor = false } )
					self.cl.tutorialGui:setText( "TextTitle", language_tag("Tutorial_Water") )
					self.cl.tutorialGui:setText( "TextMessage", language_tag("Tutorial_WaterText") )
					local keyBindingText = sm.gui.getKeyBinding( "Use", false )
					self.cl.tutorialGui:setText( "TextDismiss", string.format(language_tag("Tutorial_Dismiss"), keyBindingText) )
					self.cl.tutorialGui:setImage( "ImageTutorial", "$CONTENT_DATA/Gui/Tutorial/gui_tutorial_image_water.png" )
					self.cl.tutorialGui:setOnCloseCallback( "cl_onCloseTutorialWaterGui" )
					self.cl.tutorialGui:open()
				end
			end


		end
	end
end

function SurvivalPlayer.cl_onCloseTutorialHungerGui( self )
	self.cl.tutorialsWatched["hunger"] = true
	self.network:sendToServer( "sv_e_watchedTutorial", { tutorialKey = "hunger" } )
	self.cl.tutorialGui = nil
end

function SurvivalPlayer.sv_e_watchedTutorial( self, params, player )
	self.sv.saved.tutorialsWatched[params.tutorialKey] = true
	self.storage:save( self.sv.saved )
	self.network:setClientData( self.sv.saved )
end

function SurvivalPlayer.cl_localPlayerUpdate( self, dt )
	BasePlayer.cl_localPlayerUpdate( self, dt )
	self:cl_updateCamera( dt )

	local character = self.player.character
	if character and not self.cl.isConscious then
		local keyBindingText =  sm.gui.getKeyBinding( "Use", true )
		if self.cl.hasRevivalItem then
			if self.cl.revivalChewCount < BaguetteSteps then
				sm.gui.setInteractionText( "", keyBindingText, "#{INTERACTION_EAT} ("..self.cl.revivalChewCount.."/10)" )
			else
				sm.gui.setInteractionText( "", keyBindingText, "#{INTERACTION_REVIVE}" )
			end
		else
			sm.gui.setInteractionText( "", keyBindingText, "#{INTERACTION_RESPAWN}" )
		end
	end

	if character then
		self.cl.underwaterEffect:setPosition( character.worldPosition )
		self.cl.hungryEffect:setPosition( character.worldPosition )
		self.cl.thirstyEffect:setPosition( character.worldPosition )
	end
end

function SurvivalPlayer.client_onInteract( self, character, state )
	if state == true then

		--self:cl_startCutscene( { effectName = "DollyZoomCutscene", worldPosition = character.worldPosition, worldRotation = sm.quat.identity() } )
		--self:cl_startCutscene( camera_test )
		--self:cl_startCutscene( camera_test_joint )
		--self:cl_startCutscene( camera_wakeup_ground )
		--self:cl_startCutscene( camera_approach_crash )
		--self:cl_startCutscene( camera_wakeup_crash )
		--self:cl_startCutscene( camera_wakeup_bed )

		if self.cl.tutorialGui and self.cl.tutorialGui:isActive() then
			self.cl.tutorialGui:close()
		end

		if not self.cl.isConscious then
			if self.cl.hasRevivalItem then
				if self.cl.revivalChewCount >= BaguetteSteps then
					self.network:sendToServer( "sv_n_revive" )
				end
				self.cl.revivalChewCount = self.cl.revivalChewCount + 1
				self.network:sendToServer( "sv_onEvent", { type = "character", data = "chew" } )
			else
				self.network:sendToServer( "sv_n_tryRespawn" )
			end
		end
	end
end

function SurvivalPlayer.server_onFixedUpdate( self, dt )
	BasePlayer.server_onFixedUpdate( self, dt )

	--Raft
	if self.sv.lampObtainTick ~= nil then
		local tick = sm.game.getServerTick()
		if tick - self.sv.lampObtainTick >= self.sv.lampLifeTime then
			sm.container.beginTransaction()
			sm.container.spend( self.player:getInventory(), obj_necklace_lamp, 1, true )
			self.network:sendToClient( self.player, "cl_raft_neckLaceMsg" )
			sm.container.endTransaction()
		end
	end
	--Raft

	if g_survivalDev and not self.sv.saved.isConscious and not self.sv.saved.hasRevivalItem then
		if sm.container.canSpend( self.player:getInventory(), obj_consumable_longsandwich, 1 ) then
			if sm.container.beginTransaction() then
				sm.container.spend( self.player:getInventory(), obj_consumable_longsandwich, 1, true )
				if sm.container.endTransaction() then
					self.sv.saved.hasRevivalItem = true
					self.player:sendCharacterEvent( "baguette" )
					self.network:setClientData( self.sv.saved )
				end
			end
		end
	end

	-- Delays the respawn so clients have time to fade to black
	if self.sv.respawnDelayTimer then
		self.sv.respawnDelayTimer:tick()
		if self.sv.respawnDelayTimer:done() then
			self:sv_e_respawn()
			self.sv.respawnDelayTimer = nil
		end
	end

	-- End of respawn sequence
	if self.sv.respawnEndTimer then
		self.sv.respawnEndTimer:tick()
		if self.sv.respawnEndTimer:done() then
			self.network:sendToClient( self.player, "cl_n_endFadeToBlack", { duration = RespawnEndFadeDuration } )
			self.sv.respawnEndTimer = nil;
		end
	end

	-- If respawn failed, restore the character
	if self.sv.respawnTimeoutTimer then
		self.sv.respawnTimeoutTimer:tick()
		if self.sv.respawnTimeoutTimer:done() then
			self:sv_e_onSpawnCharacter()
		end
	end

	local character = self.player:getCharacter()
	-- Update breathing
	if character then
		--RAFT
		local inv = self.player:getInventory()
		if self.sv.checkRenderables then
			self:sv_checkRenderables(inv)
		end



		if character:isDiving() then


			--RAFT
			local oxygenTankCount = math.max(sm.container.totalQuantity( inv, obj_oxygen_tank ) + self.sv.raft.oxygenTankCount, 0)
			self.sv.saved.stats.breath = math.max( self.sv.saved.stats.breath - (BreathLostPerTick/(oxygenTankCount + 1)), 0 )



			if self.sv.saved.stats.breath == 0 then
				self.sv.drownTimer:tick()
				if self.sv.drownTimer:done() then
					if self.sv.saved.isConscious then
						print( "'SurvivalPlayer' is drowning!" )
						self:sv_takeDamage( DrownDamage, "drown" )
					end
					self.sv.drownTimer:start( DrownDamageCooldown )
				end
			end
		else
			self.sv.saved.stats.breath = self.sv.saved.stats.maxbreath
			self.sv.drownTimer:start( DrownDamageCooldown )
		end

		-- Spend stamina on sprinting
		if character:isSprinting() then
			self.sv.staminaSpend = self.sv.staminaSpend + SprintStaminaCost
		end

		-- Spend stamina on carrying
		if not self.player:getCarry():isEmpty() then
			self.sv.staminaSpend = self.sv.staminaSpend + CarryStaminaCost
		end
	end

	-- Update stamina, food and water stats
	if character and self.sv.saved.isConscious and not g_godMode then
		self.sv.statsTimer:tick()
		if self.sv.statsTimer:done() then
			self.sv.statsTimer:start( StatsTickRate )

			-- Recover health from food
			if self.sv.saved.stats.food > FoodRecoveryThreshold then
				local fastRecoveryFraction = 0

				-- Fast recovery when food is above fast threshold
				if self.sv.saved.stats.food > FastFoodRecoveryThreshold then
					local recoverableHp = math.min( self.sv.saved.stats.maxhp - self.sv.saved.stats.hp, FastHpRecovery )
					local foodSpend = math.min( recoverableHp * FastFoodCostPerHpRecovery, math.max( self.sv.saved.stats.food - FastFoodRecoveryThreshold, 0 ) )
					local recoveredHp = foodSpend / FastFoodCostPerHpRecovery

					self.sv.saved.stats.hp = math.min( self.sv.saved.stats.hp + recoveredHp, self.sv.saved.stats.maxhp )
					self.sv.saved.stats.food = self.sv.saved.stats.food - foodSpend
					fastRecoveryFraction = ( recoveredHp ) / FastHpRecovery
				end

				-- Normal recovery
				local recoverableHp = math.min( self.sv.saved.stats.maxhp - self.sv.saved.stats.hp, HpRecovery * ( 1 - fastRecoveryFraction ) )
				local foodSpend = math.min( recoverableHp * FoodCostPerHpRecovery, math.max( self.sv.saved.stats.food - FoodRecoveryThreshold, 0 ) )
				local recoveredHp = foodSpend / FoodCostPerHpRecovery

				self.sv.saved.stats.hp = math.min( self.sv.saved.stats.hp + recoveredHp, self.sv.saved.stats.maxhp )
				self.sv.saved.stats.food = self.sv.saved.stats.food - foodSpend
			end

			-- Spend water and food on stamina usage
			self.sv.saved.stats.water = math.max( self.sv.saved.stats.water - self.sv.staminaSpend * WaterCostPerStamina, 0 )
			self.sv.saved.stats.food = math.max( self.sv.saved.stats.food - self.sv.staminaSpend * FoodCostPerStamina, 0 )
			self.sv.staminaSpend = 0

			-- Decrease food and water with time
			self.sv.saved.stats.food = math.max( self.sv.saved.stats.food - FoodLostPerSecond, 0 )
			self.sv.saved.stats.water = math.max( self.sv.saved.stats.water - WaterLostPerSecond, 0 )

			local fatigueDamageFromHp = false
			if self.sv.saved.stats.food <= 0 then
				self:sv_takeDamage( FatigueDamageHp, "fatigue" )
				fatigueDamageFromHp = true
			end
			if self.sv.saved.stats.water <= 0 then
				if not fatigueDamageFromHp then
					self:sv_takeDamage( FatigueDamageWater, "fatigue" )
				end
			end

			self.storage:save( self.sv.saved )
			self.network:setClientData( self.sv.saved )
		end
	end
end

function SurvivalPlayer.server_onInventoryChanges( self, container, changes )
	QuestManager.Sv_OnEvent( QuestEvent.InventoryChanges, { container = container, changes = changes } )

	local obj_interactive_builderguide = sm.uuid.new( "e83a22c5-8783-413f-a199-46bc30ca8dac" )
	if not g_survivalDev then
		if FindInventoryChange( changes, obj_interactive_builderguide ) > 0 then
			self.network:sendToClient( self.player, "cl_n_onMessage", { message = "#{ALERT_BUILDERGUIDE_NOT_ON_LIFT}", displayTime = 3 } )
			QuestManager.Sv_TryActivateQuest( "quest_builder_guide" )
		end

		--RAFT
		if FindInventoryChange( changes, obj_sail ) > 0 or FindInventoryChange( changes, obj_windsock ) > 0 then
			self.network:sendToClient( self.player, "cl_e_tutorial", "sail" )
		end
		if FindInventoryChange( changes, obj_oxygen_tank ) > 0 then
			self.network:sendToClient( self.player, "cl_e_tutorial", "oxygen" )
		end
		if FindInventoryChange( changes, obj_scrap_field ) > 0 or FindInventoryChange( changes, obj_large_field ) > 0 then
			self.network:sendToClient( self.player, "cl_e_tutorial", "farm" )
		end

		local lamps = sm.container.totalQuantity( container, obj_necklace_lamp )
		if lamps > 0 then
			self.sv.lampObtainTick = sm.game.getServerTick()
			self.sv.lampLifeTime = DaysInTicks(math.random(1000, 1500) / 100)
		elseif lamps == 0 then
			self.sv.lampObtainTick = nil
			self.sv.lampLifeTime = nil
		end
		--RAFT
	end

	--RAFT
	self.network:sendToClient( self.player, "cl_n_onInventoryChanges", { container = container, changes = changes } )
	self:sv_checkRenderables(container)
end

function SurvivalPlayer.sv_e_staminaSpend( self, stamina )
	if not g_godMode then
		if stamina > 0 then
			self.sv.staminaSpend = self.sv.staminaSpend + stamina
			print( "SurvivalPlayer spent:", stamina, "stamina" )
		end
	else
		print( "SurvivalPlayer resisted", stamina, "stamina spend" )
	end
end

function SurvivalPlayer.sv_takeDamage( self, damage, source )
	if damage > 0 then
		damage = damage * GetDifficultySettings().playerTakeDamageMultiplier
		local character = self.player:getCharacter()
		local lockingInteractable = character:getLockingInteractable()
		if lockingInteractable and lockingInteractable:hasSeat() then
			lockingInteractable:setSeatCharacter( character )
		end

		if not g_godMode and self.sv.damageCooldown:done() then
			if self.sv.saved.isConscious then
				self.sv.saved.stats.hp = math.max( self.sv.saved.stats.hp - damage, 0 )

				print( "'SurvivalPlayer' took:", damage, "damage.", self.sv.saved.stats.hp, "/", self.sv.saved.stats.maxhp, "HP" )

				if source then
					self.network:sendToClients( "cl_n_onEvent", { event = source, pos = character:getWorldPosition(), damage = damage * 0.01 } )
				else
					self.player:sendCharacterEvent( "hit" )
				end

				if self.sv.saved.stats.hp <= 0 then
					print( "'SurvivalPlayer' knocked out!" )
					self.sv.respawnInteractionAttempted = false
					self.sv.saved.isConscious = false
					character:setTumbling( true )
					character:setDowned( true )
				end

				self.storage:save( self.sv.saved )
				self.network:setClientData( self.sv.saved )
			end
		else
			print( "'SurvivalPlayer' resisted", damage, "damage" )
		end
	end
end

function SurvivalPlayer.sv_n_revive( self )
	local character = self.player:getCharacter()
	if not self.sv.saved.isConscious and self.sv.saved.hasRevivalItem and not self.sv.spawnparams.respawn then
		print( "SurvivalPlayer", self.player.id, "revived" )
		self.sv.saved.stats.hp = self.sv.saved.stats.maxhp
		self.sv.saved.stats.food = self.sv.saved.stats.maxfood
		self.sv.saved.stats.water = self.sv.saved.stats.maxwater
		self.sv.saved.isConscious = true
		self.sv.saved.hasRevivalItem = false
		self.storage:save( self.sv.saved )
		self.network:setClientData( self.sv.saved )
		self.network:sendToClient( self.player, "cl_n_onEffect", { name = "Eat - EatFinish", host = self.player.character } )
		if character then
			character:setTumbling( false )
			character:setDowned( false )
		end
		self.sv.damageCooldown:start( 40 )
		self.player:sendCharacterEvent( "revive" )
	end
end

function SurvivalPlayer.sv_e_respawn( self )
	if self.sv.spawnparams.respawn then
		if not self.sv.respawnTimeoutTimer then
			self.sv.respawnTimeoutTimer = Timer()
			self.sv.respawnTimeoutTimer:start( RespawnTimeout )
		end
		return
	end
	if not self.sv.saved.isConscious then
		g_respawnManager:sv_performItemLoss( self.player )
		self.sv.spawnparams.respawn = true

		sm.event.sendToGame( "sv_e_respawn", { player = self.player } )
	else
		print( "SurvivalPlayer must be unconscious to respawn" )
	end
end

function SurvivalPlayer.sv_n_tryRespawn( self )
	if not self.sv.saved.isConscious and not self.sv.respawnDelayTimer and not self.sv.respawnInteractionAttempted then
		self.sv.respawnInteractionAttempted = true
		self.sv.respawnEndTimer = nil;
		self.network:sendToClient( self.player, "cl_n_startFadeToBlack", { duration = RespawnFadeDuration, timeout = RespawnFadeTimeout } )
		
		self.sv.respawnDelayTimer = Timer()
		self.sv.respawnDelayTimer:start( RespawnDelay )
	end
end

function SurvivalPlayer.sv_e_onSpawnCharacter( self )
	if self.sv.saved.isNewPlayer then
		-- Intro cutscene for new player
		if not g_survivalDev then
			--self:sv_e_startLocalCutscene( "camera_approach_crash" )
		end
	elseif self.sv.spawnparams.respawn then
		local playerBed = g_respawnManager:sv_getPlayerBed( self.player )
		if playerBed and playerBed.shape and sm.exists( playerBed.shape ) and playerBed.shape.body:getWorld() == self.player.character:getWorld() then
			-- Attempt to seat the respawned character in a bed
			self.network:sendToClient( self.player, "cl_seatCharacter", { shape = playerBed.shape  } )
		else
			-- Respawned without a bed
			--self:sv_e_startLocalCutscene( "camera_wakeup_ground" )
		end

		self.sv.respawnEndTimer = Timer()
		self.sv.respawnEndTimer:start( RespawnEndDelay )
	
	end

	if self.sv.saved.isNewPlayer or self.sv.spawnparams.respawn then
		print( "SurvivalPlayer", self.player.id, "spawned" )
		if self.sv.saved.isNewPlayer then
			self.sv.saved.stats.hp = self.sv.saved.stats.maxhp
			self.sv.saved.stats.food = self.sv.saved.stats.maxfood
			self.sv.saved.stats.water = self.sv.saved.stats.maxwater
		else
			self.sv.saved.stats.hp = 30
			self.sv.saved.stats.food = 30
			self.sv.saved.stats.water = 30
		end
		self.sv.saved.isConscious = true
		self.sv.saved.hasRevivalItem = false
		self.sv.saved.isNewPlayer = false
		self.storage:save( self.sv.saved )
		self.network:setClientData( self.sv.saved )

		self.player.character:setTumbling( false )
		self.player.character:setDowned( false )
		self.sv.damageCooldown:start( 40 )
	else
		-- SurvivalPlayer rejoined the game
		if self.sv.saved.stats.hp <= 0 or not self.sv.saved.isConscious then
			self.player.character:setTumbling( true )
			self.player.character:setDowned( true )
		end
	end

	self.sv.respawnInteractionAttempted = false
	self.sv.respawnDelayTimer = nil
	self.sv.respawnTimeoutTimer = nil
	self.sv.spawnparams = {}

	sm.event.sendToGame( "sv_e_onSpawnPlayerCharacter", self.player )
end

function SurvivalPlayer.cl_n_onInventoryChanges( self, params )
	if params.container == sm.localPlayer.getInventory() then
		for i, item in ipairs( params.changes ) do
			if item.difference > 0 then
				g_survivalHud:addToPickupDisplay( item.uuid, item.difference )
			end
		end
	end
end

function SurvivalPlayer.cl_seatCharacter( self, params )
	if sm.exists( params.shape ) then
		params.shape.interactable:setSeatCharacter( self.player.character )
	end
end

function SurvivalPlayer.sv_e_debug( self, params )
	if params.hp then
		self.sv.saved.stats.hp = params.hp
	end
	if params.water then
		self.sv.saved.stats.water = params.water
	end
	if params.food then
		self.sv.saved.stats.food = params.food
	end
	self.storage:save( self.sv.saved )
	self.network:setClientData( self.sv.saved )
end

function SurvivalPlayer.sv_e_eat( self, edibleParams )
	if edibleParams.hpGain then
		self:sv_restoreHealth( edibleParams.hpGain )
	end
	if edibleParams.foodGain then
		self:sv_restoreFood( edibleParams.foodGain )

		self.network:sendToClient( self.player, "cl_n_onEffect", { name = "Eat - EatFinish", host = self.player.character } )
	end
	if edibleParams.waterGain then
		self:sv_restoreWater( edibleParams.waterGain )
		-- self.network:sendToClient( self.player, "cl_n_onEffect", { name = "Eat - DrinkFinish", host = self.player.character } )
	end
	self.storage:save( self.sv.saved )
	self.network:setClientData( self.sv.saved )
end

function SurvivalPlayer.sv_e_feed( self, params )
	if not self.sv.saved.isConscious and not self.sv.saved.hasRevivalItem then
		if sm.container.beginTransaction() then
			sm.container.spend( params.playerInventory, params.foodUuid, 1, true )
			if sm.container.endTransaction() then
				self.sv.saved.hasRevivalItem = true
				self.player:sendCharacterEvent( "baguette" )
				self.network:setClientData( self.sv.saved )
			end
		end
	end
end

function SurvivalPlayer.sv_restoreHealth( self, health )
	if self.sv.saved.isConscious then
		self.sv.saved.stats.hp = self.sv.saved.stats.hp + health
		self.sv.saved.stats.hp = math.min( self.sv.saved.stats.hp, self.sv.saved.stats.maxhp )
		print( "'SurvivalPlayer' restored:", health, "health.", self.sv.saved.stats.hp, "/", self.sv.saved.stats.maxhp, "HP" )
	end
end

function SurvivalPlayer.sv_restoreFood( self, food )
	if self.sv.saved.isConscious then
		food = food * ( 0.8 + ( self.sv.saved.stats.maxfood - self.sv.saved.stats.food ) / self.sv.saved.stats.maxfood * 0.2 )
		self.sv.saved.stats.food = self.sv.saved.stats.food + food
		self.sv.saved.stats.food = math.min( self.sv.saved.stats.food, self.sv.saved.stats.maxfood )
		print( "'SurvivalPlayer' restored:", food, "food.", self.sv.saved.stats.food, "/", self.sv.saved.stats.maxfood, "FOOD" )
	end
end

function SurvivalPlayer.sv_restoreWater( self, water )
	if self.sv.saved.isConscious then
		water = water * ( 0.8 + ( self.sv.saved.stats.maxwater - self.sv.saved.stats.water ) / self.sv.saved.stats.maxwater * 0.2 )
		self.sv.saved.stats.water = self.sv.saved.stats.water + water
		self.sv.saved.stats.water = math.min( self.sv.saved.stats.water, self.sv.saved.stats.maxwater )
		print( "'SurvivalPlayer' restored:", water, "water.", self.sv.saved.stats.water, "/", self.sv.saved.stats.maxwater, "WATER" )
	end
end

function SurvivalPlayer.server_onShapeRemoved( self, removedShapes )
	local numParts = 0
	local numBlocks = 0
	local numJoints = 0



	for _, removedShapeType in ipairs( removedShapes ) do
		if removedShapeType.type == "block"  then
			numBlocks = numBlocks + removedShapeType.amount
		elseif removedShapeType.type == "part"  then
			numParts = numParts + removedShapeType.amount
		elseif removedShapeType.type == "joint"  then
			numJoints = numJoints + removedShapeType.amount




		end

		if removedShapeType.uuid == obj_barrel then
			sm.container.beginTransaction()
			local inv = sm.game.getLimitedInventory() and self.player:getInventory() or self.player:getHotbar()
			sm.container.spend(inv, obj_barrel, 1)

			local loot = {}
            for j = 1, math.random( Barrel.minLoot, Barrel.maxLoot ) do
                loot[#loot+1] = Barrel.lootTable[math.random(#Barrel.lootTable)]
            end

			local droppedLoot = {}
            for k, barrelItem in pairs(loot) do
                local quantity = type(barrelItem.quantity) == "function" and barrelItem.quantity() or barrelItem.quantity
                local uuid = barrelItem.uuid

                if inv:canCollect( uuid, quantity ) then
                    sm.container.collect( inv, uuid, quantity )
                else
                    droppedLoot[#droppedLoot+1] = { uuid = uuid, chance = 1, quantity = quantity }
                end
            end
			sm.container.endTransaction()

            if #droppedLoot > 0 then
                raft_SpawnLoot(
                    self.player,
                    droppedLoot
                )
            end
		end
	end

	local staminaSpend = numParts + numJoints + math.sqrt( numBlocks )
	--self:sv_e_staminaSpend( staminaSpend )
end


-- Camera
function SurvivalPlayer.cl_updateCamera( self, dt )
	if self.cl.cutsceneEffect then

		local cutscenePos = self.cl.cutsceneEffect:getCameraPosition()
		local cutsceneRotation = self.cl.cutsceneEffect:getCameraRotation()
		local cutsceneFOV = self.cl.cutsceneEffect:getCameraFov()
		if cutscenePos == nil then cutscenePos = sm.camera.getPosition() end
		if cutsceneRotation == nil then cutsceneRotation = sm.camera.getRotation() end
		if cutsceneFOV == nil then cutsceneFOV = sm.camera.getFov() end

		if self.cl.cutsceneEffect:isPlaying() then
			self.cl.followCutscene = math.min( self.cl.followCutscene + dt / CUTSCENE_FADE_IN_TIME, 1.0 )
		else
			self.cl.followCutscene = math.max( self.cl.followCutscene - dt / CUTSCENE_FADE_OUT_TIME, 0.0 )
		end

		local lerpedCameraPosition = sm.vec3.lerp( sm.camera.getDefaultPosition(), cutscenePos, self.cl.followCutscene )
		local lerpedCameraRotation = sm.quat.slerp( sm.camera.getDefaultRotation(), cutsceneRotation, self.cl.followCutscene )
		local lerpedCameraFOV = lerp( sm.camera.getDefaultFov(), cutsceneFOV, self.cl.followCutscene )
		print(self.cl.followCutscene)
		sm.camera.setPosition( lerpedCameraPosition )
		sm.camera.setRotation( lerpedCameraRotation )
		sm.camera.setFov( lerpedCameraFOV )

		if self.cl.followCutscene <= 0.0 and not self.cl.cutsceneEffect:isPlaying() then
			sm.gui.hideGui( false )
			sm.camera.setCameraState( sm.camera.state.default )
			--sm.localPlayer.setLockedControls( false )
			self.cl.cutsceneEffect:destroy()
			self.cl.cutsceneEffect = nil
		end
	else
		self.cl.followCutscene = 0.0
	end
end

function SurvivalPlayer.cl_startCutscene( self, params )
	self.cl.cutsceneEffect = sm.effect.createEffect( params.effectName )
	if params.worldPosition then
		self.cl.cutsceneEffect:setPosition( params.worldPosition )
	end
	if params.worldRotation then
		self.cl.cutsceneEffect:setRotation( params.worldRotation )
	end
	self.cl.cutsceneEffect:start()
	sm.gui.hideGui( true )
	sm.camera.setCameraState( sm.camera.state.cutsceneTP )
	--sm.localPlayer.setLockedControls( true )

	--local camPos = self.cl.cutsceneEffect:getCameraPosition()
	--local camDir = self.cl.cutsceneEffect:getCameraDirection()
	--if camPos and camDir then
	--	sm.camera.setPosition( camPos )
	--	if camDir:length() > FLT_EPSILON then
	--		sm.camera.setDirection( camDir )
	--	end
	--end
end

function SurvivalPlayer.sv_e_startCutscene( self, params )
	self.network:sendToClient( self.player, "cl_startCutscene", params )
end

function SurvivalPlayer.client_onCancel( self )
	BasePlayer.client_onCancel( self )
	g_effectManager:cl_cancelAllCinematics()
end



--RAFT
function SurvivalPlayer.sv_e_OxygenTank( self, change )
	self.sv.raft.oxygenTankCount = self.sv.raft.oxygenTankCount + change
end

function SurvivalPlayer:sv_checkRenderables( inv )
	local hasFins = inv:canSpend(obj_fins, 1)
	local hasTank = inv:canSpend(obj_oxygen_tank, 1)
	local hasLamp = inv:canSpend(obj_necklace_lamp, 1)
	local changes = {}

	if hasFins ~= self.fins then
		changes.fins = { add = hasFins }
	end
	if hasTank ~= self.tank then
		changes.tank = { add = hasTank }
	end
	if hasLamp ~= self.lamp then
		changes.lamp = { add = hasLamp }
	end

	--fuck you #
	local actualFuckingLength = 0
	for k, v in pairs(changes) do
		actualFuckingLength = actualFuckingLength + 1
	end

	if actualFuckingLength > 0 then
		self.network:sendToClients("cl_updateRenderables", {changes = changes, char = self.player:getCharacter()})
	end

	self.fins = hasFins
	self.tank = hasTank
	self.lamp = hasLamp
end

function SurvivalPlayer:cl_updateRenderables( args )
	if args.changes.fins then
		if args.changes.fins.add then
			args.char:addRenderable("$CONTENT_DATA/Characters/Char_Player/Fins/obj_fins.rend" )
		else
			args.char:removeRenderable( "$CONTENT_DATA/Characters/Char_Player/Fins/obj_fins.rend" )
		end
	end

	if args.changes.tank then
		if args.changes.tank.add then
			args.char:addRenderable( "$CONTENT_DATA/Characters/Char_Player/OxygenTank/OxygenTank.rend" )
		else
			args.char:removeRenderable( "$CONTENT_DATA/Characters/Char_Player/OxygenTank/OxygenTank.rend" )
		end
	end

	if args.changes.lamp then
		local character = self.player.character
		if (self.cl.lampEffect == nil or not sm.exists(self.cl.lampEffect)) and character then
			self.cl.lampEffect = sm.effect.createEffect( "Glowstick - Hold", character, "jnt_spine2" )
		end

		if args.changes.lamp.add then
			args.char:addRenderable( "$CONTENT_DATA/Characters/Char_Player/NecklaceLamp/NecklaceLamp.rend" )
			if not self.cl.lampEffect:isPlaying() then
				self.cl.lampEffect:start()
			end
		else
			args.char:removeRenderable( "$CONTENT_DATA/Characters/Char_Player/NecklaceLamp/NecklaceLamp.rend" )
			self.cl.lampEffect:stop()
		end
	end
end




--RAFT
function SurvivalPlayer.sv_e_tutorial( self, event )
	self.network:sendToClient(self.player, "cl_e_tutorial", event)
end


function SurvivalPlayer.cl_e_tutorial( self, event )
	if event == "fishing" and not self.cl.tutorialsWatched["fishing"] then
		if not self.cl.tutorialGui then
			local params = {
				closeCallback = "cl_onCloseTutorialFishGui",
				image = "$CONTENT_DATA/Gui/Tutorial/gui_tutorial_image_fish.png",
				text = "Tutorial_Fish"}
			setup_tutorial_gui(self, params)
		end

	elseif event == "workbench" and not self.cl.tutorialsWatched["workbench"] then
		if not self.cl.tutorialGui then
			local params = {
				closeCallback = "cl_onCloseTutorialWorkbenchGui",
				image = "$CONTENT_DATA/Gui/Tutorial/gui_tutorial_image_workbench.png",
				text = "Tutorial_Workbench"}
			setup_tutorial_gui(self, params)
		end
	
	elseif event == "sail" and not self.cl.tutorialsWatched["sail"] then
		if not self.cl.tutorialGui then
			local params = {
				closeCallback = "cl_onCloseTutorialSailGui",
				image = "$CONTENT_DATA/Gui/Tutorial/gui_tutorial_image_sail.png",
				text = "Tutorial_Sail"}
			setup_tutorial_gui(self, params)
		end

	elseif event == "sleep" and not self.cl.tutorialsWatched["sleep"] then
		if not self.cl.tutorialGui then
			local params = {
				closeCallback = "cl_onCloseTutorialSleepGui",
				image = "$CONTENT_DATA/Gui/Tutorial/gui_tutorial_image_sleep.png",
				text = "Tutorial_Sleep"}
			setup_tutorial_gui(self, params)
		end
	
	elseif event == "shark" and not self.cl.tutorialsWatched["shark"] then
		if not self.cl.tutorialGui then
			local params = {
				closeCallback = "cl_onCloseTutorialSharkGui",
				image = "$CONTENT_DATA/Gui/Tutorial/gui_tutorial_image_shark.png",
				text = "Tutorial_Shark"}
			setup_tutorial_gui(self, params)
		end

	elseif event == "oxygen" and not self.cl.tutorialsWatched["oxygen"] then
		if not self.cl.tutorialGui then
			local params = {
				closeCallback = "cl_onCloseTutorialOxygenGui",
				image = "$CONTENT_DATA/Gui/Tutorial/gui_tutorial_image_oxygen.png",
				text = "Tutorial_OxygenTank"}
			setup_tutorial_gui(self, params)
		end

	elseif event == "farm" and not self.cl.tutorialsWatched["farm"] then
		if not self.cl.tutorialGui then
			local params = {
				closeCallback = "cl_onCloseTutorialFarmGui",
				image = "$CONTENT_DATA/Gui/Tutorial/gui_tutorial_image_farm.png",
				text = "Tutorial_Farm"}
			setup_tutorial_gui(self, params)
		end
	end
end

function SurvivalPlayer:cl_raft_neckLaceMsg()
	sm.gui.displayAlertText( language_tag("Lamp_break"), 2.5 )
end

function setup_tutorial_gui(self, params)
	self.cl.tutorialGui = sm.gui.createGuiFromLayout( "$GAME_DATA/Gui/Layouts/Tutorial/PopUp_Tutorial.layout", true, { isHud = true, isInteractive = false, needsCursor = false } )
	self.cl.tutorialGui:setText( "TextTitle", language_tag(params.text) )
	self.cl.tutorialGui:setText( "TextMessage", language_tag(params.text .. "Text") )
	local keyBindingText = sm.gui.getKeyBinding( "Use", false )
	self.cl.tutorialGui:setText( "TextDismiss", string.format(language_tag("Tutorial_Dismiss"), keyBindingText) )
	self.cl.tutorialGui:setImage( "ImageTutorial", params.image )
	self.cl.tutorialGui:setOnCloseCallback(params.closeCallback)
	self.cl.tutorialGui:open()
end

function SurvivalPlayer.cl_onCloseTutorialWaterGui( self )
	self.cl.tutorialsWatched["thirst"] = true
	self.network:sendToServer( "sv_e_watchedTutorial", { tutorialKey = "thirst" } )
	self.cl.tutorialGui = nil
end

function SurvivalPlayer.cl_onCloseTutorialFishGui( self )
	self.cl.tutorialsWatched["fishing"] = true
	self.network:sendToServer( "sv_e_watchedTutorial", { tutorialKey = "fishing" } )
	self.cl.tutorialGui = nil
end

function SurvivalPlayer.cl_onCloseTutorialWorkbenchGui( self )
	self.cl.tutorialsWatched["workbench"] = true
	self.network:sendToServer( "sv_e_watchedTutorial", { tutorialKey = "workbench" } )
	self.cl.tutorialGui = nil
end

function SurvivalPlayer.cl_onCloseTutorialSailGui( self )
	self.cl.tutorialsWatched["sail"] = true
	self.network:sendToServer( "sv_e_watchedTutorial", { tutorialKey = "sail" } )
	self.cl.tutorialGui = nil
end

function SurvivalPlayer.cl_onCloseTutorialSleepGui( self )
	self.cl.tutorialsWatched["sleep"] = true
	self.network:sendToServer( "sv_e_watchedTutorial", { tutorialKey = "sleep" } )
	self.cl.tutorialGui = nil
end

function SurvivalPlayer.cl_onCloseTutorialSharkGui( self )
	self.cl.tutorialsWatched["shark"] = true
	self.network:sendToServer( "sv_e_watchedTutorial", { tutorialKey = "shark" } )
	self.cl.tutorialGui = nil
end

function SurvivalPlayer.cl_onCloseTutorialOxygenGui( self )
	self.cl.tutorialsWatched["oxygen"] = true
	self.network:sendToServer( "sv_e_watchedTutorial", { tutorialKey = "oxygen" } )
	self.cl.tutorialGui = nil
end

function SurvivalPlayer.cl_onCloseTutorialFarmGui( self )
	self.cl.tutorialsWatched["farm"] = true
	self.network:sendToServer( "sv_e_watchedTutorial", { tutorialKey = "farm" } )
	self.cl.tutorialGui = nil
end