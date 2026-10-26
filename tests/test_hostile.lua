local T = dofile((arg[0]:match('^(.*)[/\\]') or '.') .. '/testlib.lua')
local F = require('fixtures')
local location = require('beamngEarthEnduro/location')
local hostile = require('beamngEarthEnduro/hostile')
local north = 1 / 111195.0802 -- degrees latitude per metre
T.eq(hostile.REWARD, 5000, 'bounty is $5,000'); T.eq(hostile.STILL_SECONDS, 10, 'stopped for 10 s'); T.eq(hostile.CLAIM_METRES, 10, 'claimed within 10 m')
T.eq(hostile.MODEL, 'roamer', 'the hostile is a Roamer'); T.eq(hostile.CONFIG, 'vehicles/roamer/robber_light.pc', 'the Robber Light config')

-- The distance into the run is between 3 and 10 km.
T.eq(hostile.pickKm(function() return 0 end), 3, 'earliest at 3 km'); T.near(hostile.pickKm(function() return 0.999999 end), 10, 1e-4, 'latest at 10 km')

-- Game side: spawns behind the player, facing the same way, never entering it, and sets it chasing.
do
  local commands, deleted, spawned = {}, {}, nil
  local groundAt = function() return 42 end
  local function point(x, y, z) return { x = x, y = y, z = z } end
  local objects = {
    [7] = { pos = point(1000, 2000, 50), vel = point(20, 0, 0), damage = 0 },
    [8] = { pos = point(1003, 2004, 50), vel = point(0.3, 0.4, 0), damage = 2500, dirVec = point(0, 1, 0) },
  }
  local world = { [7] = true }
  local function car(id)
    return { getID = function() return id end, getPosition = function() return point(1000, 2000, 50) end,
      getDirectionVector = function() return point(0, 2, 0.1) end,
      queueLuaCommand = function(_, command) commands[#commands + 1] = { id = id, command = command } end,
      delete = function() deleted[#deleted + 1] = id; world[id] = nil end }
  end
  local env = {
    player = function() return car(7) end,
    objects = function() return objects end,
    vehicles = function() return { spawnNewVehicle = function(model, options)
      spawned = { model = model, options = options }; world[8] = true; return car(8) end } end,
    objectById = function(id) return world[id] and car(id) or nil end,
    point = point,
    rotation = function(x, y) return { x = x, y = y } end,
    ground = function(x, y, z) return groundAt(x, y, z) end,
  }
  local h = hostile.new(env)
  local config = { model = 'pickup', parts = { engine = 'v8' } }
  local id = h:spawn('pickup', config, 300)
  T.eq(id, 8, 'returns the hostile id'); T.eq(spawned.model, 'pickup', 'spawns the model given')
  T.eq(spawned.options.config.parts.engine, 'v8', 'with the config given'); T.check(spawned.options.config ~= config, 'a copy of it')
  T.eq(spawned.options.autoEnterVehicle, false, 'the player stays in their own car')
  T.near(spawned.options.pos.x, 1000, 1e-9, 'directly ahead'); T.near(spawned.options.pos.y, 2300, 1e-9, '300 m ahead')
  T.near(spawned.options.pos.z, 42.5, 1e-9, 'just above the ground'); T.near(spawned.options.rot.y, -1, 1e-9, 'facing the player')
  T.eq(#commands, 1, 'chase order sent'); T.check(commands[1].command:find('ai.setTargetObjectID%(7%)'), 'chases the player')
  T.check(commands[1].command:find('ai.setMode%("chase"%)'), 'in chase mode')
  local status = h:status(8)
  T.near(status.speed, 0.5, 1e-9, 'reads its speed'); T.eq(status.damage, 2500, 'reads its damage'); T.near(status.distance, 5, 1e-9, 'distance to the player')
  T.near(status.angle, math.deg(math.atan2(3, -4)), 1e-9, 'the player is behind it on its left')
  T.eq(status.grounded, true, 'ground under it')
  groundAt = function() return nil end
  T.eq(h:status(8).grounded, false, 'no ground under it: fallen through')
  groundAt = function() error('changed') end
  T.eq(h:status(8).grounded, nil, 'unknown when the ground cannot be read')
  groundAt = function() return 42 end
  T.check(h:chase(8), 'chase order sent again'); T.eq(#commands, 2, 'second order')
  -- Steered from the mod: the AI is turned off once, and the gearbox only shifts on a change.
  T.check(h:drive(8, { kind = 'drive', gear = -1, throttle = 0.6, steer = 0.5 }), 'drive order sent')
  local sent = commands[#commands].command
  T.check(sent:find('ai.setMode%("disabled"%)'), 'AI off'); T.check(sent:find('shiftToGearIndex%(%-1%)'), 'into reverse')
  T.check(sent:find('input.event%("throttle", 0.60, 2%)'), 'throttle'); T.check(sent:find('input.event%("steering", 0.50, 2%)'), 'steering')
  h:drive(8, { kind = 'drive', gear = -1, throttle = 0.6, steer = -0.2 })
  sent = commands[#commands].command
  T.check(not sent:find('ai.setMode') and not sent:find('shiftToGearIndex'), 'a steering update sends only the inputs')
  h:drive(8, { kind = 'rest' })
  T.check(commands[#commands].command:find('input.event%("brake", 1, 2%)'), 'resting holds the brakes')
  h:drive(8, { kind = 'chase' })
  sent = commands[#commands].command
  T.check(sent:find('shiftToGearIndex%(1%)') and sent:find('ai.setMode%("chase"%)'), 'back into drive for the chase AI')
  T.check(sent:find('input.event%("brake", 0, 2%)'), 'inputs released for the AI')
  -- The EMP on the player's car: stalls it, locks its brakes and shoves it away from the hostile.
  local before = #commands
  T.check(h:emp(8, 'start'), 'EMP sent')
  sent = commands[#commands].command
  T.eq(commands[#commands].id, 7, 'on the player car'); T.eq(#commands, before + 1, 'in one command')
  T.check(sent:find('setIgnitionLevel%(0%)'), 'ignition cut'); T.check(sent:find('input.event%("brake", 1, 1%)'), 'brakes locked')
  T.check(sent:find('toggle_warn_signal'), 'hazards on'); T.check(sent:find('emp.wav', 1, true), 'EMP sound')
  T.check(sent:find('applyVelocity%(vec3%(%-3.0000, %-4.0000, 0.0000%)%)'), 'shoved 5 m/s straight away from the hostile')
  T.check(sent:find('setPlanets%({1003.0000, 2004.0000, 50.0000, 5,'), 'repelled from the hostile')
  T.check(not sent:find('breakDevice'), 'nothing broken for good')
  T.check(h:emp(8, 'shock_over'), 'shove ended'); T.check(commands[#commands].command:find('setPlanets%({}%)'), 'repulsion cleared')
  T.check(h:emp(8, 'over'), 'car given back')
  sent = commands[#commands].command
  T.check(sent:find('input.event%("brake", 0, 1%)'), 'brakes released'); T.check(sent:find('setIgnitionLevel%(s.ignition or 2%)'), 'ignition back on')
  T.eq(select(2, hostile.new({ player = function() return nil end }):emp(8, 'start')), 'vehicle_required', 'EMP needs a player car')
  T.check(h:remove(8), 'removed'); T.eq(deleted[1], 8, 'deleted from the world')
  local _, why = h:status(8)
  T.eq(why, 'vehicle_gone', 'gone once removed'); T.check(h:remove(8), 'removing twice is harmless')
  objects[9] = nil; world[9] = true
  _, why = h:status(9)
  T.eq(why, 'not_ready', 'no reading yet just after a spawn')
  -- Only where there is ground: closer in when there is none at the first distance, none at all refused.
  local tried = {}
  groundAt = function(x, y) tried[#tried + 1] = y - 2000; if y - 2000 <= 200 then return 40 end end
  world[8] = nil
  T.eq(h:spawn('pickup', config, 250, 12), 8, 'spawned closer in'); T.near(spawned.options.pos.y, 2190, 1e-9, '190 m ahead, the first spot with ground')
  T.near(spawned.options.pos.x, 1012, 1e-9, '12 m to the right of the player\'s line')
  T.eq(table.concat(tried, ','), '250,220,190', 'tried 250, 220 then 190 m'); T.near(spawned.options.pos.z, 40.5, 1e-9, 'on that ground')
  world[8] = nil
  h:spawn('pickup', config, 250, -12)
  T.near(spawned.options.pos.x, 988, 1e-9, 'or to the left')
  groundAt = function() return nil end
  spawned = nil
  T.eq(select(2, h:spawn('pickup', config, 150)), 'no_ground', 'no ground anywhere: refused'); T.eq(spawned, nil, 'nothing spawned')
  groundAt = function() return 42 end
  -- Failures are contained.
  T.eq(select(2, hostile.new({ player = function() return nil end }):spawn('pickup', config, 300)), 'vehicle_required', 'needs a player car')
  env.vehicles = function() return {} end
  T.eq(select(2, hostile.new(env):spawn('pickup', config, 300)), 'spawn_unavailable', 'missing spawner reported')
  env.vehicles = function() return { spawnNewVehicle = function() error('boom') end } end
  T.eq(select(2, hostile.new(env):spawn('pickup', config, 300)), 'spawn_failed', 'spawn errors contained')
end

-- The brain, step by step.
do
  local B = hostile.BRAIN
  local function run(brain, reading, seconds)
    local orders = {}
    for _ = 1, math.floor(seconds * 10 + 0.5) do
      local order = hostile.think(brain, reading, 0.1)
      if order then orders[#orders + 1] = order end
    end
    return orders
  end
  -- Far off it is steered straight at the player, turning towards them.
  local brain = {}
  local orders = run(brain, { speed = 15, damage = 0, distance = 300, angle = 20 }, 1)
  T.eq(brain.mode, 'direct', 'far off: straight at the player'); T.eq(orders[1].gear, 1, 'forwards')
  T.near(orders[1].steer, -20 / B.STEER_FULL_DEGREES, 1e-9, 'steers left towards a player on its left')
  T.eq(orders[1].throttle, B.DIRECT_THROTTLE, 'at speed'); T.eq(#orders, 5, 'steering updated every 0.2 s')
  orders = run(brain, { speed = 15, damage = 0, distance = 300, angle = -150 }, 0.2)
  T.eq(orders[#orders].steer, 1, 'full lock right for a player behind on its right'); T.eq(orders[#orders].throttle, B.TURN_THROTTLE, 'slower turning round')
  -- Close in it hands over to the chase AI, and only goes back to straight-line driving well beyond.
  orders = run(brain, { speed = 15, damage = 0, distance = 110, angle = 0 }, 0.1)
  T.eq(brain.mode, 'chase', 'close in: chase AI'); T.eq(orders[1].kind, 'chase', 'chase order')
  T.eq(#run(brain, { speed = 15, damage = 0, distance = 150, angle = 0 }, 1), 0, 'chase AI left alone in the gap')
  run(brain, { speed = 15, damage = 0, distance = 200, angle = 0 }, 0.1)
  T.eq(brain.mode, 'direct', 'back to straight-line driving far off')
  -- Stuck: reverses out with the wheel turned away, up to three tries, then gives up.
  brain = {}
  run(brain, { speed = 0, damage = 0, distance = 60, angle = 30 }, B.STUCK_SECONDS + 0.1)
  T.eq(brain.mode, 'unstick', 'stuck: reverses out'); T.check(not hostile.counts(brain), 'reversing out is not standing still')
  orders = run(brain, { speed = 0, damage = 0, distance = 60, angle = 30 }, 0.2)
  T.eq(orders[#orders].gear, -1, 'in reverse'); T.check(orders[#orders].steer > 0, 'wheel turned away to swing its nose round')
  for try = 2, 3 do
    run(brain, { speed = 0, damage = 0, distance = 60, angle = 30 }, B.UNSTICK_SECONDS + B.STUCK_SECONDS + 0.1)
    T.eq(brain.mode, 'unstick', 'try ' .. try); T.eq(brain.tries, try, 'counted')
  end
  run(brain, { speed = 0, damage = 0, distance = 60, angle = 30 }, B.UNSTICK_SECONDS + B.STUCK_SECONDS + 0.1)
  T.eq(brain.mode, 'beaten', 'gives up after three tries'); T.check(hostile.counts(brain), 'now standing still counts')
  -- Getting free resets the tries.
  brain = {}
  run(brain, { speed = 0, damage = 0, distance = 60 }, B.STUCK_SECONDS + 0.1)
  run(brain, { speed = 6, damage = 0, distance = 60 }, B.UNSTICK_SECONDS + 0.1)
  T.eq(brain.tries, 0, 'free again: tries reset'); T.eq(brain.mode, 'chase', 'and back to the chase')
  -- A hit while ramming, or being pinned against the player, backs it off to ram again.
  brain = {}
  run(brain, { speed = 10, damage = 0, distance = 5, angle = 0 }, 0.5)
  orders = run(brain, { speed = 10, damage = 500, distance = 5, angle = 0 }, 0.1)
  T.eq(brain.mode, 'backoff', 'hit: backs off'); T.eq(orders[1].gear, -1, 'in reverse'); T.eq(orders[1].throttle, B.BACKOFF_THROTTLE, 'hard')
  run(brain, { speed = 3, damage = 500, distance = 15, angle = 0 }, B.BACKOFF_SECONDS + 0.1)
  T.eq(brain.mode, 'chase', 'then goes again'); T.eq(brain.tries, 0, 'backing off is not a try')
  run(brain, { speed = 0, damage = 500, distance = 4, angle = 0 }, B.STUCK_SECONDS + 0.1)
  T.eq(brain.mode, 'backoff', 'pinned against the player: backs off, not stuck')
  -- A crash away from the player is not a hit.
  brain = {}
  run(brain, { speed = 10, damage = 0, distance = 50 }, 0.5); run(brain, { speed = 10, damage = 900, distance = 50 }, 0.1)
  T.eq(brain.mode, 'chase', 'damage far from the player does not back it off')
end

-- The EMP and the robbery, in the brain.
do
  local B, E = hostile.BRAIN, hostile.EMP
  T.eq(E.METRES, 18, 'EMP within 18 m'); T.eq(E.SECONDS, 6, 'stalls the player for 6 s'); T.eq(E.ESCAPE_METRES, 250, 'escapes at 250 m')
  T.eq(hostile.robAmount(10000), 2500, 'takes a quarter'); T.eq(hostile.robAmount(100000), 5000, 'at most $5,000')
  T.eq(hostile.robAmount(3), 0, 'whole dollars'); T.eq(hostile.robAmount(0), 0, 'nothing from nothing'); T.eq(hostile.robAmount(-5), 0, 'or from debt')
  local function run(brain, reading, seconds)
    local orders = {}
    for _ = 1, math.floor(seconds * 10 + 0.5) do
      local order = hostile.think(brain, reading, 0.1)
      if order then orders[#orders + 1] = order end
    end
    return orders
  end
  -- Not before it has rammed the player.
  local brain = {}
  run(brain, { speed = 10, damage = 0, distance = 10, angle = 0 }, 0.5)
  T.check(not hostile.empReady(brain, { distance = 10 }), 'not before a hit')
  run(brain, { speed = 10, damage = 500, distance = 5, angle = 0 }, 0.1)
  T.eq(brain.hits, 1, 'a hit counted'); T.check(not hostile.empReady(brain, { distance = 5 }), 'not while backing off')
  run(brain, { speed = 3, damage = 500, distance = 15, angle = 0 }, B.BACKOFF_SECONDS + 0.1)
  T.check(hostile.empReady(brain, { distance = 15 }), 'ready after ramming, inside 18 m')
  T.check(not hostile.empReady(brain, { distance = 25 }), 'not from further off')
  -- Or after chasing long enough without landing a hit.
  local slow = {}
  run(slow, { speed = 10, damage = 0, distance = 60, angle = 0 }, E.AFTER_SECONDS - 1)
  T.check(not hostile.empReady(slow, { distance = 10 }), 'not yet without a hit')
  run(slow, { speed = 10, damage = 0, distance = 60, angle = 0 }, 1.1)
  T.check(hostile.empReady(slow, { distance = 10 }), 'ready after 30 s of chasing')
  -- Fired: pulls up, then flees, never firing again.
  T.eq(hostile.rob(brain, true).kind, 'rest', 'pulls up'); T.eq(brain.mode, 'rob', 'robbing')
  T.check(not hostile.counts(brain), 'pulled up is not disabled'); T.check(not hostile.empReady(brain, { distance = 5 }), 'only once')
  T.eq(#run(brain, { speed = 0, damage = 500, distance = 5, angle = 0 }, E.ROB_SECONDS - 0.2), 0, 'stays put while robbing')
  local orders = run(brain, { speed = 0, damage = 500, distance = 5, angle = 0 }, 0.3)
  T.eq(brain.mode, 'flee', 'then flees'); T.eq(orders[1].gear, 1, 'forwards')
  T.eq(orders[1].throttle, B.TURN_THROTTLE, 'slowly while turning away from a player ahead')
  orders = run(brain, { speed = 10, damage = 500, distance = 40, angle = 150 }, 0.2)
  T.near(orders[#orders].steer, 30 / B.STEER_FULL_DEGREES * B.STEER_SIGN, 1e-9, 'steers to put the player straight behind')
  T.eq(orders[#orders].throttle, E.FLEE_THROTTLE, 'at speed with the player behind')
  orders = run(brain, { speed = 25, damage = 500, distance = 40, angle = 180 }, 0.2)
  T.eq(orders[#orders].throttle, 0, 'lifts off above 70 km/h so it can be caught'); T.eq(orders[#orders].steer, 0, 'straight on')
  -- Rammed while fleeing it carries on fleeing; pinned, it reverses out and flees again.
  run(brain, { speed = 10, damage = 500, distance = 5, angle = 180 }, 0.1); run(brain, { speed = 10, damage = 1200, distance = 5, angle = 180 }, 0.1)
  T.eq(brain.mode, 'flee', 'a hit does not turn it round')
  run(brain, { speed = 0, damage = 1200, distance = 4, angle = 180 }, B.STUCK_SECONDS + 0.1)
  T.eq(brain.mode, 'unstick', 'stuck fleeing: reverses out')
  run(brain, { speed = 0, damage = 1200, distance = 4, angle = 180 }, B.UNSTICK_SECONDS + 0.1)
  T.eq(brain.mode, 'flee', 'and flees again')
  -- With nothing taken it goes back to ramming.
  local broke = { mode = 'chase' }
  hostile.rob(broke, false)
  run(broke, { speed = 0, damage = 0, distance = 5, angle = 0 }, E.ROB_SECONDS + 0.1)
  T.eq(broke.mode, 'chase', 'nothing taken: back to the chase')
end

-- The run, with a hostile set to come 4 km in.
local function onRun(options)
  local h = F.hostiles()
  local c, io, a, _, _, g = F.controller({ hostiles = h, random = options and options.random })
  c:tick(0.1)
  c:addTestMoney()
  T.check(c:enterCarKov(), 'entered CarKov')
  T.check(c.carkov.hostileAtKm >= 3 and c.carkov.hostileAtKm < 10, 'hostile distance picked on entry')
  T.eq(c.profile.carkov.hostileAtKm, c.carkov.hostileAtKm, 'and saved with the run')
  c.carkov.hostileAtKm = 4
  a.pose = location.copy(c:view().resume); c:tick(0.1)
  T.eq(c:view().arrived, true, 'at the drop')
  return c, a, h, g, io
end
-- Drives straight towards the extraction in 50 m steps at 50 m/s.
local function drive(c, a, metres)
  for _ = 1, math.floor(metres / 50) do
    a.pose = location.destination(a.pose, location.bearing(a.pose, c.carkov.extraction), 50); c:tick(1)
  end
end

-- Inbound, then the spawn behind the player in a copy of their car; a stuck AI pays nothing.
do
  local c, a, h, g = onRun()
  drive(c, a, 3900)
  T.eq(c:view().carkov.hostile, nil, 'no hostile before 4 km'); T.eq(#h.spawns, 0, 'nothing spawned')
  drive(c, a, 150)
  local v = c:view()
  T.eq(v.carkov.hostile.phase, 'inbound', 'HOSTILE INBOUND'); T.eq(v.carkov.hostile.seconds, 5, 'counts down from 5')
  T.eq(#h.spawns, 0, 'warning comes first')
  F.advance(c, 3.05)
  T.eq(c:view().carkov.hostile.seconds, 2, 'counting down')
  F.advance(c, 2.5)
  v = c:view()
  T.eq(#h.spawns, 1, 'hostile spawned'); T.eq(h.spawns[1].ahead, 250, '250 m ahead, inside Earth\'s ground'); T.eq(math.abs(h.spawns[1].side), 12, 'to one side')
  T.eq(h.spawns[1].model, 'roamer', 'a Roamer'); T.eq(h.spawns[1].config, 'vehicles/roamer/robber_light.pc', 'in the Robber Light config')
  T.eq(v.carkov.hostile.phase, 'chasing', 'chasing'); T.eq(v.carkov.hostile.distanceMetres, 250, 'distance shown')
  T.eq(c.hostile.brain.mode, 'direct', '250 m off it drives straight at the player'); T.eq(h.orders[1].kind, 'drive', 'steered from the mod')
  h.alive[h:current()].distance = 100; c:tick(0.1)
  T.eq(c.hostile.brain.mode, 'chase', 'close in it hands over to the chase AI'); T.eq(h.orders[#h.orders].kind, 'chase', 'chase order sent')
  -- Stuck with no damage, beside the player, for longer than 10 s: not disabled, no bounty.
  local id = h:current()
  local balance = c:view().balance
  h.alive[id] = { speed = 0, damage = 50, distance = 5 }
  F.advance(c, 15)
  T.eq(c:view().carkov.hostile.phase, 'chasing', 'a stuck AI is not disabled'); T.eq(c:view().balance, balance, 'and pays nothing')
  -- Rammed: it moves, then stops damaged, but the player is not close enough yet.
  h.alive[id] = { speed = 8, damage = 4000, distance = 40 }; F.advance(c, 2)
  T.eq(c.hostile.brain.mode, 'chase', 'chasing again after backing off')
  h.alive[id].speed = 0.2
  F.advance(c, 4.1)
  T.eq(c.hostile.brain.mode, 'unstick', 'stuck: it tries to reverse out'); T.eq(c.hostile.still, 0, 'trying is not standing still')
  F.advance(c, 2.5)
  T.eq(c.hostile.brain.mode, 'chase', 'then chases again')
  F.advance(c, 4.1)
  T.eq(c.hostile.brain.mode, 'beaten', 'damaged, it gives up after one try'); T.eq(h.orders[#h.orders].kind, 'rest', 'and sits still')
  F.advance(c, 5)
  T.eq(c:view().carkov.hostile.phase, 'chasing', 'not disabled before 10 s still since its last try')
  F.advance(c, 1.2)
  T.eq(c:view().carkov.hostile.phase, 'disabled', 'disabled after 10 s stopped and damaged'); T.eq(c:view().balance, balance, 'not paid until claimed')
  -- Moving again starts the 10 s again.
  h.alive[id].speed = 5; c:tick(0.1); h.alive[id].speed = 0; c:tick(0.1)
  T.eq(c:view().carkov.hostile.phase, 'chasing', 'moving again resets it')
  F.advance(c, 10.2)
  h.alive[id].distance = 9; c:tick(0.1)
  v = c:view()
  T.eq(v.balance, balance + 5000, 'bounty paid within 10 m'); T.eq(v.carkov.hostile, nil, 'hostile gone')
  T.eq(h.removed[1], id, 'removed from the world'); T.eq(v.carkov.flash.title, 'HOSTILE DISABLED', 'HUD says so')
  T.eq(v.unsavedBalance >= 5000, true, 'kept by Save like driving pay')
  -- Once per run.
  drive(c, a, 3000)
  T.eq(#h.spawns, 1, 'only one hostile per run')
  T.check(c:manualSave(), 'saved'); T.eq(c.profile.carkov.hostileDone, true, 'save records the hostile came')
  c:reload(); c:tick(0.1); drive(c, a, 500)
  T.eq(#h.spawns, 1, 'no second hostile after a reload')
end

-- With no hostile config set, the hostile is a copy of the player's car.
do
  local model, config = hostile.MODEL, hostile.CONFIG
  hostile.MODEL, hostile.CONFIG = nil, nil
  local c, a, h, g = onRun()
  drive(c, a, 4050); F.advance(c, 5.1)
  T.eq(h.spawns[1].model, g.model, 'in the player car model'); T.eq(h.spawns[1].config.parts.engine, g.fitted.engine, 'with its parts')
  hostile.MODEL, hostile.CONFIG = model, config
end

-- The run ending removes the hostile.
do
  local c, a, h = onRun()
  drive(c, a, 4050); F.advance(c, 5.1)
  local id = h:current()
  T.check(id ~= nil, 'hostile out')
  c.quitArmed = true
  T.check(c:quitCarKov(), 'quit the run')
  T.eq(h.removed[#h.removed], id, 'hostile removed when the run ends'); T.eq(h:current(), nil, 'none left')
  T.eq(c:view().carkov.hostile, nil, 'HUD clear')
end

-- Leaving the level removes it, and a hostile left far behind is removed too.
do
  local c, a, h = onRun()
  drive(c, a, 4050); F.advance(c, 5.1)
  local id = h:current()
  c:endMission()
  T.eq(h.removed[#h.removed], id, 'removed when the level ends')
  c, a, h = onRun()
  drive(c, a, 4050); F.advance(c, 5.1)
  id = h:current()
  h.alive[id].distance = 3500; c:tick(0.1)
  T.eq(h.removed[#h.removed], id, 'removed when left far behind'); T.eq(c:view().carkov.flash.title, 'HOSTILE LOST', 'HUD says so')
end

-- Never inside the last kilometre before extraction, and a failed spawn just leaves the run alone.
do
  local c, a, h = onRun()
  c.carkov.hostileAtKm = 14.5
  for _ = 1, 400 do
    if location.distance(a.pose, c.carkov.extraction) < 900 then break end
    a.pose = location.destination(a.pose, location.bearing(a.pose, c.carkov.extraction), 50); c:tick(1)
  end
  c.profile.progression.totalDistanceKm = 15; c:tick(0.1); F.advance(c, 6)
  T.eq(#h.spawns, 0, 'no hostile within 1 km of extraction'); T.eq(c.carkov.hostileDone, true, 'and none later')
  c, a, h = onRun()
  h.fails = true
  drive(c, a, 4050); F.advance(c, 6)
  T.eq(c:view().carkov.hostile, nil, 'failed spawn clears the warning'); T.eq(c:view().carkov.active, true, 'run carries on')
end

-- No ground behind the player yet: it waits and tries each second, then gives up.
do
  local c, a, h = onRun()
  h.noGround = true
  drive(c, a, 4050); F.advance(c, 5.1)
  T.eq(#h.spawns, 0, 'nothing spawned without ground'); T.eq(c:view().carkov.hostile.phase, 'inbound', 'still coming')
  F.advance(c, 3)
  h.noGround = false; F.advance(c, 1.1)
  T.eq(#h.spawns, 1, 'spawned once the ground is in')
  c, a, h = onRun()
  h.noGround = true
  drive(c, a, 4050); F.advance(c, 5 + hostile.SPAWN_WAIT_SECONDS + 1.5)
  T.eq(c:view().carkov.hostile, nil, 'gives up after waiting'); T.eq(#h.spawns, 0, 'nothing spawned')
end

-- Fallen through the world: respawned behind the player, twice, then removed.
do
  local c, a, h = onRun()
  drive(c, a, 4050); F.advance(c, 5.1)
  local id = h:current()
  h.alive[id].grounded = false; F.advance(c, 1)
  T.eq(h:current(), id, 'a moment with no ground is not a fall')
  h.alive[id].grounded = true; c:tick(0.1); h.alive[id].grounded = false
  F.advance(c, hostile.FALL_SECONDS + 0.1)
  T.eq(h.removed[#h.removed], id, 'fallen hostile removed'); T.eq(c:view().carkov.hostile.phase, 'inbound', 'and coming again')
  F.advance(c, 1.1)
  T.eq(#h.spawns, 2, 'respawned behind the player'); T.eq(c.hostile.respawns, 1, 'counted')
  for n = 2, 3 do
    id = h:current(); h.alive[id].grounded = false
    F.advance(c, hostile.FALL_SECONDS + 1.3)
  end
  T.eq(#h.spawns, 3, 'only twice'); T.eq(h:current(), nil, 'then removed')
  T.eq(c:view().carkov.hostile, nil, 'HUD clear'); T.eq(c:view().carkov.flash.title, 'HOSTILE LOST', 'HUD says it is gone')
end

-- Up to the EMP: out, rammed the player, then close in.
local function toEmp()
  local c, a, h = onRun()
  drive(c, a, 4050); F.advance(c, 5.1)
  local id = h:current()
  h.alive[id] = { speed = 10, damage = 0, distance = 30, angle = 0, grounded = true }; F.advance(c, 0.5)
  h.alive[id] = { speed = 10, damage = 500, distance = 5, angle = 0, grounded = true }; c:tick(0.1)
  T.eq(c.hostile.brain.mode, 'backoff', 'rammed the player'); T.eq(#h.emps, 0, 'no EMP while backing off')
  h.alive[id] = { speed = 3, damage = 500, distance = 30, angle = 0, grounded = true }; F.advance(c, hostile.BRAIN.BACKOFF_SECONDS + 0.2)
  return c, a, h, id
end

-- The EMP: stalls the player for 6 s, robs them, then the hostile flees and escapes 250 m off.
do
  local c, a, h, id = toEmp()
  local balance = c:view().balance
  T.check(balance > 0, 'money to take')
  h.alive[id].distance = 15; c:tick(0.1)
  local v = c:view()
  local taken = math.floor(math.min(balance * 0.25, 5000))
  T.eq(h.emps[1], 'start', 'EMP fired inside 18 m'); T.eq(v.balance, balance - taken, 'a quarter of the money taken')
  T.eq(v.carkov.hostile.phase, 'emp', 'HUD shows the EMP'); T.eq(v.carkov.hostile.stolen, taken, 'and what was taken')
  T.eq(v.carkov.hostile.empSeconds, 6, 'stalled for 6 s'); T.eq(h.orders[#h.orders].kind, 'rest', 'the hostile pulls up')
  F.advance(c, 0.6)
  T.eq(h.emps[2], 'shock_over', 'the shove ends after 0.5 s')
  F.advance(c, 3.5)
  T.eq(c.hostile.brain.mode, 'flee', 'flees after 4 s'); T.eq(h.orders[#h.orders].kind, 'drive', 'steered away from here')
  T.eq(#h.emps, 2, 'player still stalled')
  -- Paused, the stall waits too.
  c.paused = function() return true end; F.advance(c, 5); c.paused = function() return false end
  T.eq(#h.emps, 2, 'the EMP does not run out while paused')
  F.advance(c, 2)
  T.eq(h.emps[3], 'over', 'the player gets their car back after 6 s'); T.eq(#h.emps, 3, 'once')
  v = c:view()
  T.eq(v.carkov.hostile.phase, 'fleeing', 'HUD shows it fleeing'); T.eq(v.carkov.hostile.escapeMetres, 250, 'and where it escapes')
  h.alive[id].distance = 240; c:tick(0.1)
  T.check(c.hostile ~= nil, 'not escaped at 240 m')
  h.alive[id].distance = 260; c:tick(0.1)
  v = c:view()
  T.eq(h.removed[#h.removed], id, 'removed before it can fall through the world'); T.eq(v.carkov.hostile, nil, 'gone')
  T.eq(v.carkov.flash.title, 'HOSTILE ESCAPED', 'HUD says so'); T.check(v.carkov.flash.text:find(tostring(taken % 1000), 1, true), 'with the amount')
  T.eq(v.balance, balance - taken, 'the money is gone')
end

-- Disabled while fleeing: the bounty and the money back; falling through the world is an escape.
do
  local c, a, h, id = toEmp()
  local balance = c:view().balance
  h.alive[id].distance = 15; c:tick(0.1)
  local taken = balance - c:view().balance
  F.advance(c, 4.2)
  T.eq(c.hostile.brain.mode, 'flee', 'fleeing')
  h.alive[id] = { speed = 0, damage = 4000, distance = 40, angle = 180, grounded = true }
  F.advance(c, hostile.BRAIN.STUCK_SECONDS + hostile.BRAIN.UNSTICK_SECONDS + hostile.BRAIN.STUCK_SECONDS + 0.3)
  T.eq(c.hostile.brain.mode, 'beaten', 'damaged and stuck, it gives up')
  F.advance(c, hostile.STILL_SECONDS + 0.2)
  T.eq(c:view().carkov.hostile.phase, 'disabled', 'disabled'); T.eq(c:view().carkov.hostile.stolen, taken, 'still holding the money')
  h.alive[id].distance = 9; c:tick(0.1)
  local v = c:view()
  T.eq(v.balance, balance - taken + 5000 + taken, 'bounty and money back'); T.check(v.carkov.flash.text:find('got back', 1, true), 'HUD says so')
  c, a, h, id = toEmp()
  h.alive[id].distance = 15; c:tick(0.1)
  F.advance(c, 4.2)
  local spawns = #h.spawns
  h.alive[id].grounded = false; F.advance(c, hostile.FALL_SECONDS + 0.2)
  T.eq(c:view().carkov.flash.title, 'HOSTILE ESCAPED', 'fell through fleeing: escaped'); T.eq(#h.spawns, spawns, 'not respawned')
  T.eq(h.emps[#h.emps], 'over', 'the player is never left stalled')
end

-- Quitting mid-EMP gives the car back; with no money to take it carries on ramming.
do
  local c, a, h, id = toEmp()
  h.alive[id].distance = 15; c:tick(0.1)
  c.quitArmed = true; T.check(c:quitCarKov(), 'quit mid-EMP')
  T.eq(h.emps[#h.emps], 'over', 'car given back when the run ends')
  c, a, h, id = toEmp()
  c.profile.progression.balance = 0
  h.alive[id].distance = 15; c:tick(0.1)
  T.eq(h.emps[1], 'start', 'still fires'); T.eq(c:view().carkov.hostile.stolen, nil, 'nothing taken')
  F.advance(c, 4.2)
  T.check(c.hostile.brain.mode ~= 'flee', 'nothing to run off with: rams again'); T.eq(c:view().carkov.hostile.phase, 'emp', 'player still stalled')
  F.advance(c, 2); T.eq(c:view().carkov.hostile.phase, 'chasing', 'then the chase as before')
  h.alive[id].distance = 5; F.advance(c, 1)
  T.eq(#h.emps, 3, 'only one EMP an encounter')
end

-- No hostile spawner (or off a run), nothing happens.
do
  local c, a = F.controller()
  c:tick(0.1)
  T.eq(c:view().carkov.hostile, nil, 'no hostile on the stage'); T.eq(c:view().carkov.hostileReward, nil, 'not offered without a spawner')
end

T.done('CarKov hostile')
