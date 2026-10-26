local F = {}
function F.copy(value)
  if type(value) ~= 'table' then return value end
  local out = {}
  for k, v in pairs(value) do out[k] = F.copy(v) end
  return out
end
function F.position(lat, lon) return { latitude = lat == nil and 0 or lat, longitude = lon == nil and 0 or lon } end
function F.config() return { base = F.position(), resumeRadiusMetres = 50 } end
function F.save(generation, lat, lon)
  return {
    schemaVersion = 1, generation = generation or 1, profileId = 'default', base = F.position(),
    resume = F.position(lat, lon), progression = { balance = 0, totalDistanceKm = 0 }, vehicle = { model = 'pickup' },
  }
end
function F.io(files)
  local io = { files = files or {}, writes = 0, directories = 0 }
  io.exists = function(path)
    if io.existsFails then error('permission denied') end
    return io.files[path] ~= nil
  end
  io.read = function(path)
    if io.readFails == path then error('unreadable') end
    return F.copy(io.files[path])
  end
  io.mkdir = function() io.directories = io.directories + 1; return not io.mkdirFails end
  io.write = function(path, data)
    io.writes = io.writes + 1
    if io.writeFails then io.files[path] = 'partial JSON'; return false end
    io.files[path] = F.copy(data)
    if io.writeMismatch then io.files[path].generation = 99 end
    if io.writeRounds then io.files[path].resume.latitude = io.files[path].resume.latitude + 1e-9 end
    if io.readbackFails then io.readFails = path end
    if io.writeReturnsNil then return nil end
    return true
  end
  return io
end
function F.adapter(pose)
  local a = { pose = pose or F.position(), valid = true, vehicle = { id = 1, model = 'pickup' } }
  function a:invalidate() end
  function a:sample()
    if not self.valid then return { valid = false, reason = self.reason or 'vehicle_required' } end
    return {
      valid = true, latitude = self.pose.latitude, longitude = self.pose.longitude, vehicle = F.copy(self.vehicle),
    }
  end
  return a
end
-- Stand-in for the garage: damage to report, fitted parts and whether the game accepts a respawn.
function F.garage()
  local g = { damage = 0, vehicleId = 1, model = 'pickup', repairs = 0, accepts = true,
    fitted = { engine = 'pickup_engine_v8', intake = 'pickup_intake_stock' },
    values = { pickup_engine_v8 = 4000, pickup_intake_stock = 100, pickup_turbo = 2400, pickup_intake_race = 800 },
    carValues = { pickup = 20000, burnside = 3500, sport = 40000 }, parked = {} }
  function g:carValue(model) return self.carValues[model], model end
  -- Other cars still in the world, by id: { model, fitted, damage }.
  function g:enter(id)
    local car = self.parked[id]
    if not car then return false, 'vehicle_gone' end
    self.parked[id] = nil
    self.vehicleId, self.model, self.fitted, self.damage = id, car.model, car.fitted, car.damage
    return true
  end
  function g:inspect()
    if self.unreadable then return nil, 'damage_unavailable' end
    return { id = self.vehicleId, damage = self.damage }
  end
  function g:parts()
    if self.partsUnreadable then return nil, 'parts_unavailable' end
    local names = {}
    for _, part in pairs(self.fitted) do names[part] = part end
    return { id = self.vehicleId, model = self.model, config = { model = self.model, parts = F.copy(self.fitted) },
      parts = F.copy(self.fitted), values = F.copy(self.values), names = names,
      value = self.carValues[self.model], name = self.model }
  end
  -- Parts menu stand-in: fits parts for free and respawns, which mends the damage.
  function g:fit(slot, part)
    self.fitted[slot], self.damage = part, 0
  end
  -- Spawn stand-in: records the spawn. A saved config table fits its parts; a starter file path
  -- fits g.starter when set.
  g.spawns = {}
  function g:spawnConfig(model, config)
    if not self.accepts then return false, 'spawn_failed', 'rejected' end
    if type(config) == 'string' and self.spawnedFrom == config then return true, 'already_fitted' end
    self.spawns[#self.spawns + 1] = { model = model, config = F.copy(config) }
    if type(config) == 'table' then
      self.model, self.fitted, self.damage, self.spawnedFrom = model, F.copy(config.parts), 0, nil
    elseif self.starter then
      self.model, self.fitted, self.damage, self.spawnedFrom = model, F.copy(self.starter), 0, config
    end
    return true
  end
  function g:repair(config)
    if not self.accepts then return false, 'repair_failed', 'rejected' end
    self.repairs, self.damage = self.repairs + 1, 0
    if config then self.fitted = F.copy(config.parts) end
    return true
  end
  return g
end
-- Stand-in for the hostile spawner: records spawns, removals and EMP stages; tests set each hostile's reading.
function F.hostiles()
  local h = { spawns = {}, removed = {}, chases = 0, alive = {}, nextId = 100 }
  function h:spawn(model, config, ahead, side)
    if self.fails then return nil, 'spawn_failed', 'rejected' end
    if self.noGround then return nil, 'no_ground' end
    self.nextId = self.nextId + 1
    self.spawns[#self.spawns + 1] = { id = self.nextId, model = model, config = F.copy(config), ahead = ahead, side = side }
    self.alive[self.nextId] = { speed = 15, damage = 0, distance = ahead }
    return self.nextId
  end
  h.orders = {}
  function h:drive(id, order)
    self.orders[#self.orders + 1] = F.copy(order)
    return self.alive[id] ~= nil
  end
  function h:chase(id) self.chases = self.chases + 1; return self.alive[id] ~= nil end
  h.emps = {}
  function h:emp(id, stage)
    self.emps[#self.emps + 1] = stage
    return true
  end
  function h:status(id)
    if not self.alive[id] then return nil, 'vehicle_gone' end
    return F.copy(self.alive[id])
  end
  function h:remove(id)
    self.removed[#self.removed + 1] = id
    self.alive[id] = nil
    return true
  end
  -- The one hostile in the world, or nil.
  function h:current()
    for id, reading in pairs(self.alive) do return id, reading end
  end
  return h
end
-- Stand-in for the puncture maker: counts bursts; tests set whether the car is off road.
function F.punctures()
  local p = { bursts = 0, off = false, checks = 0 }
  function p:burst()
    if self.fails then return false, 'burst_failed', 'rejected' end
    self.bursts = self.bursts + 1
    return true
  end
  function p:offRoad() self.checks = self.checks + 1; return self.off end
  return p
end
-- The first stage's starting money as shipped. Controllers start with $0 unless a test asks for
-- starting money, so the money arithmetic in the tests stays simple.
local firstStage = require('beamngEarthEnduro/stages').list[1]
F.STARTING_MONEY = firstStage.startingMoney
function F.controller(options)
  local Core = require('beamngEarthEnduro/core')
  options = options or {}
  firstStage.startingMoney = options.startingMoney or 0
  local io = options.io or F.io({ ['/settings/beamngEarthEnduro/config.json'] = F.config() })
  local adapter = options.adapter or F.adapter()
  local garage = options.garage or F.garage()
  local events, logs = {}, {}
  local c = Core.new({ io = io, adapter = adapter, garage = garage, paused = options.paused, random = options.random,
    hostiles = options.hostiles, punctures = options.punctures,
    trigger = function(name, view) events[#events + 1] = { name = name, data = F.copy(view) } end,
    log = function(level, tag, message) logs[#logs + 1] = message end })
  return c, io, adapter, events, logs, garage
end
function F.advance(c, seconds)
  for _ = 1, math.ceil(seconds * 10) do c:tick(0.1) end
end
return F
