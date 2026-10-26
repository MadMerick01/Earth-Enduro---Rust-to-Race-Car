local location = require('beamngEarthEnduro/location')
local config = require('beamngEarthEnduro/config')
local persistence = require('beamngEarthEnduro/persistence')
local diagnostics = require('beamngEarthEnduro/diagnostics')
local hud = require('beamngEarthEnduro/hud')
local earthAdapter = require('beamngEarthEnduro/earthAdapter')
local garage = require('beamngEarthEnduro/garage')
local stages = require('beamngEarthEnduro/stages')
local perks = require('beamngEarthEnduro/perks')
local carkov = require('beamngEarthEnduro/carkov')
local hostile = require('beamngEarthEnduro/hostile')
local punctures = require('beamngEarthEnduro/punctures')
local roadEvents = require('beamngEarthEnduro/roadEvents')
local M = {}
-- Faster movement between two readings is treated as a teleport, not driving (150 m/s = 540 km/h).
local MAX_DRIVING_SPEED = 150
-- Money earned per kilometre of counted driving, and the amount the HUD test button adds.
local EARNINGS_PER_KM = 250
local TEST_MONEY = 10000
local MAX_BALANCE = 9007199254740991
-- Repair pricing from the vehicle's overall damage (BeamNG's own traffic code treats about 50 as a
-- scratch, 1000 as moderate and 30000 as major), scaled by what the car is worth: a car with a
-- game Value of REFERENCE_CAR_VALUE pays REPAIR_COST_PER_DAMAGE per point, a car worth half that
-- pays half. A repair never costs more than MAX_REPAIR_SHARE of the car's Value (the call-out fee
-- aside). Tune these after testing in game.
local REPAIR_MIN_DAMAGE = 50
local REPAIR_CALLOUT_FEE = 100
local REPAIR_COST_PER_DAMAGE = 0.5
local REFERENCE_CAR_VALUE = 25000
local MAX_REPAIR_SHARE = 0.75
-- Part pricing: a part's jbeam value, or a flat price when it has none. Parts taken off in the same
-- change are traded in for a share of their value, which can lower the bill but never pays out.
local DEFAULT_PART_PRICE = 250
local PART_TRADE_IN_SHARE = 0.3
-- Driving this far from where the parts were changed, without paying, puts the paid parts back.
local UNPAID_PARTS_DRIVE_LIMIT = 25
-- Car pricing: a car config's game Value, or a flat price when it has none. The car you leave is
-- traded in for a share of its Value, less the repair it needs; a trade-in is never below $0.
local DEFAULT_CAR_PRICE = 10000
local CAR_TRADE_IN_SHARE = 0.5
-- A fresh start, with no save, puts the player in this car; they upgrade it from there.
local STARTER_MODEL = 'burnside'
local STARTER_CONFIG = 'vehicles/burnside/worldironmanenduro_starter.pc'
M.STARTER_MODEL, M.STARTER_CONFIG = STARTER_MODEL, STARTER_CONFIG
-- Out of money and can't drive: a car with at least STUCK_DAMAGE (what BeamNG calls moderate damage)
-- whose repair costs more than the balance, and which has stayed within STUCK_METRES for
-- STUCK_SECONDS of unpaused play. The HUD then offers Restart stage, or Quit run on CarKov. Nothing
-- is forced: damage is its own punishment, so there is no wreck limit.
local STUCK_DAMAGE = 1000
local STUCK_METRES = 5
local STUCK_SECONDS = 20
M.STUCK_DAMAGE, M.STUCK_METRES, M.STUCK_SECONDS = STUCK_DAMAGE, STUCK_METRES, STUCK_SECONDS
-- Stage clock: a repair or a new car costs the player this many seconds. One frame never adds more
-- than MAX_CLOCK_STEP, so a loading stall or a teleport hitch does not eat into the time limit.
local PENALTY_SECONDS = 300
local MAX_CLOCK_STEP = 0.5
local PENALTY_SHOWN_FOR = 8
M.PENALTY_SECONDS = PENALTY_SECONDS
-- How long the HUD shows a sponsor bonus once it is paid. The amount and distance are set per stage
-- in stages.lua.
local SPONSOR_SHOWN_FOR = 6
-- How long the HUD shows a perk being used, paid out or lost. Perk values are set in perks.lua.
local PERK_SHOWN_FOR = 6
-- How long the HUD shows how a CarKov run ended, or how its hostile was dealt with. CarKov's fee
-- and reward are set in carkov.lua, and the hostile's in hostile.lua.
local CARKOV_SHOWN_FOR = 10
-- A puncture's tyre repair, as damage points, so every repair quote and bill includes it. Like
-- other damage it is priced by the car's Value: TYRE_REPAIR_COST on a REFERENCE_CAR_VALUE car.
local PUNCTURE_DAMAGE = punctures.TYRE_REPAIR_COST / REPAIR_COST_PER_DAMAGE
-- Perks that work on the stage clock, which does not run on a CarKov run, so they wait for the stage.
local CLOCK_PERKS = { timeFreeze = true, paceGift = true }

-- The car's Value for repair pricing: its game Value, or the dealer's flat price when it has none.
local function repairValue(value)
  if type(value) ~= 'number' or value ~= value or value <= 0 or value == math.huge then return DEFAULT_CAR_PRICE end
  return value
end

-- Dollars per damage point for a car worth this much.
function M.repairRate(value)
  return REPAIR_COST_PER_DAMAGE * repairValue(value) / REFERENCE_CAR_VALUE
end

-- Whole-dollar price to repair a car worth carValue with this much damage; 0 means nothing to repair.
function M.repairCost(damage, carValue)
  if type(damage) ~= 'number' or damage ~= damage or damage < REPAIR_MIN_DAMAGE then return 0 end
  local value = repairValue(carValue)
  local parts = math.min(damage * M.repairRate(value), value * MAX_REPAIR_SHARE)
  return math.floor(REPAIR_CALLOUT_FEE + parts + 0.5)
end

-- Compares the paid-for parts with the fitted ones. Returns { added, removed, cost } or nil when
-- they match; added and removed list { name, price }.
function M.partsDiff(owned, fitted)
  local added, removed, seen = {}, {}, {}
  local function price(snapshot, part)
    local value = snapshot.values and snapshot.values[part]
    return math.floor((value or DEFAULT_PART_PRICE) + 0.5)
  end
  local function name(snapshot, part) return snapshot.names and snapshot.names[part] or part end
  local function compare(slot)
    if seen[slot] then return end
    seen[slot] = true
    local before, after = owned.parts[slot] or '', fitted.parts[slot] or ''
    if before == after then return end
    if after ~= '' then added[#added + 1] = { name = name(fitted, after), price = price(fitted, after) } end
    if before ~= '' then removed[#removed + 1] = { name = name(owned, before), price = price(owned, before) } end
  end
  for slot in pairs(owned.parts) do compare(slot) end
  for slot in pairs(fitted.parts) do compare(slot) end
  if #added == 0 and #removed == 0 then return nil end
  local byName = function(a, b) return a.name < b.name end
  table.sort(added, byName); table.sort(removed, byName)
  local total = 0
  for _, part in ipairs(added) do total = total + part.price end
  for _, part in ipairs(removed) do total = total - part.price * PART_TRADE_IN_SHARE end
  return { added = added, removed = removed, cost = math.max(0, math.floor(total + 0.5)) }
end

local function dollars(amount)
  local text = tostring(math.floor(amount))
  repeat
    local n
    text, n = text:gsub('^(-?%d+)(%d%d%d)', '%1,%2')
  until n == 0
  return '$' .. text
end

local labels = {
  CONFIG_REQUIRED = 'BASE CONFIGURATION REQUIRED', EARTH_UNAVAILABLE = 'EARTH UNAVAILABLE',
  READY = 'READY', ERROR = 'RALLY PAUSED',
}
-- What the HUD asks of the player until they reach the resume point.
local goLabels = { resume = 'GO TO YOUR LAST SAVE', start = 'GO TO THE START', drop = 'GO TO THE CARKOV DROP' }
local goMessages = {
  resume = 'Copy these coordinates, paste them into the BeamNG.Earth map and teleport there to carry on your enduro.',
  start = 'Copy these coordinates, paste them into the BeamNG.Earth map and teleport there to start your enduro. You get your starter car when you arrive.',
  carried = 'Copy these coordinates, paste them into the BeamNG.Earth map and teleport there to start the stage. Your car is waiting for you there.',
  drop = 'Copy these coordinates, paste them into the BeamNG.Earth map and teleport there to start your CarKov run. Your car is waiting for you there.',
}
local arrivedMessages = {
  resume = "You're in the right place. Continue your trek, and press Save to keep your progress.",
  start = "You're at the start. Begin your trek, and press Save to keep your progress.",
}
local messages = {
  earth_missing = 'Enable BeamNG.Earth to continue.',
  earth_starting = 'Waiting for BeamNG.Earth to finish starting.',
  earth_level_required = 'Load the BeamNG.Earth Freeroam level to continue.',
  earth_interface_error = 'Earth information is unavailable. Load the level again when Earth is ready.',
  vehicle_required = 'Enter an active vehicle to continue.',
  position_invalid = 'Waiting for a valid geographic position.',
}
-- What the player sees for each problem that pauses Enduro.
local errorMessages = {
  newer_version = 'Your save was made by a newer version of the rally mod. Update the mod to keep playing.',
  storage_unavailable = 'The rally could not open its save folder. Load the level again to try again.',
  internal_error = 'The rally hit a problem and paused. Load the level again to carry on from your last save.',
  unknown_stage = 'Your save is for a stage this version does not have. Update the mod to keep playing.',
}
local loadMessages = {
  loaded = 'Loaded your last save.',
  missing = 'No save yet. Press Save to keep your progress.',
  unreadable = 'Your save file could not be read, so this is a fresh start. Saving will replace it.',
}

-- Controller dependencies permit deterministic headless tests. No game globals below this factory.
function M.new(deps)
  local c = {
    state = 'CONFIG_REQUIRED', clock = 0, sessionVerified = false,
    diag = diagnostics.new(deps.log), adapter = deps.adapter,
    store = persistence.new(deps.io), ui = hud.new(deps.trigger),
    feedback = 'Not saved this session.', garage = deps.garage,
    paused = deps.paused or function() return false end,
    random = deps.random or math.random,
    -- Spawns, reads and removes the CarKov hostile; without it runs have no hostile.
    hostiles = deps.hostiles,
    -- Bursts tyres and tells whether the car is off road; without it there are no punctures.
    punctures = deps.punctures,
    punctureDamage = 0,
  }

  function c:transition(nextState, reason)
    if self.state == nextState and self.reason == reason then return end
    self.state, self.reason = nextState, reason
    self.diag:event('state', nextState .. ':' .. tostring(reason or ''))
  end

  function c:reload()
    -- Whatever ended (a run, a level or a reload), its hostile goes with it.
    self:clearHostile('reload')
    self.adapter:invalidate()
    self.sessionVerified, self.lastSample, self.error, self.odometer = false, nil, nil, nil
    self.earningsCarry = 0
    self.quote, self.repairFeedback = nil, nil
    self.partsFeedback, self.carFeedback = nil, nil
    self.vehicleProvided, self.arrivingModel, self.arrivingValue, self.arrived = false, nil, nil, false
    self.stuck, self.still, self.restartArmed, self.penalty, self.sponsorFlash, self.perkFlash = nil, nil, false, nil, nil, nil
    self.quitArmed, self.extractHold, self.stageArmed, self.newGameArmed = false, nil, nil, false
    -- A puncture not yet repaired; a reload respawns the car, so its tyre repair is owed instead.
    self.punctureDamage, self.punctureFlash, self.offRoad, self.offRoadCheckedAt = 0, nil, nil, nil
    -- A friendly village's offer is not saved, so a reload turns it down.
    self.roadOffer, self.roadFlash = nil, nil
    self.configuration, self.configError = config.load(deps.io)
    self.diag:event('configuration', self.configuration and 'loaded' or self.configError, self.configuration and 'I' or 'W')
    self.profile, self.loadStatus = self.store:load()
    self.diag:event('save_loaded_or_rejected', self.loadStatus, self.profile and 'I' or 'W')
    self.feedback = loadMessages[self.loadStatus] or ''
    if not self.profile and not loadMessages[self.loadStatus] then self.error = self.loadStatus end
    -- Saves from before stages belong to the first stage.
    local stageId = self.profile and self.profile.stage
    self.stage = stageId and stages.get(stageId) or (not stageId and stages.first()) or nil
    if not self.stage and not self.error then self.error = 'unknown_stage' end
    self.stageFinished = self.profile ~= nil and self.profile.finished == true
    -- Saves from before sponsor bonuses count the distance already driven as paid, so nothing is back-paid.
    if self.profile and self.stage and self.profile.progression.sponsorBonuses == nil then
      self.profile.progression.sponsorBonuses = math.floor(self.profile.progression.totalDistanceKm / self.stage.sponsorEveryKm)
    end
    -- Likewise, saves from before Service Perks get their first offer at the next stretch.
    if self.profile and self.profile.progression.perkOffers == nil then
      self.profile.progression.perkOffers = math.floor(self.profile.progression.totalDistanceKm / perks.OFFER_EVERY_KM)
    end
    self.savedDistanceKm = self.profile and self.profile.progression.totalDistanceKm or 0
    -- Before the first save the stage's starting money counts as saved, since it was not earned.
    self.savedBalance = self.profile and self.profile.progression.balance
      or (self.stage and self.stage.startingMoney) or 0
    -- A restored car looks new, but the repair it needed when saved is still owed.
    self.owedDamage = self.profile and self.profile.vehicle and self.profile.vehicle.damage or 0
    -- A restarted stage sends the player back to its start for a new starter car.
    self.mode = (self.profile and not self.profile.atStart) and 'resume' or 'start'
    -- A CarKov run under way; until the player first reaches its drop point they go there instead.
    self.carkov = self.profile and self.profile.carkov or nil
    if self.carkov and self.mode == 'start' then self.mode = 'drop' end
    -- Runs saved before hostiles get one too.
    if self.carkov and self.carkov.hostileAtKm == nil and not self.carkov.hostileDone then
      self.carkov.hostileAtKm = hostile.pickKm(self.random)
    end
    -- A stage started from the one before, or restarted, can bring a car to its start instead of the
    -- starter car; a CarKov drop always brings the player's car.
    self.carriedCar = (self.mode == 'start' or self.mode == 'drop') and self.profile ~= nil and self.profile.vehicle ~= nil
      and self.profile.vehicle.config ~= nil
    self.creationBase = location.copy(self.profile and self.profile.base or self.unsavedBase
      or (self.configuration and self.configuration.base))
    self.startupTarget = location.copy(self.profile and self.profile.resume or self.creationBase)
    -- A restarted save goes to where the stage starts now, even if an update moved it.
    if self.profile and self.mode == 'start' and self.configuration and self.stage then self.startupTarget = self:stageStart() end
    if self.startupTarget then
      self.diag:event('target', self.mode .. ':' .. string.format('%.8f,%.8f', self.startupTarget.latitude, self.startupTarget.longitude))
    end
    if not self.configuration then self:transition('CONFIG_REQUIRED', 'configuration')
    elseif self.error then self:transition('ERROR', self.error)
    else self:transition('EARTH_UNAVAILABLE', 'position_invalid') end
    -- Saves from when a wreck ended the run could only be restarted, so they restart now.
    if self.profile and self.profile.gameOver and self.configuration and not self.error then
      self.restartArmed = true
      if self:restartStage() then
        self.feedback = 'Wrecks no longer end the run, so your old game over was restarted. Go to the start to carry on.'
      end
    end
  end

  function c:interrupt(reason)
    self.odometer = nil
    if self.configuration and not self.error then self:transition('EARTH_UNAVAILABLE', reason) end
  end

  function c:endMission()
    self:clearHostile('level_ended')
    self.sessionVerified, self.lastSample = false, nil
    self:interrupt('earth_level_required')
    self.adapter:invalidate()
  end

  -- The balance is whole dollars; fractions of a dollar carry over in memory until they add up.
  function c:addMoney(amount)
    local progression = self.profile.progression
    local total = self.earningsCarry + amount
    local whole = math.floor(total)
    self.earningsCarry = total - whole
    progression.balance = math.min(MAX_BALANCE, progression.balance + whole)
  end

  function c:canAfford(amount)
    return self.profile ~= nil and not self.error and type(amount) == 'number' and amount >= 0
      and amount == math.floor(amount) and amount <= self.profile.progression.balance
  end

  -- Every purchase pays through here: refuses when the balance is short, never goes below zero.
  -- Like earnings, the new balance is only kept on disk by Save.
  function c:spend(amount, label)
    if not self:canAfford(amount) then
      self.diag:event('spend_rejected', tostring(label) .. ':' .. tostring(amount), 'W')
      return false
    end
    self.profile.progression.balance = self.profile.progression.balance - amount
    self.diag:event('spend', tostring(label) .. ':' .. tostring(amount))
    return true
  end

  -- Puts the player PENALTY_SECONDS further behind on the stage clock. Like money, it is kept by Save.
  function c:addPenalty(reason)
    -- A CarKov run has no clock to add to.
    if self.carkov then return end
    local progression = self.profile.progression
    progression.penaltySeconds = (progression.penaltySeconds or 0) + PENALTY_SECONDS
    self.penalty = { reason = reason, at = self.clock }
    self.diag:event('time_penalty', reason .. ':' .. PENALTY_SECONDS)
  end

  -- Service Perks. The perk held, when this version knows it.
  function c:heldPerk()
    local id = self.profile and self.profile.progression.perk
    return id and perks.get(id) and id or nil
  end

  function c:flashPerk(title, text)
    self.perkFlash = { title = title, text = text, at = self.clock }
  end

  -- A changed perk can change an open parts or car bill, so the bill is priced again.
  function c:perkChanged()
    if self.pendingParts or self.pendingCar then self.partsCheckDue = true end
  end

  -- Uses up the perk held when it is this one. Returns whether it was.
  function c:usePerk(id)
    if self:heldPerk() ~= id then return false end
    self.profile.progression.perk = nil
    self.diag:event('perk_used', id)
    self:perkChanged()
    return true
  end

  -- A repair costs time unless No Penalty covers it, and loses the perk held, except Insurance.
  -- Returns whether it cost time.
  -- On a CarKov run a repair costs no time, so No Penalty is kept for the stage.
  function c:repaired()
    local timed = not self.carkov and not self:usePerk('noPenalty')
    if timed then self:addPenalty('repair') end
    local held = self:heldPerk()
    if held and held ~= 'insurance' and not (self.carkov and held == 'noPenalty') then
      self.profile.progression.perk = nil
      self:flashPerk('PERK LOST', 'The repair lost your ' .. perks.get(held).name .. ' perk.')
      self.diag:event('perk_lost', held)
    elseif not timed and not self.carkov then
      self:flashPerk('NO PENALTY USED', 'The repair cost you no time.')
    end
    return timed
  end

  -- Offers a random perk for each whole stretch of OFFER_EVERY_KM driven, like the sponsor bonus.
  -- An offer not answered yet is replaced by the next one.
  function c:offerPerk()
    if self.stageFinished then return end
    local progression = self.profile.progression
    local due = math.floor(progression.totalDistanceKm / perks.OFFER_EVERY_KM)
    if due <= (progression.perkOffers or 0) then return end
    progression.perkOffers = due
    progression.perkOffer = perks.pick(self.random, self:heldPerk())
    self.diag:event('perk_offered', progression.perkOffer)
  end

  function c:perkActionsAllowed()
    return self.profile ~= nil and not self.error and self.state == 'READY' and self.arrived
      and not self.stageFinished
  end

  -- Keep: turns the offer down. Swap: takes it in place of the perk held (or an empty slot).
  function c:answerPerkOffer(swap)
    local offer = self.profile and self.profile.progression.perkOffer
    if not offer or not self:perkActionsAllowed() then return false end
    self.profile.progression.perkOffer = nil
    if swap and perks.get(offer) then
      self.profile.progression.perk = offer
      self:perkChanged()
      self.diag:event('perk_taken', offer)
    end
    return true
  end

  function c:activatePerk()
    local held = self:heldPerk()
    local perk = held and perks.get(held)
    if not perk or not perk.activate or not self:perkActionsAllowed() then return false end
    if self.carkov and CLOCK_PERKS[held] then return false end
    local progression = self.profile.progression
    progression.perk = nil
    if held == 'timeFreeze' then
      progression.freezeSeconds = (progression.freezeSeconds or 0) + perks.TIME_FREEZE_SECONDS
      self:flashPerk('TIME FREEZE', 'The stage clock is stopped.')
    elseif held == 'paceGift' then
      progression.timeCreditSeconds = (progression.timeCreditSeconds or 0) + perks.PACE_GIFT_SECONDS
      self:flashPerk('PACE GIFT', 'Time taken off your stage clock.')
    elseif held == 'luckyMile' then
      progression.luckyUntilKm = math.max(progression.luckyUntilKm or 0, progression.totalDistanceKm) + perks.LUCKY_MILE_KM
      self:flashPerk('LUCKY MILE', 'Driving pays ' .. perks.LUCKY_MILE_MULTIPLIER .. 'x for the next ' .. perks.LUCKY_MILE_KM .. ' km.')
    end
    self.diag:event('perk_activated', held)
    return true
  end

  -- Insurance: pays for the repair when the player is out of money and cannot drive. With a bill
  -- open, the repair in the bill is dropped. Like any repair it costs time. Returns whether it paid.
  function c:claimInsurance()
    if self:heldPerk() ~= 'insurance' then return false end
    if self.pendingCar then
      self.pendingCar.oldDamage = 0
      self:quoteCar(self.fittedParts)
    elseif self.pendingParts then
      local p = self.pendingParts
      p.damage, p.repair, p.cost = 0, 0, p.partsCost - p.discount
    else
      local ok, why, detail = self.garage:repair()
      if not ok then
        self.diag:event('insurance_failed', tostring(why) .. (detail and (': ' .. detail) or ''), 'E')
        return false
      end
    end
    self.profile.progression.perk = nil
    self.owedDamage, self.punctureDamage, self.quote, self.stuck, self.still = 0, 0, nil, nil, nil
    self:addPenalty('repair')
    self:flashPerk('INSURANCE PAID', 'Your insurance paid for the repair, so you can drive on.')
    self.diag:event('insurance_paid', 'stuck')
    return true
  end

  -- The stage clock runs while the player is on the stage, the game is not paused and the stage
  -- is neither finished nor over.
  function c:clockRunning()
    return self.profile ~= nil and self.state == 'READY' and self.arrived and not self.stageFinished
      and not self.error and self.stage ~= nil and self.stage.targetSeconds ~= nil
      and not self.carkov and not self.paused()
  end

  function c:runClock(dt)
    -- A CarKov run times itself for its finish screen; it has no limit or Time Freeze.
    if self.carkov then
      if self.profile and self.state == 'READY' and self.arrived and not self.error and not self.paused() then
        local progression = self.profile.progression
        progression.drivingSeconds = (progression.drivingSeconds or 0) + math.min(dt, MAX_CLOCK_STEP)
      end
      return
    end
    if not self:clockRunning() then return end
    local progression = self.profile.progression
    local step = math.min(dt, MAX_CLOCK_STEP)
    -- Time Freeze: the clock stands still until the frozen time is used up.
    local frozen = math.min(step, progression.freezeSeconds or 0)
    if frozen > 0 then
      progression.freezeSeconds = progression.freezeSeconds - frozen
      if progression.freezeSeconds <= 0 then progression.freezeSeconds = nil end
      step = step - frozen
    end
    progression.drivingSeconds = (progression.drivingSeconds or 0) + step
  end

  -- Pays the sponsor bonus for each whole stretch of sponsorEveryKm driven and not yet paid for. The
  -- count of bonuses paid is saved with the balance, so a reload never pays one twice.
  function c:paySponsor()
    if self.stageFinished or not self.stage or self.carkov then return end
    local progression = self.profile.progression
    local due = math.floor(progression.totalDistanceKm / self.stage.sponsorEveryKm)
    local paid = progression.sponsorBonuses or 0
    if due <= paid then return end
    local amount = (due - paid) * self.stage.sponsorBonus
    if self:usePerk('sponsorBoost') then amount = amount + self.stage.sponsorBonus * (perks.SPONSOR_BOOST_MULTIPLIER - 1) end
    progression.sponsorBonuses = due
    self:addMoney(amount)
    self.sponsorFlash = { amount = amount, at = self.clock }
    self.diag:event('sponsor_bonus', due .. ':' .. amount)
  end

  -- Seconds ahead of (positive) or behind (negative) the stage's pace. The pace assumes the time
  -- limit is spread evenly over the straight-line distance from start to finish, so a player a
  -- third of the way there in a straight line is expected to have used a third of the time.
  function c:paceSeconds(current, elapsed)
    local target = self.stage.targetSeconds
    local progress = 1
    if not self.stageFinished then
      local total = location.distance(self:stageStart(), self.stage.finish)
      local left = location.distance(current, self.stage.finish)
      if not total or not left or total <= self.stage.finishRadiusMetres then return nil end
      progress = math.max(0, math.min(1, 1 - left / total))
    end
    return math.floor(progress * target - elapsed + 0.5)
  end

  -- The vehicle's damage now, plus the damage still owed from the last save.
  function c:inspectDamage()
    local vehicle, why = self.garage:inspect()
    if not vehicle then return nil, why end
    return { id = vehicle.id, damage = vehicle.damage + self.owedDamage + self.punctureDamage }
  end

  -- The game Value of the player's own car, when vehicleId is that car; repairs are priced from it.
  function c:carValueOf(vehicleId)
    local owned = self.ownedParts
    if owned and vehicleId ~= nil and owned.id == vehicleId then return owned.value end
  end

  -- Reads the player vehicle's damage now and prices it. Returns the inspection and cost, or nil and a reason.
  function c:priceRepair()
    if not self.profile or self.error then return nil, 'unavailable' end
    if not self.garage then return nil, 'repair_unavailable' end
    local vehicle, why = self:inspectDamage()
    if not vehicle then return nil, why end
    return vehicle, M.repairCost(vehicle.damage, self:carValueOf(vehicle.id))
  end

  local repairMessages = {
    unavailable = 'Repairs are unavailable right now. Check the status above.',
    vehicle_required = 'Enter a vehicle to get a repair quote.',
  }
  local function repairProblem(why)
    return repairMessages[why] or 'Could not read the vehicle damage. Try again in a moment.'
  end

  function c:requestRepairQuote()
    local vehicle, cost = self:priceRepair()
    if not vehicle then
      self.quote, self.repairFeedback = nil, repairProblem(cost)
      self.diag:event('repair_quote_failed', tostring(cost), 'W')
      return false
    end
    self.diag:event('repair_quote', string.format('%.1f damage, %d', vehicle.damage, cost))
    if cost == 0 then
      self.quote, self.repairFeedback = nil, 'No damage to repair.'
      return true
    end
    self.quote = { vehicleId = vehicle.id, cost = cost }
    self.repairFeedback = self:canAfford(cost) and 'Press Repair to fix every damaged part.'
      or ('Not enough money yet. You need ' .. dollars(cost - self.profile.progression.balance) .. ' more.')
    return true
  end

  -- Charges the quoted price and repairs. A changed vehicle or new damage needs a fresh quote first,
  -- and the player is only charged once the game has accepted the repair.
  function c:repairVehicle()
    if self.pendingCar then
      self.repairFeedback = 'Buy or revert the new car first.'
      return false
    end
    if self.pendingParts then
      self.repairFeedback = 'Buy or revert your part changes first. Their bill includes the repair.'
      return false
    end
    if not self.quote then
      self.repairFeedback = 'Get a repair quote first.'
      return false
    end
    local vehicle, cost = self:priceRepair()
    if not vehicle then
      self.quote, self.repairFeedback = nil, repairProblem(cost)
      self.diag:event('repair_rejected', tostring(cost), 'W')
      return false
    end
    if vehicle.id ~= self.quote.vehicleId or cost ~= self.quote.cost then
      self.quote = nil
      self:requestRepairQuote()
      if self.quote then
        self.repairFeedback = 'The damage changed, so the quote was updated. Press Repair again to accept it.'
      end
      return false
    end
    if not self:canAfford(cost) then
      self.repairFeedback = 'Not enough money. You need ' .. dollars(cost - self.profile.progression.balance) .. ' more.'
      self.diag:event('repair_rejected', 'insufficient_funds', 'W')
      return false
    end
    local ok, why, detail = self.garage:repair()
    if not ok then
      self.repairFeedback = 'Repair failed. You have not been charged.'
      self.diag:event('repair_failed', tostring(why) .. (detail and (': ' .. detail) or ''), 'E')
      return false
    end
    self:spend(cost, 'repair')
    local timed = self:repaired()
    self.quote, self.owedDamage, self.punctureDamage = nil, 0, 0
    self.repairFeedback = 'Repaired for ' .. dollars(cost) .. '.' .. (timed and ' The repair cost you 5 minutes.' or '')
      .. ' Save to keep the new balance.'
    return true
  end

  -- Parts. The parts menu is BeamNG's own and changes parts for free; every change respawns the
  -- vehicle, so the HUD compares the fitted parts with the ones paid for after each spawn. The
  -- difference is billed on Buy, or the paid parts are put back on Revert. The respawn also mends
  -- all damage, so the bill includes the repair the car needed just before its first change.
  function c:vehicleSpawned()
    self.partsCheckDue = true
  end

  -- Adopts the fitted parts as paid for, when there is nothing to charge against.
  function c:adoptParts(snapshot)
    self.ownedParts, self.pendingParts, self.pendingCar = snapshot, nil, nil
    self.diag:event('parts_owned', tostring(snapshot.model) .. ' #' .. tostring(snapshot.id))
  end

  function c:checkParts()
    local snapshot = self.garage:parts()
    if not snapshot then return false end
    self.fittedParts = snapshot
    local owned = self.ownedParts
    -- The starter or saved car comes as paid for, even when it replaced a car of the same model.
    if self.arrivingModel and snapshot.model == self.arrivingModel then
      snapshot.value = snapshot.value or self.arrivingValue
      self.arrivingModel, self.arrivingValue = nil, nil
      self:adoptParts(snapshot)
      return true
    end
    if not self.profile or self.error or not owned then
      self:adoptParts(snapshot)
      return true
    end
    -- A different vehicle, or a different model in place of this one, is a car the player is buying.
    if owned.id ~= snapshot.id or owned.model ~= snapshot.model then return self:quoteCar(snapshot) end
    if self.pendingCar then
      self.pendingCar = nil
      self.carFeedback = 'Back in your own car. Nothing to pay.'
    end
    local diff = M.partsDiff(owned, snapshot)
    if not diff then
      if self.pendingParts then self.partsFeedback = 'Part changes undone. Nothing to pay.' end
      self.pendingParts = nil
      return true
    end
    local previous = self.pendingParts
    local damage = previous and previous.damage
      or (self.lastDamage and self.lastDamage.id == snapshot.id and self.lastDamage.damage) or (self.owedDamage + self.punctureDamage)
    local repair = M.repairCost(damage, self:carValueOf(snapshot.id))
    local position = previous and previous.position
      or (self.lastSample and self.lastSample.valid and location.copy(self.lastSample)) or nil
    local discount = self:heldPerk() == 'partsDiscount' and math.floor(diff.cost * perks.PARTS_DISCOUNT_SHARE + 0.5) or 0
    self.pendingParts = {
      id = snapshot.id, added = diff.added, removed = diff.removed, partsCost = diff.cost, discount = discount,
      repair = repair, damage = damage, cost = diff.cost - discount + repair, position = position,
    }
    self.quote = nil
    self.partsFeedback = self:canAfford(self.pendingParts.cost) and 'Press Buy to keep these parts, or Revert.'
      or ('Not enough money. You need ' .. dollars(self.pendingParts.cost - self.profile.progression.balance)
        .. ' more. Revert, or the parts go back when you drive off.')
    self.diag:event('parts_quote', string.format('%d parts, %d repair', diff.cost, repair))
    return true
  end

  -- Cars. Picking a car in the game's vehicle selector, or getting into any car that is not the
  -- player's, opens a bill: the car's price, plus parts changed on it since, less the trade-in of
  -- the player's car. The swap mends the old car, so its damage is frozen into the bill.
  function c:quoteCar(snapshot)
    local owned, previous = self.ownedParts, self.pendingCar
    local sameCar = previous and previous.id == snapshot.id and previous.model == snapshot.model
    local oldDamage = previous and previous.oldDamage
      or (self.pendingParts and self.pendingParts.damage)
      or (self.lastDamage and self.lastDamage.id == owned.id and self.lastDamage.damage) or (self.owedDamage + self.punctureDamage)
    local base = sameCar and previous.base or snapshot
    local extras = M.partsDiff(base, snapshot)
    local price = math.floor((base.value or DEFAULT_CAR_PRICE) + 0.5)
    local repair = M.repairCost(oldDamage, owned.value)
    local tradeIn = math.max(0, math.floor((owned.value or DEFAULT_CAR_PRICE) * CAR_TRADE_IN_SHARE + 0.5) - repair)
    local extrasCost = extras and extras.cost or 0
    local discount = self:heldPerk() == 'carDeal' and math.floor(price * perks.CAR_DISCOUNT_SHARE + 0.5) or 0
    self.pendingParts, self.quote = nil, nil
    self.pendingCar = {
      id = snapshot.id, model = snapshot.model, name = base.name or snapshot.model, base = base,
      price = price, discount = discount, extras = extrasCost, tradeIn = tradeIn, repair = repair, oldDamage = oldDamage,
      cost = math.max(0, price - discount + extrasCost - tradeIn), fromId = owned.id,
      position = previous and previous.position
        or (self.lastSample and self.lastSample.valid and location.copy(self.lastSample)) or nil,
    }
    local cost = self.pendingCar.cost
    self.carFeedback = self:canAfford(cost) and 'Press Buy car to keep it, or Revert to get your car back.'
      or ('Not enough money. You need ' .. dollars(cost - self.profile.progression.balance)
        .. ' more. Revert, or your car comes back when you drive off.')
    self.diag:event('car_quote', string.format('%s %d, trade-in %d', tostring(snapshot.model), cost, tradeIn))
    return true
  end

  function c:buyCar()
    if not self.profile or self.error then
      self.carFeedback = 'Buying cars is unavailable right now. Check the status above.'
      return false
    end
    local pending = self.pendingCar
    if not pending then
      self.carFeedback = 'No car to pay for.'
      return false
    end
    if not self:checkParts() then
      self.carFeedback = 'Could not read the car. Try again in a moment.'
      return false
    end
    if not self.pendingCar then return false end
    if self.pendingCar.cost ~= pending.cost or self.pendingCar.id ~= pending.id then
      self.carFeedback = 'The car changed, so the bill was updated. Press Buy car again to accept it.'
      return false
    end
    if not self:spend(pending.cost, 'car') then
      self.carFeedback = 'Not enough money. You need ' .. dollars(pending.cost - self.profile.progression.balance) .. ' more.'
      return false
    end
    -- Later part changes are priced against what was paid for, so the car keeps its own Value.
    local snapshot = self.fittedParts
    snapshot.value = pending.base.value
    self:adoptParts(snapshot)
    if pending.discount > 0 then self:usePerk('carDeal') end
    local timed = not self.carkov and not self:usePerk('noPenalty')
    if timed then self:addPenalty('car') end
    self.owedDamage, self.punctureDamage = 0, 0
    self.carFeedback = 'Bought ' .. tostring(pending.name) .. ' for ' .. dollars(pending.cost)
      .. (timed and '. The car change cost you 5 minutes.' or (self.carkov and '.' or '. No Penalty saved you the 5 minutes.'))
      .. ' Save to keep it.'
    return true
  end

  -- Puts the player back in their own car: the one they left, if it is still there, or else their
  -- car respawned in place. A respawned car looks new, but the repair it needed is still owed.
  function c:revertCar(droveOff)
    local pending, owned = self.pendingCar, self.ownedParts
    if not pending or not owned then
      self.carFeedback = 'No car to revert.'
      return false
    end
    local ok, why, detail
    local respawned = pending.id == pending.fromId
    if not respawned then
      ok = self.garage:enter(pending.fromId)
      respawned = not ok
    end
    if respawned then
      self.arrivingModel, self.arrivingValue = owned.model, owned.value
      ok, why, detail = self.garage:spawnConfig(owned.model, owned.config)
      if not ok then
        self.arrivingModel, self.arrivingValue = nil, nil
        self.carFeedback = 'Could not bring your car back. Try again in a moment.'
        self.diag:event('car_revert_failed', tostring(why) .. (detail and (': ' .. detail) or ''), 'E')
        return false
      end
      self.owedDamage, self.punctureDamage = pending.oldDamage, 0
    end
    self.pendingCar = nil
    self.carFeedback = droveOff and 'You drove off without paying, so your own car is back.' or 'Your own car is back.'
    return true
  end

  -- Called every tick: checks parts after a spawn or vehicle switch, notes the damage the vehicle has
  -- before a change, and puts the paid parts back if the player drives off without paying.
  function c:watchParts()
    if not self.garage then return end
    local vehicleId = self.lastSample and self.lastSample.valid and self.lastSample.vehicle and self.lastSample.vehicle.id
    local expected = self.pendingCar and self.pendingCar.id or (self.ownedParts and self.ownedParts.id)
    if vehicleId ~= nil and expected ~= nil and vehicleId ~= expected then self.partsCheckDue = true end
    if not self.ownedParts then self.partsCheckDue = true end
    if self.partsCheckDue then
      -- Damage is frozen until the check: the respawn has already reset it.
      if self:checkParts() then self.partsCheckDue = false end
      return
    end
    local inspected = self:inspectDamage()
    if inspected then self.lastDamage = inspected end
    local pending = self.pendingCar or self.pendingParts
    if pending and self.lastSample and self.lastSample.valid then
      if not pending.position then pending.position = location.copy(self.lastSample)
      else
        local moved = location.distance(pending.position, self.lastSample)
        local revert = self.pendingCar and self.revertCar or self.revertParts
        -- A failed revert is retried after another stretch of driving, not every frame.
        if moved and moved > UNPAID_PARTS_DRIVE_LIMIT and not revert(self, true) then
          pending.position = location.copy(self.lastSample)
        end
      end
    end
  end

  -- Confirms the bill still matches what is fitted. Returns the pending change, or nil after re-quoting.
  local function currentBill(self)
    local pending = self.pendingParts
    if not pending then
      self.partsFeedback = 'No part changes to pay for.'
      return nil
    end
    local before = pending.cost
    if not self:checkParts() then
      self.partsFeedback = 'Could not read the fitted parts. Try again in a moment.'
      return nil
    end
    if not self.pendingParts then return nil end
    if self.pendingParts.cost ~= before then
      self.partsFeedback = 'The parts changed, so the bill was updated. Press Buy again to accept it.'
      return nil
    end
    return self.pendingParts
  end

  function c:buyParts()
    if not self.profile or self.error then
      self.partsFeedback = 'Buying parts is unavailable right now. Check the status above.'
      return false
    end
    local pending = currentBill(self)
    if not pending then return false end
    if not self:spend(pending.cost, 'parts') then
      self.partsFeedback = 'Not enough money. You need ' .. dollars(pending.cost - self.profile.progression.balance) .. ' more.'
      return false
    end
    self:adoptParts(self.fittedParts)
    self.owedDamage, self.punctureDamage = 0, 0
    if pending.discount > 0 then self:usePerk('partsDiscount') end
    -- Parts alone cost no time, but a bill that includes a repair is a repair.
    local timed = pending.repair > 0 and self:repaired()
    self.partsFeedback = 'Bought for ' .. dollars(pending.cost) .. '.'
      .. (timed and ' The repair cost you 5 minutes.' or '') .. ' Save to keep the new balance.'
    return true
  end

  -- Respawns the vehicle with the paid parts. Nothing is charged: the change already mended the
  -- damage, so, as with a reverted car, the car looks new but its repair is still owed.
  function c:revertParts(droveOff)
    local pending = self.pendingParts
    if not pending or not self.ownedParts then
      self.partsFeedback = 'No part changes to revert.'
      return false
    end
    local ok, why, detail = self.garage:repair(self.ownedParts.config)
    if not ok then
      self.partsFeedback = 'Could not put the paid parts back. Try again in a moment.'
      self.diag:event('parts_revert_failed', tostring(why) .. (detail and (': ' .. detail) or ''), 'E')
      return false
    end
    -- The bill's damage already includes what was owed before the change.
    self.pendingParts, self.owedDamage, self.punctureDamage = nil, pending.damage or 0, 0
    self.partsFeedback = (droveOff and 'You drove off without paying, so the paid parts were put back.'
      or 'The paid parts were put back.') .. (pending.repair > 0 and ' Its repair is still owed.' or '')
    return true
  end

  -- Once per load, when the player reaches the resume point, their vehicle is swapped, where it
  -- stands, for the car of the last save, or the starter car on a fresh start. Like money, part
  -- changes since the last Save are undone by a reload. A save without a car config leaves the vehicle alone.
  function c:provideVehicle()
    if self.vehicleProvided or not self.garage or self.state ~= 'READY' or not self.arrived then return end
    self.vehicleProvided = true
    local model, config, label
    local configFile
    if self.mode == 'start' and not self.carriedCar then
      model, config, label, configFile = STARTER_MODEL, STARTER_CONFIG, 'starter_car', STARTER_CONFIG
    else
      config = self.profile and self.profile.vehicle and self.profile.vehicle.config
      if not config then return end
      model, label, configFile = config.model, self.carriedCar and 'carried_car' or 'saved_car', config.partConfigFilename
    end
    self.arrivingModel = model
    -- A car respawned from a saved config may not know its .pc file, so its price is looked up here.
    self.arrivingValue = self.garage.carValue and (self.garage:carValue(model, configFile)) or nil
    local ok, why, detail = self.garage:spawnConfig(model, config)
    if not ok then
      self.arrivingModel = nil
      self.diag:event(label .. '_failed', tostring(why) .. (detail and (': ' .. detail) or ''), 'E')
      return
    end
    if why == 'already_fitted' then self.arrivingModel = nil end
    self.diag:event(label, why or 'spawned')
  end

  -- The car Save keeps: the paid-for parts, with the paint and tuning fitted now. Only the fields
  -- a respawn needs are kept; nil when the game's config cannot be stored as plain data.
  function c:savedVehicleConfig()
    local owned = self.ownedParts
    if not owned or type(owned.config) ~= 'table' then return nil end
    local source, look = owned.config, owned.config
    local fitted = self.fittedParts
    if fitted and fitted.id == owned.id and type(fitted.config) == 'table' then look = fitted.config end
    local config = persistence.plainConfig({ model = source.model or owned.model, parts = source.parts,
      partsTree = source.partsTree, partConfigFilename = source.partConfigFilename or owned.configFile, vars = look.vars, paints = look.paints, licenseName = look.licenseName })
    if not config then self.diag:event('vehicle_config_unsaved', tostring(owned.model), 'W') end
    return config
  end

  -- The damage Save keeps with the car: what it has now plus what is still owed, or, with a parts
  -- bill open, what it had before the change mended it. A restored car owes its repair.
  function c:savedVehicleDamage()
    local damage = self.owedDamage + self.punctureDamage
    if self.pendingCar then damage = self.pendingCar.oldDamage
    elseif self.pendingParts then damage = self.pendingParts.damage
    elseif self.garage and self.ownedParts then
      local inspected = self:inspectDamage()
      if inspected and inspected.id == self.ownedParts.id then damage = inspected.damage end
    end
    return damage > 0 and math.min(MAX_BALANCE, damage) or nil
  end

  -- Adds the distance driven since the previous reading. Teleport-sized jumps only move the odometer.
  function c:addMileage(sample, dt)
    if self.odometer and location.finite(dt) and dt > 0 then
      local metres = location.distance(self.odometer, sample)
      if metres and metres <= MAX_DRIVING_SPEED * dt then
        local progression = self.profile.progression
        local rate = EARNINGS_PER_KM * (self:heldPerk() == 'doubleCash' and perks.DOUBLE_CASH_MULTIPLIER or 1)
        if progression.luckyUntilKm then
          if progression.totalDistanceKm < progression.luckyUntilKm then rate = rate * perks.LUCKY_MILE_MULTIPLIER end
          if progression.totalDistanceKm + metres / 1000 >= progression.luckyUntilKm then progression.luckyUntilKm = nil end
        end
        progression.totalDistanceKm = progression.totalDistanceKm + metres / 1000
        self:addMoney(metres / 1000 * rate)
        self:paySponsor()
        self:offerPerk()
        self:roadPuncture(sample, metres, dt)
        self:roadEvent(sample)
      end
    end
    self.odometer = location.copy(sample)
  end

  -- Road punctures. Each stretch driven has a small chance of bursting a tyre (see punctures.lua):
  -- more at speed, double off road, never within GAP_KM of the last one or SAFE_FINISH_METRES of
  -- the stage finish or CarKov extraction. The tyre repair is added to the repair, which mends it.
  -- Like mileage, the distance of the last puncture is kept by Save.
  function c:roadPuncture(sample, metres, dt)
    if not self.punctures or self.stageFinished or self.paused() or self.pendingParts or self.pendingCar
        or self.stuck or self.extractHold then return end
    local progression = self.profile.progression
    if progression.lastPunctureKm and progression.totalDistanceKm - progression.lastPunctureKm < punctures.GAP_KM then return end
    local goal = self.carkov and self.carkov.extraction or (self.stage and self.stage.finish)
    local left = goal and location.distance(sample, goal)
    if not left or left <= punctures.SAFE_FINISH_METRES then return end
    if not self.offRoadCheckedAt or self.clock - self.offRoadCheckedAt >= punctures.OFF_ROAD_CHECK_SECONDS then
      local ok, offRoad = pcall(self.punctures.offRoad, self.punctures)
      self.offRoad, self.offRoadCheckedAt = ok and offRoad == true, self.clock
    end
    if self.random() >= punctures.chance(metres, metres / dt * 3.6, self.offRoad) then return end
    local ok, why, detail = self.punctures:burst()
    if not ok then
      self.diag:event('puncture_failed', tostring(why) .. (detail and (': ' .. detail) or ''), 'E')
      return
    end
    progression.lastPunctureKm = progression.totalDistanceKm
    self.punctureDamage = self.punctureDamage + PUNCTURE_DAMAGE
    self.quote = nil
    self.punctureFlash = { at = self.clock }
    self.diag:event('puncture', string.format('%.1f km%s', progression.totalDistanceKm, self.offRoad and ' off road' or ''))
  end

  -- Roadside events (see roadEvents.lua). Each check due rolls for an event: a friendly village
  -- offering a free part, or bandits. A check is used up, with no event, while a bill is open, the
  -- player is stuck or extracting, a village offer is still open, or within SAFE_FINISH_METRES of
  -- the stage finish or CarKov extraction. Like perk offers, the checks made are kept by Save.
  function c:roadEvent(sample)
    if self.stageFinished then return end
    local progression = self.profile.progression
    local due = roadEvents.due(progression.totalDistanceKm)
    -- Saves from before roadside events start counting from here.
    if progression.roadEvents == nil then progression.roadEvents = due end
    if due <= progression.roadEvents then return end
    progression.roadEvents = due
    if self.paused() or self.pendingParts or self.pendingCar or self.stuck or self.extractHold or self.roadOffer then return end
    local goal = self.carkov and self.carkov.extraction or (self.stage and self.stage.finish)
    local left = goal and location.distance(sample, goal)
    if not left or left <= roadEvents.SAFE_FINISH_METRES then return end
    if self.random() >= roadEvents.CHANCE then return end
    if self.random() < roadEvents.VILLAGE_SHARE then self:offerGift() else self:bandits() end
  end

  function c:flashRoad(title, text)
    self.roadFlash = { title = title, text = text, at = self.clock }
  end

  -- Bandits take BANDITS_MIN to BANDITS_MAX dollars, never more than the player has.
  function c:bandits()
    local progression = self.profile.progression
    local taken = math.min(roadEvents.banditAmount(self.random), progression.balance)
    progression.balance = progression.balance - taken
    self:flashRoad('BANDITS!', taken > 0 and ('Bandits made off with ' .. dollars(taken) .. ' of your money.')
      or 'Bandits stopped you, but you had no money for them to take.')
    self.diag:event('road_bandits', tostring(taken))
  end

  -- A friendly village offers a better part for one slot of the car, picked at random from the
  -- garage's upgrades. With none to offer (or no way to read the parts), nothing happens.
  function c:offerGift()
    if not self.garage or type(self.garage.upgrades) ~= 'function' or not self.ownedParts then return false end
    local ok, list, why = pcall(self.garage.upgrades, self.garage, roadEvents.category)
    local gift = ok and roadEvents.pick(self.random, list) or nil
    if not gift then
      self.diag:event('road_gift_none', tostring(ok and why or list), 'W')
      return false
    end
    self.roadOffer = { vehicleId = self.ownedParts.id, path = gift.path, part = gift.part, name = gift.name, label = gift.label }
    self.diag:event('road_gift_offered', tostring(gift.path) .. ':' .. tostring(gift.part))
    return true
  end

  function c:roadOfferInstallAllowed()
    return self.roadOffer ~= nil and self:perkActionsAllowed() and not self.pendingParts and not self.pendingCar
  end

  -- Install: fits the part, which respawns the car mended, at no cost and with no time penalty, and
  -- keeps the perk held. The car comes back as paid for. Decline: turns the offer down.
  function c:answerRoadOffer(install)
    local offer = self.roadOffer
    if not offer or not self:perkActionsAllowed() then return false end
    if not install then
      self.roadOffer = nil
      self.diag:event('road_gift_declined', tostring(offer.part))
      return true
    end
    if not self:roadOfferInstallAllowed() then return false end
    local owned = self.ownedParts
    if not owned or owned.id ~= offer.vehicleId then
      self.roadOffer = nil
      self:flashRoad('FREE PART', 'The villagers\' part was for the car you had then, so it is gone.')
      return false
    end
    self.arrivingModel, self.arrivingValue = owned.model, owned.value
    local ok, why, detail = self.garage:fitPart(offer.path, offer.part)
    if not ok then
      self.arrivingModel, self.arrivingValue = nil, nil
      self:flashRoad('FREE PART', 'The part could not be fitted. Try again in a moment.')
      self.diag:event('road_gift_failed', tostring(why) .. (detail and (': ' .. detail) or ''), 'E')
      return false
    end
    self.roadOffer = nil
    self.owedDamage, self.punctureDamage, self.quote, self.stuck, self.still = 0, 0, nil, nil, nil
    self:flashRoad('FREE PART FITTED', offer.name .. ' fitted, and your car was repaired for free. Save to keep it.')
    self.diag:event('road_gift_installed', tostring(offer.path) .. ':' .. tostring(offer.part))
    return true
  end

  function c:observe(sample, dt)
    self.lastSample = sample
    self.diag:event('earth', tostring(sample.reason or 'available') .. ':' .. tostring(sample.detail or sample.source or ''))
    if not self.configuration then self:transition('CONFIG_REQUIRED', 'configuration'); return end
    if self.error then self:transition('ERROR', self.error); return end
    if not sample.valid or not location.valid(sample) then
      self:interrupt(sample.reason or 'position_invalid'); return
    end
    -- Any valid vehicle position starts the session: saving and mileage work wherever the vehicle is.
    if not self.profile then
      self.profile = persistence.newProfile(self.creationBase, sample, sample.vehicle, self.stage.id,
        self.stage.startingMoney)
      self.unsavedBase = location.copy(self.profile.base)
      self.diag:event('profile_initialised', 'default (in memory, not yet saved)')
    end
    self.sessionVerified = true
    -- Arriving within the radius of the resume point, usually by teleporting there from the map,
    -- confirms the player is back on their trek.
    if not self.arrived and self.startupTarget then
      local away = location.distance(sample, self.startupTarget)
      -- A CarKov drop zone is wider, so the player can teleport a little way off to dodge a cliff or river.
      local radius = self.mode == 'drop' and carkov.DROP_RADIUS_METRES or self.configuration.resumeRadiusMetres
      if away and away <= radius then
        self.arrived = true
        self.diag:event('arrived', string.format('%.1f m', away))
      end
    end
    -- Driving before then is not part of the trek.
    if self.arrived then self:addMileage(sample, dt) else self.odometer = nil end
    self:transition('READY', 'verified')
    -- On a CarKov run, staying in the extraction zone for EXTRACT_HOLD_SECONDS, with no bill open,
    -- pays out and ends the run. Leaving the zone starts the hold again.
    if self.carkov then
      local left = self.arrived and location.distance(sample, self.carkov.extraction)
      if left and left <= carkov.EXTRACTION_RADIUS_METRES and not self.pendingParts and not self.pendingCar then
        if not self.paused() then self.extractHold = (self.extractHold or 0) + math.min(dt, MAX_CLOCK_STEP) end
        if self.extractHold >= carkov.EXTRACT_HOLD_SECONDS then self:extract() end
      else
        self.extractHold = nil
      end
      return
    end
    -- Reaching the finish completes the stage and pays the stage complete reward, and the finish
    -- is saved straight away.
    if self.arrived and not self.stageFinished then
      local left = location.distance(sample, self.stage.finish)
      if left and left <= self.stage.finishRadiusMetres then
        self.stageFinished, self.stuck, self.still = true, nil, nil
        self.profile.progression.perkOffer, self.roadOffer = nil, nil
        self:addMoney(self.stage.finishReward)
        self.diag:event('stage_finished', self.stage.id .. string.format(' %.1f km', self.profile.progression.totalDistanceKm))
        self:manualSave()
      end
    end
  end

  -- Watches for a player who is out of money and cannot drive (see STUCK_DAMAGE). Insurance pays
  -- the repair then; otherwise the HUD offers the way out. With a parts bill open, the damage the
  -- part change mended counts. Moving off, or being able to pay, clears it.
  function c:watchStuck(dt)
    local sample = self.lastSample
    if self.stageFinished or not self.garage or self.state ~= 'READY' or not self.arrived
        or not sample or not sample.valid then
      self.stuck, self.still = nil, nil
      return
    end
    local damage = (self.pendingCar and self.pendingCar.oldDamage) or (self.pendingParts and self.pendingParts.damage)
    if not damage then
      local inspected = self:inspectDamage()
      damage = inspected and inspected.damage
    end
    local cost = damage and damage >= STUCK_DAMAGE and M.repairCost(damage, self:carValueOf(self.ownedParts and self.ownedParts.id)) or 0
    local moved = self.still and location.distance(self.still.position, sample)
    if cost == 0 or self:canAfford(cost) or not self.still or not moved or moved > STUCK_METRES then
      if self.stuck then self.diag:event('stuck_cleared', tostring(cost)) end
      self.stuck = nil
      self.still = { position = location.copy(sample), seconds = 0 }
      return
    end
    if not self.paused() then self.still.seconds = self.still.seconds + math.min(dt, MAX_CLOCK_STEP) end
    if self.still.seconds < STUCK_SECONDS then return end
    if not self.stuck then
      self.diag:event('stuck', string.format('%.1f damage, %d', damage, cost), 'W')
      if self:claimInsurance() then return end
    end
    self.stuck = { cost = cost }
  end

  -- Writes a save of this profile and makes it the loaded one. Returns it, or nil and why.
  -- The stages completed and the stage's entry carry over from the loaded save unless the candidate sets them.
  function c:record(candidate)
    candidate.schemaVersion, candidate.profileId = 1, 'default'
    -- Finished stages, the stage entry and a CarKov run carry over; false clears them.
    for _, key in ipairs({ 'completedStages', 'entry', 'carkov' }) do
      if candidate[key] == nil and self.profile then candidate[key] = self.profile[key] end
      if candidate[key] == false then candidate[key] = nil end
    end
    local saved, why = self.store:save(candidate)
    if not saved then return nil, why end
    self.profile, self.unsavedBase = saved, nil
    self.savedDistanceKm = saved.progression.totalDistanceKm
    self.savedBalance = saved.progression.balance
    return saved
  end

  -- Where a stage starts. config.json's base, when set, moves the first stage's start.
  function c:startOf(stage)
    if stage.id == stages.first().id then return location.copy(self.configuration.base) end
    return location.copy(stage.start)
  end
  function c:stageStart() return self:startOf(self.stage) end

  -- What a restart goes back to: the money and car the stage was started with, or, on the first
  -- stage, its starting money and the starter car.
  function c:stageEntry()
    local entry = self.profile and self.profile.entry
    if entry then return entry.balance, persistence.plainConfig(entry.vehicle.config) and {
      model = entry.vehicle.model, config = entry.vehicle.config, damage = entry.vehicle.damage } or {}, entry.perk end
    return self.stage.startingMoney, {}, nil
  end

  -- The ids of the stages the player has finished, each once, under its current id.
  function c:completedStageIds()
    local ids, seen = {}, {}
    local function add(id)
      local stage = stages.get(id)
      local key = stage and stage.id or id
      if not seen[key] then seen[key] = true; ids[#ids + 1] = key end
    end
    for _, id in ipairs(self.profile and self.profile.completedStages or {}) do add(id) end
    if self.stageFinished and self.stage then add(self.stage.id) end
    return ids
  end

  -- Why the player cannot pick a stage now, or nil when they can.
  function c:stageSelectBlocked()
    if self.error or not self.configuration or not self.stage then return 'Stages cannot be started right now. Check the status above.' end
    if self.carkov then return 'Quit your CarKov run on the CarKov tab before you start another stage.' end
    if self.pendingParts or self.pendingCar then
      return 'Pay for or put back your parts or car change on the Garage tab before you move on.'
    end
    return nil
  end

  -- Moves the save on to any stage, with the car and money the player has now. Stages are optional:
  -- none has to be finished first. Mileage, the clock and sponsor bonuses start again; the player
  -- goes to the stage's start for their car. The perk held comes too; a perk running now, or one on
  -- offer, stays behind with the stage. Leaving a stage that is not finished loses its progress, so
  -- the first press asks to confirm. A new player who has not saved yet starts it fresh, in the
  -- starter car with the stage's starting money.
  function c:startStage(id, confirmed)
    local target = type(id) == 'string' and stages.get(id) or nil
    if not target then
      self.feedback = 'That stage is not in this version of the mod.'
      return false
    end
    local blocked = self:stageSelectBlocked()
    if blocked then self.feedback = blocked; return false end
    if target.id == self.stage.id then
      self.feedback = 'You are on ' .. target.name .. ' already. Press Restart stage to start it again.'
      return false
    end
    local fresh = not self.profile or (self.profile.generation == 0 and not self.arrived)
    local losing = not fresh and not self.stageFinished
    if losing and not confirmed and self.stageArmed ~= target.id then
      self.stageArmed, self.restartArmed, self.newGameArmed = target.id, false, false
      self.feedback = 'Press Confirm to leave ' .. self.stage.name .. ' for ' .. target.name
        .. '. Your car and money come with you, but this stage\'s mileage, clock and sponsor bonuses are lost.'
      return false
    end
    self.stageArmed = nil
    local start = self:startOf(target)
    local candidate = { base = start, resume = start, stage = target.id, atStart = true }
    local carried = false
    if not fresh then
      -- On the stage, the car and money as they are now; otherwise as last saved.
      local vehicle
      if self.state == 'READY' and self.arrived then
        local config = self:savedVehicleConfig()
        vehicle = { model = config and config.model, config = config, damage = self:savedVehicleDamage() }
      else
        local saved = self.profile.vehicle or {}
        vehicle = { model = saved.model, config = saved.config, damage = saved.damage }
      end
      local balance = self.profile.progression.balance
      local perk = self:heldPerk()
      carried = vehicle.config ~= nil
      candidate.vehicle, candidate.completedStages = vehicle, self:completedStageIds()
      candidate.entry = { balance = balance, vehicle = vehicle, perk = perk }
      candidate.progression = { balance = balance, totalDistanceKm = 0, drivingSeconds = 0, penaltySeconds = 0,
        sponsorBonuses = 0, perkOffers = 0, perk = perk }
    else
      candidate.vehicle = {}
      candidate.progression = { balance = target.startingMoney, totalDistanceKm = 0, drivingSeconds = 0,
        penaltySeconds = 0, sponsorBonuses = 0, perkOffers = 0 }
    end
    local saved, why = self:record(candidate)
    if not saved then
      self.feedback = 'Could not start ' .. target.name .. ' just now. Your save is unchanged. Try again.'
      self.diag:event('stage_start_failed', tostring(why), 'E')
      return false
    end
    self.diag:event('stage_started', target.id .. (carried and '' or ' (car not carried)'))
    self:reload()
    self.feedback = target.name .. ' is ready. Go to the start' .. (self.carriedCar and ' to get your car.' or ' to get the starter car.')
    return true
  end

  -- The finish screen's shortcut: the stage after this one, once this one is finished.
  function c:startNextStage()
    local nextStage = self.stage and stages.after(self.stage.id)
    if not nextStage or not self.stageFinished or self.error or self.state ~= 'READY'
        or not self.arrived or not self.profile then
      self.feedback = 'Finish this stage first, or pick any stage from the Stages tab.'
      return false
    end
    return self:startStage(nextStage.id, true)
  end

  -- Starts the stage again: money, mileage, car and perk go back to the start, and the save is replaced.
  -- A second press confirms, since progress is lost.
  function c:restartStage()
    if self.error or not self.configuration or not self.stage then
      self.feedback = 'Restart is unavailable right now. Check the status above.'
      return false
    end
    if self.carkov then
      self.feedback = 'Quit your CarKov run on the CarKov tab before you restart the stage.'
      return false
    end
    if not self.restartArmed then
      self.restartArmed, self.stageArmed, self.newGameArmed = true, nil, false
      self.feedback = 'Press Confirm restart to start ' .. self.stage.name
        .. ' again. Your car, money, mileage, clock and perk go back to the start.'
      return false
    end
    local start = self:stageStart()
    local balance, vehicle, perk = self:stageEntry()
    local saved, why = self:record({ base = start, resume = start, progression = { balance = balance, totalDistanceKm = 0,
      drivingSeconds = 0, penaltySeconds = 0, sponsorBonuses = 0, perkOffers = 0, perk = perk },
      stage = self.stage.id, vehicle = vehicle, atStart = true })
    if not saved then
      self.restartArmed = false
      self.feedback = 'Could not restart just now. Press Restart stage to try again.'
      self.diag:event('stage_restart_failed', tostring(why), 'E')
      return false
    end
    self.diag:event('stage_restarted', self.stage.id)
    self:reload()
    self.feedback = 'Stage restarted. Go to the start to get ' .. (self.carriedCar and 'your car.' or 'your starter car.')
    return true
  end

  -- Starts the whole rally over: Stage 1 in the starter car with its starting money. Finished
  -- stages, perks, a CarKov run, mileage, the clock and sponsor bonuses are all wiped, and the save
  -- is replaced. A second press confirms, since none of it can be got back.
  function c:newGameAllowed()
    return self.configuration ~= nil and not self.store.blocked
  end

  function c:newGame()
    if not self:newGameAllowed() then
      self.feedback = 'New game is unavailable right now. Check the status above.'
      return false
    end
    if not self.newGameArmed then
      self.newGameArmed, self.restartArmed, self.stageArmed = true, false, nil
      self.feedback = 'Press Confirm new game to start the rally over in the starter car with '
        .. dollars(stages.first().startingMoney) .. '. Every stage, perk, CarKov run and dollar you have now is lost.'
      return false
    end
    local first = stages.first()
    local start = self:startOf(first)
    local saved, why = self:record({ base = start, resume = start, progression = { balance = first.startingMoney,
      totalDistanceKm = 0, drivingSeconds = 0, penaltySeconds = 0, sponsorBonuses = 0, perkOffers = 0 },
      stage = first.id, vehicle = {}, atStart = true, completedStages = false, entry = false, carkov = false })
    if not saved then
      self.newGameArmed = false
      self.feedback = 'Could not start a new game just now. Your save is unchanged. Press New game to try again.'
      self.diag:event('new_game_failed', tostring(why), 'E')
      return false
    end
    self.diag:event('new_game', first.id)
    self:reload()
    self.feedback = 'New game started. Go to the start of ' .. first.name .. ' to get your starter car.'
    return true
  end

  -- CarKov. Entering saves the stage where the player is, takes the fee and sends them to a random
  -- drop point with their car; the run gets its own progression (the perk held comes along), with no
  -- stage clock or sponsor bonus. Every way out goes back to the stage save with the car and money
  -- the player has then: extraction pays the reward, quitting pays nothing, and quitting while out of
  -- money and unable to drive also repairs the car as far as the money goes.
  local function copyTable(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
  end

  -- Why CarKov cannot be entered now, or nil when it can.
  function c:carkovEntryProblem()
    if self.carkov then return 'You are already on a CarKov run.' end
    if not self.profile or self.error or self.state ~= 'READY' or not self.arrived then
      return 'CarKov opens once you are on your stage. Check the status above.'
    end
    if self.pendingParts or self.pendingCar then
      return 'Pay for or put back your parts or car change on the Garage tab before you enter CarKov.'
    end
    if not self:canAfford(carkov.ENTRY_FEE) then
      return 'CarKov costs ' .. dollars(carkov.ENTRY_FEE) .. ' to enter. You need '
        .. dollars(carkov.ENTRY_FEE - self.profile.progression.balance) .. ' more.'
    end
    return nil
  end

  function c:enterCarKov()
    local problem = self:carkovEntryProblem()
    if problem then
      self.feedback = problem
      return false
    end
    -- Read the vehicle position at click time so the stage is saved where the player is now.
    local fresh = self.adapter:sample()
    if not fresh.valid or not location.valid(fresh) then
      self.feedback = 'Waiting for a valid vehicle position. Try again in a moment.'
      return false
    end
    local drop, extraction = carkov.pick(self.random)
    if not drop then
      self.feedback = 'Could not find a CarKov drop point. Try again.'
      self.diag:event('carkov_no_drop', '', 'W')
      return false
    end
    local progression = self.profile.progression
    local stageProgression = copyTable(progression)
    -- An open perk offer stays behind; the perk held goes on the run and comes back with the player.
    stageProgression.perkOffer = nil
    local config = self:savedVehicleConfig()
    local saved, why = self:record({ base = self.profile.base, resume = drop,
      progression = { balance = progression.balance - carkov.ENTRY_FEE, totalDistanceKm = 0, drivingSeconds = 0,
        penaltySeconds = 0, sponsorBonuses = 0, perkOffers = 0, perk = self:heldPerk() },
      vehicle = { model = config and config.model, config = config, damage = self:savedVehicleDamage() },
      stage = self.stage.id, atStart = true,
      carkov = { drop = drop, extraction = extraction, startBalance = progression.balance,
        stage = { resume = location.copy(fresh), progression = stageProgression, finished = self.stageFinished or nil },
        hostileAtKm = hostile.pickKm(self.random) } })
    if not saved then
      self.feedback = 'Could not enter CarKov just now. You have not been charged. Try again.'
      self.diag:event('carkov_enter_failed', tostring(why), 'E')
      return false
    end
    self.diag:event('carkov_entered', string.format('%.5f,%.5f to %.5f,%.5f', drop.latitude, drop.longitude,
      extraction.latitude, extraction.longitude))
    self:reload()
    self.extraction = nil
    self.feedback = 'Your stage is saved and you paid ' .. dollars(carkov.ENTRY_FEE) .. '. Go to the drop point to get your car.'
    return true
  end

  -- Ends the run and saves the stage again as it was on entry, with the money given and the car
  -- the player has now (or, before they reached the drop, the car they entered with).
  function c:leaveCarKov(result, balance, repaired)
    local run = self.carkov
    local vehicle = self.profile.vehicle
    if self.arrived then
      local config = self:savedVehicleConfig()
      vehicle = { model = config and config.model, config = config, damage = self:savedVehicleDamage() }
    end
    if repaired then vehicle = { model = vehicle.model, config = vehicle.config } end
    local progression = copyTable(run.stage.progression)
    progression.balance, progression.perk = balance, self:heldPerk()
    local saved, why = self:record({ base = self.profile.base, resume = run.stage.resume, progression = progression,
      vehicle = vehicle, stage = self.stage.id, finished = run.stage.finished, carkov = false })
    if not saved then
      self.diag:event('carkov_leave_failed', result .. ':' .. tostring(why), 'E')
      return false
    end
    self.diag:event('carkov_' .. result, tostring(balance))
    self:reload()
    return true
  end

  local carkovResults = {
    quit = { title = 'CARKOV QUIT', text = 'You left CarKov. The entry fee is lost.' },
    stranded = { title = 'CARKOV FAILED', text = 'You were out of money and could not drive, so the run is over and the entry fee is lost.' },
    hostile_disabled = { title = 'HOSTILE DISABLED', text = 'You took out the hostile and earned ' .. dollars(hostile.REWARD) .. '. Save to keep it.' },
    hostile_lost = { title = 'HOSTILE LOST', text = 'You left the hostile far behind. It is gone.' },
    hostile_escaped = { title = 'HOSTILE ESCAPED', text = 'The hostile got away' },
    hostile_fell = { title = 'HOSTILE LOST', text = 'The hostile fell out of the world. It is gone.' },
  }
  function c:flashCarKov(result, extra)
    local shown = carkovResults[result]
    self.carkovFlash = { result = result, title = shown.title, text = shown.text .. (extra or ''), at = self.clock }
  end

  -- Extraction: pays the reward and goes back to the stage. The save is made straight away. The
  -- EXTRACTION COMPLETE screen stays up until the player dismisses it.
  function c:extract()
    local progression = self.profile.progression
    local balance = math.min(MAX_BALANCE, progression.balance + carkov.REWARD)
    local result = { reward = carkov.REWARD, distanceKm = progression.totalDistanceKm,
      seconds = math.floor(progression.drivingSeconds or 0), balance = balance,
      -- What the run made overall: driving pay and the reward, less the fee and anything spent.
      net = self.carkov.startBalance and (balance - self.carkov.startBalance) or nil }
    if not self:leaveCarKov('extracted', balance) then return false end
    self.extraction = result
    self.feedback = 'Go back to your stage save to carry on. Your car and money come with you.'
    return true
  end

  function c:dismissExtraction()
    if not self.extraction then return false end
    self.extraction = nil
    return true
  end

  -- Quitting while out of money and unable to drive: the car is repaired, charged as far as the balance goes.
  function c:failCarKov(cost)
    local balance = self.profile.progression.balance
    local charged = math.min(cost, balance)
    if not self:leaveCarKov('stranded', balance - charged, true) then
      self.feedback = 'Could not quit just now. Try again.'
      return false
    end
    -- The car is respawned repaired at the stage save; this mends it where it stands meanwhile.
    if self.garage then self.garage:repair() end
    self:flashCarKov('stranded', charged > 0 and (' The repair took ' .. dollars(charged) .. '.') or '')
    self.feedback = 'Go back to your stage save to carry on in your repaired car.'
    return true
  end

  -- The CarKov hostile. Once per run, when the run's distance passes hostileAtKm (and the player is
  -- not within SAFE_EXTRACTION_METRES of the extraction), HOSTILE INBOUND counts down, then a
  -- hostile car is spawned ahead of the player, facing them, and comes at them. Once it has stood still for
  -- STILL_SECONDS with real damage, getting within CLAIM_METRES of it pays the bounty. Like
  -- driving pay, the bounty and the hostile having come are kept by Save. Close in, it can fire an
  -- EMP, rob the player and flee (hostile.lua's EMP); disabling it then gives the money back too.
  function c:clearHostile(reason)
    local encounter = self.hostile
    self.hostile = nil
    if not encounter or not encounter.id or not self.hostiles then return end
    -- The player's car is never left stalled.
    if encounter.emp then self.hostiles:emp(encounter.id, 'over') end
    local ok, why = self.hostiles:remove(encounter.id)
    self.diag:event('hostile_removed', reason .. (ok and '' or (':' .. tostring(why))), ok and 'I' or 'W')
  end

  -- The hostile's car: hostile.lua's MODEL and CONFIG when set, or else a copy of the player's car.
  function c:hostileCar()
    if hostile.MODEL and hostile.CONFIG then return hostile.MODEL, hostile.CONFIG end
    local snapshot = self.garage and self.garage:parts()
    if snapshot and type(snapshot.config) == 'table' then return snapshot.model, snapshot.config end
    return nil
  end

  function c:watchHostile(dt)
    local run = self.carkov
    if not run or not self.hostiles or self.error then
      self:clearHostile('no_run')
      return
    end
    if self.paused() then return end
    local step = math.min(dt, MAX_CLOCK_STEP)
    local encounter = self.hostile
    if encounter and encounter.emp then self:tickEmp(encounter, step) end
    if self.state ~= 'READY' or not self.arrived then return end
    if not encounter then
      if run.hostileDone or not run.hostileAtKm or self.profile.progression.totalDistanceKm < run.hostileAtKm then return end
      run.hostileDone = true
      local left = self.lastSample and location.distance(self.lastSample, run.extraction)
      if not left or left <= hostile.SAFE_EXTRACTION_METRES then
        self.diag:event('hostile_skipped', string.format('%.0f m from extraction', left or -1))
        return
      end
      self.hostile = { phase = 'inbound', left = hostile.WARNING_SECONDS }
      self.diag:event('hostile_inbound', string.format('%.1f km', self.profile.progression.totalDistanceKm))
      return
    end
    if encounter.phase == 'inbound' then
      encounter.left = encounter.left - step
      -- A player who is out of money and cannot drive is left alone until it is sorted out.
      if encounter.left > 0 or self.stuck then return end
      local model, config = self:hostileCar()
      local id, why, detail
      local side = (self.random() < 0.5 and -1 or 1) * hostile.SPAWN_SIDE_METRES
      if model then id, why, detail = self.hostiles:spawn(model, config, hostile.SPAWN_AHEAD_METRES, side)
      else why = 'car_unavailable' end
      if not id then
        -- No ground with collision ahead of the player yet (BeamNG.Earth still streaming it in): try
        -- again each second for a while.
        encounter.waited = (encounter.waited or 0) + 1
        if why == 'no_ground' and encounter.waited <= hostile.SPAWN_WAIT_SECONDS then
          encounter.left = 1
          return
        end
        self.hostile = nil
        self.diag:event('hostile_spawn_failed', tostring(why) .. (detail and (': ' .. detail) or ''), 'E')
        return
      end
      self.hostile = { phase = 'chasing', id = id, still = 0, brain = { empFired = encounter.empDone }, airborne = 0,
        respawns = encounter.respawns or 0 }
      self.diag:event('hostile_spawned', tostring(model) .. ' #' .. tostring(id))
      return
    end
    local status, why = self.hostiles:status(encounter.id)
    if not status then
      if why == 'vehicle_gone' then
        self.hostile = nil
        self.diag:event('hostile_gone', '', 'W')
      end
      return
    end
    encounter.damage, encounter.distance = status.damage, status.distance
    -- Fallen through the world (no ground under it): respawned ahead of the player, a few times a run.
    -- Fleeing with the player's money, it has got away with it instead.
    encounter.airborne = status.grounded == false and encounter.airborne + step or 0
    local fleeing = encounter.brain.fleeing and not encounter.disabled
    if fleeing and (encounter.airborne >= hostile.FALL_SECONDS
        or (status.distance and status.distance > hostile.EMP.ESCAPE_METRES)) then
      self:hostileEscaped(encounter.airborne >= hostile.FALL_SECONDS and 'fell' or 'far')
      return
    end
    if encounter.airborne >= hostile.FALL_SECONDS then
      local respawns = encounter.respawns + 1
      self:clearHostile('fell')
      if respawns > hostile.RESPAWN_TRIES then
        self:flashCarKov('hostile_fell')
        return
      end
      self.hostile = { phase = 'inbound', left = 1, respawns = respawns, empDone = encounter.brain.empFired }
      self.diag:event('hostile_respawn', tostring(respawns), 'W')
      return
    end
    -- The brain picks how it drives: straight at the player, the chase AI, reversing out when
    -- stuck, or backing off to ram again.
    local mode = encounter.brain.mode
    local command = hostile.think(encounter.brain, status, step)
    if command then self.hostiles:drive(encounter.id, command) end
    if self.hostiles.emp and hostile.empReady(encounter.brain, status) then self:fireEmp(encounter) end
    if encounter.brain.mode ~= mode then self.diag:event('hostile_mode', tostring(encounter.brain.mode)) end
    -- Standing still while reversing out or backing off is trying, not disabled.
    encounter.still = status.speed <= hostile.STILL_SPEED and hostile.counts(encounter.brain) and encounter.still + step or 0
    encounter.disabled = encounter.still >= hostile.STILL_SECONDS and status.damage >= hostile.DISABLED_DAMAGE
    if encounter.disabled and status.distance and status.distance <= hostile.CLAIM_METRES then
      local stolen = encounter.stolen or 0
      self:addMoney(hostile.REWARD + stolen)
      self:clearHostile('disabled')
      self:flashCarKov('hostile_disabled', stolen > 0 and (' You also got back the ' .. dollars(stolen) .. ' it took.') or nil)
      self.diag:event('hostile_bounty', string.format('%.0f damage', status.damage))
    elseif status.distance and status.distance > hostile.LOST_METRES then
      self:clearHostile('lost')
      self:flashCarKov('hostile_lost')
    end
  end

  -- The EMP fires at the player's car: it takes ROB_SHARE of their money (at most ROB_MAX) and the
  -- hostile pulls up, then flees with it. With nothing to take it goes back to ramming.
  function c:fireEmp(encounter)
    local progression = self.profile.progression
    local taken = math.min(hostile.robAmount(progression.balance), progression.balance)
    progression.balance = progression.balance - taken
    encounter.stolen = taken
    encounter.emp = { left = hostile.EMP.SECONDS, shock = hostile.EMP.SHOCK_SECONDS }
    local ok, why = self.hostiles:emp(encounter.id, 'start')
    self.hostiles:drive(encounter.id, hostile.rob(encounter.brain, taken > 0))
    self.diag:event('hostile_emp', tostring(taken) .. (ok and '' or (':' .. tostring(why))), ok and 'I' or 'W')
  end

  -- Counts the EMP down on game time: the shove ends after SHOCK_SECONDS, the car comes back after SECONDS.
  function c:tickEmp(encounter, step)
    local emp = encounter.emp
    if emp.shock then
      emp.shock = emp.shock - step
      if emp.shock <= 0 then
        emp.shock = nil
        self.hostiles:emp(encounter.id, 'shock_over')
      end
    end
    emp.left = emp.left - step
    if emp.left <= 0 then
      encounter.emp = nil
      self.hostiles:emp(encounter.id, 'over')
    end
  end

  -- The hostile got away with the player's money: far enough off that BeamNG.Earth has no ground
  -- for it, or already through the world. The money is gone.
  function c:hostileEscaped(how)
    local stolen = self.hostile.stolen or 0
    self:clearHostile('escaped')
    self:flashCarKov('hostile_escaped', ' with ' .. dollars(stolen) .. ' of your money.')
    self.diag:event('hostile_escaped', how .. ' ' .. tostring(stolen))
  end

  -- What the HUD shows of the hostile, or nil when there is none.
  function c:hostileView()
    local encounter = self.hostile
    if not encounter then return nil end
    if encounter.phase == 'inbound' then
      return { phase = 'inbound', seconds = math.max(0, math.ceil(encounter.left)), reward = hostile.REWARD,
        claimMetres = hostile.CLAIM_METRES }
    end
    local phase = encounter.disabled and 'disabled' or encounter.emp and 'emp'
      or encounter.brain.fleeing and 'fleeing' or 'chasing'
    return { phase = phase, reward = hostile.REWARD,
      distanceMetres = encounter.distance and math.floor(encounter.distance + 0.5) or nil,
      claimMetres = hostile.CLAIM_METRES, stillSeconds = hostile.STILL_SECONDS,
      stolen = encounter.stolen and encounter.stolen > 0 and encounter.stolen or nil,
      empSeconds = encounter.emp and math.max(0, math.ceil(encounter.emp.left)) or nil,
      escapeMetres = encounter.brain.fleeing and hostile.EMP.ESCAPE_METRES or nil }
  end

  -- Quits the run; a second press confirms. Out of money and unable to drive, the car is repaired as far as the money goes.
  function c:quitCarKov()
    if not self.carkov or not self.profile or self.error then
      self.feedback = 'You are not on a CarKov run.'
      return false
    end
    if self.pendingParts or self.pendingCar then
      self.feedback = 'Pay for or put back your parts or car change on the Garage tab before you quit.'
      return false
    end
    if not self.quitArmed then
      self.quitArmed = true
      self.feedback = 'Press Confirm quit to leave CarKov. The ' .. dollars(carkov.ENTRY_FEE) .. ' entry fee is lost.'
      return false
    end
    self.quitArmed = false
    if self.stuck then return self:failCarKov(self.stuck.cost) end
    if not self:leaveCarKov('quit', self.profile.progression.balance) then
      self.feedback = 'Could not quit just now. Try again.'
      return false
    end
    self:flashCarKov('quit')
    self.feedback = 'Go back to your stage save to carry on. Your car and money come with you.'
    return true
  end

  function c:carkovView(current)
    local run = self.carkov
    local onRun = run ~= nil and current ~= nil and self.arrived
    local flash = self.carkovFlash and self.clock - self.carkovFlash.at < CARKOV_SHOWN_FOR
    return {
      fee = carkov.ENTRY_FEE, reward = carkov.REWARD, extractionKm = carkov.EXTRACTION_KM,
      dropRadiusMetres = carkov.DROP_RADIUS_METRES,
      hostileReward = self.hostiles and hostile.REWARD or nil, hostileFromKm = hostile.SPAWN_FROM_KM,
      hostileToKm = hostile.SPAWN_TO_KM, hostileClaimMetres = hostile.CLAIM_METRES,
      active = run ~= nil,
      enterAllowed = self:carkovEntryProblem() == nil,
      extraction = run and location.copy(run.extraction) or nil,
      -- Straight-line distance and compass direction to the extraction point, once at the drop.
      extractionDistanceMetres = onRun and location.distance(current, run.extraction) or nil,
      extractionDirection = onRun and location.compassPoint(location.bearing(current, run.extraction)) or nil,
      distanceKm = run and self.profile and self.profile.progression.totalDistanceKm or nil,
      quitAllowed = run ~= nil and not self.error and not self.pendingParts and not self.pendingCar,
      quitArmed = self.quitArmed,
      closingInMetres = carkov.CLOSING_IN_METRES,
      -- Seconds left to hold in the extraction zone, while the car is in it.
      hold = self.extractHold and { seconds = math.max(0, math.ceil(carkov.EXTRACT_HOLD_SECONDS - self.extractHold)),
        progress = math.min(1, self.extractHold / carkov.EXTRACT_HOLD_SECONDS) } or nil,
      -- The EXTRACTION COMPLETE screen, until dismissed.
      complete = self.extraction,
      flash = flash and { result = self.carkovFlash.result, title = self.carkovFlash.title, text = self.carkovFlash.text } or nil,
      hostile = self:hostileView(),
    }
  end

  function c:stageListView()
    local done = {}
    for _, id in ipairs(self:completedStageIds()) do done[id] = true end
    local out = {}
    for i, stage in ipairs(stages.all()) do
      out[i] = {
        id = stage.id, name = stage.name, number = stage.number, startTown = stage.startTown, finishTown = stage.finishTown,
        summary = stage.summary, difficulty = stage.difficulty, lengthKm = stage.lengthKm, lengthIsStraight = stage.lengthIsStraight,
        targetSeconds = stage.targetSeconds, estimate = stage.targetIsEstimate,
        sponsorBonus = stage.sponsorBonus, sponsorEveryKm = stage.sponsorEveryKm, finishReward = stage.finishReward,
        completed = done[stage.id] == true, current = self.stage ~= nil and self.stage.id == stage.id,
      }
    end
    return out
  end

  function c:view()
    local current = self.lastSample and self.lastSample.valid and location.copy(self.lastSample) or nil
    -- Where the player goes to carry on: the last save, or the start before the first save.
    local resume = not self.arrived and not self.error and location.copy(self.startupTarget) or nil
    local stageName = self.stage and self.stage.name or ''
    local upcoming = self.stage and stages.after(self.stage.id) or nil
    local nextStage = self.stageFinished and upcoming or nil
    local base = location.copy(self.profile and self.profile.base or self.creationBase)
    local status = messages[self.reason]
    -- A quote only stands for the vehicle it was made for.
    local quote = self.quote
    local vehicleId = self.lastSample and self.lastSample.valid and self.lastSample.vehicle and self.lastSample.vehicle.id
    if quote and (self.error or vehicleId ~= quote.vehicleId) then quote = nil end
    if self.state == 'CONFIG_REQUIRED' then
      status = 'Set valid base coordinates in the rally configuration, then load the level again.'
    elseif self.state == 'ERROR' then
      status = errorMessages[self.error] or errorMessages.internal_error
    elseif self.state == 'READY' and self.stageFinished then
      status = nextStage and ('You conquered ' .. stageName .. '! Press Start ' .. nextStage.name .. ' to take your car and money on to '
          .. nextStage.startTown .. '.')
        or ('You conquered ' .. stageName .. '! Pick another stage from the Stages tab, or press Restart stage to run it again.')
    elseif self.state == 'READY' and self.stuck then
      status = 'Out of money and can\'t drive? The repair costs ' .. dollars(self.stuck.cost) .. ' and you have '
        .. dollars(self.profile.progression.balance) .. '. If your car will not move, '
        .. (self.carkov and 'press Quit run to leave CarKov in a repaired car.' or ('press Restart stage to start ' .. stageName .. ' again.'))
    elseif self.state == 'READY' and self.carkov and self.arrived and (self.pendingParts or self.pendingCar)
        and current and (location.distance(current, self.carkov.extraction) or math.huge) <= carkov.EXTRACTION_RADIUS_METRES then
      status = 'You are at the extraction point. Pay for or put back your parts or car change on the Garage tab to extract.'
    elseif self.state == 'READY' and self.carkov and self.arrived then
      status = 'CarKov: reach the extraction point to earn ' .. dollars(carkov.REWARD) .. '. Off road is fine. Save to keep your progress.'
    elseif self.state == 'READY' then
      status = self.arrived and arrivedMessages[self.mode]
        or goMessages[self.mode == 'drop' and 'drop' or (self.carriedCar and 'carried' or self.mode)]
    elseif not status then status = messages.position_invalid end
    local label = labels[self.state]
    if self.state == 'CONFIG_REQUIRED' or self.state == 'ERROR' then -- keep the label
    elseif self.state == 'READY' and self.stageFinished then label = 'STAGE COMPLETE'
    elseif self.state == 'READY' and self.stuck then label = 'STUCK'
    elseif self.state == 'READY' and not self.arrived then label = goLabels[self.mode]
    elseif self.state == 'READY' and self.carkov then label = 'CARKOV' end
    local active = self.profile ~= nil and not self.error
    local timer
    -- A CarKov run has no stage clock or sponsor bonus.
    if self.stage and self.stage.targetSeconds and not self.carkov then
      local progression = self.profile and self.profile.progression or {}
      local driving, penalties = progression.drivingSeconds or 0, progression.penaltySeconds or 0
      local credit = progression.timeCreditSeconds or 0
      local elapsed = driving + penalties - credit
      local shown = self.penalty and self.clock - self.penalty.at < PENALTY_SHOWN_FOR
      timer = {
        targetSeconds = self.stage.targetSeconds, estimate = self.stage.targetIsEstimate,
        -- Whole seconds left; negative once the limit has passed and the player is in overtime.
        remainingSeconds = math.ceil(self.stage.targetSeconds - elapsed),
        drivingSeconds = math.floor(driving), penaltySeconds = penalties, creditSeconds = credit,
        elapsedSeconds = math.floor(elapsed),
        -- Time Freeze seconds left; the clock stands still while there are any.
        freezeSeconds = progression.freezeSeconds and math.ceil(progression.freezeSeconds) or nil,
        running = self:clockRunning(), started = self.arrived or elapsed > 0,
        aheadSeconds = (self.arrived and current and self.configuration)
          and self:paceSeconds(current, elapsed) or nil,
        penalty = shown and { reason = self.penalty.reason, seconds = PENALTY_SECONDS } or nil,
      }
    end
    local punctureShown = self.punctureFlash ~= nil and self.clock - self.punctureFlash.at < punctures.SHOWN_FOR
    local roadShown = self.roadFlash ~= nil and self.clock - self.roadFlash.at < roadEvents.SHOWN_FOR
    local onStage = current ~= nil and self.arrived and self.stage ~= nil and not self.carkov
    local sponsor
    if self.stage and not self.carkov then
      local progression = self.profile and self.profile.progression or {}
      local every = self.stage.sponsorEveryKm
      local paid = progression.sponsorBonuses or 0
      local flash = self.sponsorFlash and self.clock - self.sponsorFlash.at < SPONSOR_SHOWN_FOR
      sponsor = {
        amount = self.stage.sponsorBonus, everyKm = every, earned = paid, earnedMoney = paid * self.stage.sponsorBonus,
        -- Kilometres to the next bonus, and how far through this stretch the player is (0 to 1).
        nextKm = math.max(0, (paid + 1) * every - (progression.totalDistanceKm or 0)),
        progress = math.max(0, math.min(1, 1 - ((paid + 1) * every - (progression.totalDistanceKm or 0)) / every)),
        flash = flash and { amount = self.sponsorFlash.amount } or nil,
      }
    end
    local perk
    if self.stage then
      local progression = self.profile and self.profile.progression or {}
      local function shown(id)
        local p = id and perks.get(id)
        return p and { id = p.id, name = p.name, description = p.description, activate = p.activate == true } or nil
      end
      local held = self:heldPerk()
      local actions = self:perkActionsAllowed()
      local flash = self.perkFlash and self.clock - self.perkFlash.at < PERK_SHOWN_FOR
      local repairNote
      if held == 'noPenalty' then repairNote = 'Your No Penalty perk covers the 5 minutes of the next repair.'
      elseif held == 'insurance' then repairNote = 'Repairs keep your Insurance perk.'
      elseif held then repairNote = 'Repairing loses your ' .. perks.get(held).name .. ' perk.' end
      perk = {
        held = shown(held), offer = actions and shown(progression.perkOffer) or nil,
        activateAllowed = actions and held ~= nil and perks.get(held).activate == true and not (self.carkov and CLOCK_PERKS[held]),
        offerAllowed = actions and progression.perkOffer ~= nil,
        everyKm = perks.OFFER_EVERY_KM,
        nextKm = math.max(0, ((progression.perkOffers or 0) + 1) * perks.OFFER_EVERY_KM - (progression.totalDistanceKm or 0)),
        luckyKm = progression.luckyUntilKm and math.max(0, progression.luckyUntilKm - (progression.totalDistanceKm or 0)) or nil,
        freezeSeconds = progression.freezeSeconds and math.ceil(progression.freezeSeconds) or nil,
        repairNote = repairNote,
        flash = flash and { title = self.perkFlash.title, text = self.perkFlash.text } or nil,
        list = perks.list(),
      }
    end
    return {
      state = self.state, stateLabel = label, mode = self.mode,
      sessionStatus = status, arrived = self.arrived,
      -- The base is not shown; it stays in the state for tools and tests.
      base = base,
      resume = resume,
      resumeDistanceMetres = current and resume and location.distance(current, resume) or nil,
      stage = self.stage and {
        name = self.stage.name, finish = location.copy(self.stage.finish),
        startTown = self.stage.startTown, finishTown = self.stage.finishTown, briefing = self.stage.briefing,
        number = self.stage.number, count = self.stage.count, finishReward = self.stage.finishReward,
      } or nil,
      -- Offered once the stage is finished, when there is a stage after it.
      nextStage = nextStage and { name = nextStage.name, startTown = nextStage.startTown } or nil,
      nextStageAllowed = nextStage ~= nil and self.state == 'READY' and self.arrived
        and not self.error and not self.pendingParts and not self.pendingCar,
      carriedCar = self.carriedCar,
      -- Every stage, any of which the player can start; the one they are on and those finished are marked.
      stageList = self:stageListView(),
      stageSelectAllowed = self:stageSelectBlocked() == nil,
      stageArmed = self.stageArmed,
      -- Straight-line distance and compass direction, shown once the player is on the stage.
      finishDistanceMetres = onStage and location.distance(current, self.stage.finish) or nil,
      finishDirection = onStage and location.compassPoint(location.bearing(current, self.stage.finish)) or nil,
      stageFinished = self.stageFinished, timer = timer, sponsor = sponsor, perk = perk,
      -- Out of money and can't drive: the repair it needs, the balance, and the way out offered.
      stuck = self.stuck and { cost = self.stuck.cost, balance = self.profile.progression.balance,
        action = self.carkov and 'quit' or 'restart' } or nil,
      restartAllowed = self.stage ~= nil and self.configuration ~= nil and not self.error and not self.carkov,
      restartArmed = self.restartArmed,
      newGameAllowed = self:newGameAllowed(),
      newGameArmed = self.newGameArmed,
      vehicle = current and self.lastSample.vehicle and {
        model = self.lastSample.vehicle.model, id = self.lastSample.vehicle.id,
      } or nil,
      balance = self.profile and self.profile.progression.balance or (self.stage and self.stage.startingMoney) or 0,
      totalDistanceKm = self.profile and self.profile.progression.totalDistanceKm or 0,
      unsavedDistanceKm = self.profile and math.max(0, self.profile.progression.totalDistanceKm - self.savedDistanceKm) or 0,
      unsavedBalance = self.profile and math.max(0, self.profile.progression.balance - self.savedBalance) or 0,
      unsavedSpending = self.profile and math.max(0, self.savedBalance - self.profile.progression.balance) or 0,
      testMoneyAllowed = active,
      repairQuoteAllowed = active and self.garage ~= nil,
      repairQuote = quote and quote.cost or nil,
      repairOwed = self.owedDamage > 0 and M.repairCost(self.owedDamage, self:carValueOf(self.ownedParts and self.ownedParts.id)) or nil,
      repairAllowed = quote ~= nil and not self.pendingParts and not self.pendingCar,
      repairFeedback = self.repairFeedback,
      partsChange = self.pendingParts and {
        added = self.pendingParts.added, removed = self.pendingParts.removed,
        partsCost = self.pendingParts.partsCost, discount = self.pendingParts.discount,
        repair = self.pendingParts.repair, cost = self.pendingParts.cost,
      } or nil,
      buyPartsAllowed = self.pendingParts ~= nil and self:canAfford(self.pendingParts.cost),
      revertPartsAllowed = self.pendingParts ~= nil,
      partsFeedback = self.partsFeedback,
      carChange = self.pendingCar and {
        name = self.pendingCar.name, price = self.pendingCar.price, discount = self.pendingCar.discount,
        extras = self.pendingCar.extras,
        tradeIn = self.pendingCar.tradeIn, cost = self.pendingCar.cost,
      } or nil,
      buyCarAllowed = self.pendingCar ~= nil and self:canAfford(self.pendingCar.cost),
      revertCarAllowed = self.pendingCar ~= nil,
      carFeedback = self.carFeedback,
      saveAllowed = self.state == 'READY' and self.arrived,
      saveFeedback = self.feedback,
      carkov = self:carkovView(current),
      -- Puncture! for a few seconds after a tyre bursts, and its tyre repair until it is repaired.
      -- Roadside events: a friendly village's offer, and what just happened for a few seconds.
      road = (self.roadOffer or roadShown) and {
        offer = self.roadOffer and { label = self.roadOffer.label, name = self.roadOffer.name } or nil,
        installAllowed = self:roadOfferInstallAllowed(),
        declineAllowed = self.roadOffer ~= nil and self:perkActionsAllowed(),
        flash = roadShown and { title = self.roadFlash.title, text = self.roadFlash.text } or nil,
      } or nil,
      puncture = (self.punctureDamage > 0 or punctureShown) and {
        flash = punctureShown,
        owed = self.punctureDamage > 0,
        tyreCost = math.floor(self.punctureDamage / PUNCTURE_DAMAGE + 0.5)
          * math.floor(PUNCTURE_DAMAGE * M.repairRate(self:carValueOf(self.ownedParts and self.ownedParts.id)) + 0.5),
      } or nil,
    }
  end

  function c:tick(dtReal)
    local dt = location.finite(dtReal) and math.max(0, dtReal) or 0
    self.clock = self.clock + dt
    self:observe(self.adapter:sample(), dt)
    self:provideVehicle()
    self:watchParts()
    self:watchStuck(dt)
    self:watchHostile(dt)
    self:runClock(dt)
    self.ui:publish(self:view(), self.clock)
  end

  function c:manualSave()
    if self.state ~= 'READY' or not self.profile or self.error then
      self.feedback = 'Save is unavailable right now. Check the status above.'
      self.diag:event('manual_save_rejected', tostring(self.state), 'W')
      return false
    end
    -- Until the player reaches the resume point they are not in their own car, so a Save would
    -- replace the saved car and location with the stand-in vehicle and wherever it is.
    if not self.arrived then
      self.feedback = 'Go to the coordinates above before saving.'
      self.diag:event('manual_save_rejected', 'not_arrived', 'W')
      return false
    end
    -- Read the vehicle position at click time so the saved location is current.
    local fresh = self.adapter:sample()
    if not fresh.valid or not location.valid(fresh) then
      self.lastSample = fresh
      self:interrupt(fresh.reason or 'position_invalid')
      self.feedback = 'Save paused. Waiting for a valid vehicle position.'
      self.diag:event('manual_save_rejected', fresh.reason or 'position_invalid', 'W')
      return false
    end
    local saved, why = self:record({
      base = self.profile.base, resume = location.copy(fresh), progression = self.profile.progression,
      vehicle = { model = fresh.vehicle and fresh.vehicle.model, config = self:savedVehicleConfig(),
        damage = self:savedVehicleDamage() },
      stage = self.stage.id, finished = self.stageFinished or nil,
    })
    if not saved then
      -- Nothing is lost: the last save is untouched and the session carries on, so Save can be tried again.
      self.feedback = 'Could not save just now. Your last save is still safe. Press Save to try again.'
      self.diag:clear('manual_save_failed'); self.diag:event('manual_save_failed', why, 'E')
      return false
    end
    self.lastSample = fresh
    self.feedback = self.stageFinished and 'Your finish is saved.' or 'Saved successfully.'
    self.diag:clear('manual_save_succeeded'); self.diag:event('manual_save_succeeded', 'generation ' .. saved.generation)
    return true
  end

  -- Testing aid: adds money to the in-memory balance. Like driving earnings, it is kept by Save.
  function c:addTestMoney()
    if not self.profile or self.error then
      self.diag:event('test_money_rejected', tostring(self.state), 'W')
      return false
    end
    self:addMoney(TEST_MONEY)
    self.diag:event('test_money_added', tostring(TEST_MONEY))
    return true
  end

  function c:mount(on)
    if self.ui:mount(on, self.clock) then
      self.diag:clear('ui_initialised'); self.diag:event('ui_initialised', 'Earth Enduro HUD')
    end
  end

  c:reload()
  return c
end

local active
local function gameIO()
  return {
    read = function(path) return jsonReadFile(path) end,
    exists = function(path) return FS:fileExists(path) end,
    mkdir = function(path)
      if not FS:directoryExists(path) then FS:directoryCreate(path, true) end
      return FS:directoryExists(path)
    end,
    -- Compact JSON: the pretty writer may round coordinates.
    write = function(path, data) return jsonWriteFile(path, data, false) end,
  }
end
-- Whether the game is paused; the stage clock stops while it is.
local function gamePaused()
  for _, name in ipairs({ 'bullettime', 'simTimeAuthority' }) do
    local timing = rawget(_G, name)
    if type(timing) == 'table' and type(timing.getPause) == 'function' then return timing.getPause() == true end
  end
  return false
end
local function ensure()
  if not active then
    active = M.new({ io = gameIO(), adapter = earthAdapter.new(), garage = garage.new(), hostiles = hostile.new(),
      punctures = punctures.new(),
      log = rawget(_G, 'log'),
      paused = gamePaused, trigger = function(event, payload) if guihooks then guihooks.trigger(event, payload) end end })
  end
  return active
end
local function safely(f)
  local ok, result = pcall(f)
  if not ok then
    if active then
      active.error, active.feedback = 'internal_error', 'Anything since your last save is lost when you reload.'
      active:transition('ERROR', 'internal_error')
      active.diag:event('internal_error', tostring(result), 'E')
    elseif log then log('E', 'beamngEarthEnduro', tostring(result)) end
    return false
  end
  return result
end

function M.onExtensionLoaded()
  return safely(function() local c = ensure(); c.diag:event('extension_loaded', 'Earth Enduro') end)
end
function M.onPreRender(dtReal)
  return safely(function() ensure():tick(dtReal) end)
end
function M.save() return safely(function() return ensure():manualSave() end) end
function M.addTestMoney() return safely(function() return ensure():addTestMoney() end) end
function M.requestRepairQuote() return safely(function() return ensure():requestRepairQuote() end) end
function M.repairVehicle() return safely(function() return ensure():repairVehicle() end) end
function M.buyParts() return safely(function() return ensure():buyParts() end) end
function M.revertParts() return safely(function() return ensure():revertParts(false) end) end
function M.buyCar() return safely(function() return ensure():buyCar() end) end
function M.revertCar() return safely(function() return ensure():revertCar(false) end) end
function M.restartStage() return safely(function() return ensure():restartStage() end) end
function M.newGame() return safely(function() return ensure():newGame() end) end
function M.startNextStage() return safely(function() return ensure():startNextStage() end) end
function M.startStage(id) return safely(function() return ensure():startStage(id) end) end
function M.enterCarKov() return safely(function() return ensure():enterCarKov() end) end
function M.quitCarKov() return safely(function() return ensure():quitCarKov() end) end
function M.dismissExtraction() return safely(function() return ensure():dismissExtraction() end) end
function M.keepPerk() return safely(function() return ensure():answerPerkOffer(false) end) end
function M.swapPerk() return safely(function() return ensure():answerPerkOffer(true) end) end
function M.installRoadPart() return safely(function() return ensure():answerRoadOffer(true) end) end
function M.declineRoadPart() return safely(function() return ensure():answerRoadOffer(false) end) end
function M.activatePerk() return safely(function() return ensure():activatePerk() end) end
function M.onVehicleSpawned() return safely(function() if active then active:vehicleSpawned() end end) end
function M.reload() return safely(function() ensure():reload() end) end
function M.uiMounted(on) return safely(function() ensure():mount(on == true) end) end
function M.getState() return safely(function() return ensure():view() end) end
function M.onClientStartMission() return M.reload() end
function M.onClientEndMission()
  return safely(function() if active then active:endMission() end end)
end
function M.onFilesChanged(files)
  return safely(function()
    if not active then return end
    for _, f in pairs(type(files) == 'table' and files or {}) do
      if type(f) == 'table' and type(f.filename) == 'string' and f.filename:lower() == config.FILE:lower() then
        active:reload(); return
      end
    end
  end)
end
function M.onExtensionUnloaded() active = nil end -- no implicit save on shutdown

return M
