/* global angular, bngApi */
angular.module('beamng.apps').directive('beamngEarthEnduroHud', [function () {
  return {
    templateUrl: '/ui/modules/apps/BeamNGEarthEnduroHUD/app.html',
    replace: true,
    link: function (scope) {
      'use strict'
      var disposed = false
      var lastMessage = Date.now()
      scope.data = { state: 'EARTH_UNAVAILABLE', stateLabel: 'WAITING FOR THE RALLY', saveAllowed: false }
      var call = function (command) {
        if (typeof bngApi !== 'undefined' && bngApi.engineLua) bngApi.engineLua(command)
      }
      var mount = function (on) {
        call('if beamngEarthEnduro_core then beamngEarthEnduro_core.uiMounted(' + (on ? 'true' : 'false') + ') end')
      }
      // A stage's briefing stays hidden for the rest of the session once the player dismisses it;
      // the next stage's briefing still shows.
      scope.briefingDismissed = null
      scope.dismissBriefing = function (stageName) { scope.briefingDismissed = stageName }
      // Each part of the HUD sits on its own tab so the app stays short.
      scope.tabs = [{ id: 'route', label: 'Route' }, { id: 'stages', label: 'Stages' }, { id: 'garage', label: 'Garage' },
        { id: 'carkov', label: 'CarKov' }, { id: 'tips', label: 'Tips' }]
      scope.tab = 'route'
      scope.setTab = function (id) { scope.tab = id }
      // Marks a tab that has something waiting for the player.
      // On a CarKov run the coordinates to go to sit on the CarKov tab instead of the Route tab.
      var onCarKov = function (d) { return !!d.carkov && !!d.carkov.active }
      // A stage cannot be picked on a CarKov run, so the Stages tab is left out until the run ends.
      scope.tabShown = function (id) { return id !== 'stages' || !onCarKov(scope.data || {}) }
      var alerts = {
        route: function (d) { return !!d.resume && !onCarKov(d) },
        carkov: function (d) { return !!d.resume && onCarKov(d) },
        garage: function (d) { return !!d.partsChange || !!d.carChange || d.repairOwed > 0 || (!!d.puncture && d.puncture.owed) }
      }
      scope.tabAlert = function (id) { return !!alerts[id] && alerts[id](scope.data || {}) }
      // The header names what the player is doing: the CarKov run, the stage, or the mod itself.
      scope.header = function (d) {
        d = d || {}
        if (onCarKov(d)) {
          return { title: 'CarKov Off-Road', color: '#f2994a',
            subtitle: d.carkov.extractionKm != null ? 'Reach extraction \u00b7 ' + d.carkov.extractionKm + ' km' : 'Reach extraction' }
        }
        if (d.stage) {
          return { title: String(d.stage.name), color: null,
            subtitle: d.stage.count > 1 ? 'Earth Enduro \u00b7 Stage ' + d.stage.number + ' of ' + d.stage.count : 'Earth Enduro' }
        }
        return { title: 'Earth Enduro', color: null, subtitle: 'Rally Stages \u00b7 CarKov Off-Road' }
      }
      // Opens a tab when its bill or coordinates first appear; the player can switch away after.
      var autoOpen = [
        ['garage', function (d) { return !!d.carChange }],
        ['garage', function (d) { return !!d.partsChange }], ['carkov', alerts.carkov], ['route', alerts.route]
      ]
      var follow = function (previous, next) {
        for (var i = 0; i < autoOpen.length; i++) {
          if (autoOpen[i][1](next) && !autoOpen[i][1](previous)) { scope.tab = autoOpen[i][0]; return }
        }
        if (scope.tab === 'stages' && onCarKov(next)) scope.tab = 'carkov'
      }
      // The one message under the clock: the most urgent of out of money and can't drive, extraction complete, a
      // hostile inbound or its EMP, a puncture just now, a roadside event just now, how a CarKov run just ended or its hostile was dealt
      // with, the extraction countdown, a hostile on the player's tail, stage complete, a sponsor bonus just paid, a perk just
      // used or lost, a friendly village's offer, a perk on offer, then the status.
      var notices = {
        stuck: { kind: 'stuck', title: 'OUT OF MONEY AND CAN\'T DRIVE?', color: '#eb5757', alert: true },
        done: { kind: 'done', title: '\uD83C\uDFC1 STAGE COMPLETE \uD83C\uDFC1', color: '#f2c94c', alert: false }
      }
      var statusNotice = { kind: 'status', title: '', color: '#a7e5c9', alert: false }
      var sponsorNotice = { kind: 'sponsor', title: '', color: '#f2c94c', alert: false }
      var perkNotice = { kind: 'perk', title: '', color: '#bb86fc', alert: false }
      var offerNotice = { kind: 'offer', title: '', color: '#bb86fc', alert: false }
      var carkovNotice = { kind: 'carkov', title: '', color: '#f2994a', alert: false }
      var extractedNotice = { kind: 'extracted', title: '\uD83D\uDE81 EXTRACTION COMPLETE \uD83D\uDE81', color: '#6fcf97', alert: false }
      var holdNotice = { kind: 'hold', title: '', color: '#6fcf97', alert: false }
      var hostileNotice = { kind: 'hostile', title: '', color: '#eb5757', alert: true }
      var punctureNotice = { kind: 'puncture', title: 'PUNCTURE!', color: '#eb5757', alert: true }
      var roadNotice = { kind: 'road', title: '', color: '#f2994a', alert: false }
      var villageNotice = { kind: 'village', title: 'FRIENDLY VILLAGE', color: '#6fcf97', alert: false }
      scope.notice = function (d) {
        if (!d) return null
        if (d.stuck) return notices.stuck
        if (d.carkov && d.carkov.complete) return extractedNotice
        var threat = d.carkov && d.carkov.hostile
        if (threat && threat.phase === 'inbound') {
          hostileNotice.title = '\u26A0 HOSTILE INBOUND ' + threat.seconds
          return hostileNotice
        }
        if (threat && threat.phase === 'emp') {
          hostileNotice.title = '\u26A1 EMP! ENGINE DEAD ' + threat.empSeconds
          return hostileNotice
        }
        if (d.puncture && d.puncture.flash) return punctureNotice
        if (d.road && d.road.flash) {
          roadNotice.title = d.road.flash.title
          roadNotice.color = d.road.flash.title === 'BANDITS!' ? '#eb5757' : '#6fcf97'
          roadNotice.alert = d.road.flash.title === 'BANDITS!'
          return roadNotice
        }
        if (d.carkov && d.carkov.flash) {
          carkovNotice.title = d.carkov.flash.title
          return carkovNotice
        }
        if (d.carkov && d.carkov.hold) {
          holdNotice.title = 'EXTRACTING... ' + d.carkov.hold.seconds
          return holdNotice
        }
        if (threat) {
          hostileNotice.title = threat.phase === 'disabled' ? 'HOSTILE DISABLED: CLAIM IT'
            : threat.phase === 'fleeing' ? 'ROBBED $' + String(Math.floor(threat.stolen || 0)).replace(/\B(?=(\d{3})+(?!\d))/g, ',') + ': CATCH IT'
            : 'HOSTILE ON YOUR TAIL'
          return hostileNotice
        }
        if (d.stageFinished) return notices.done
        if (d.sponsor && d.sponsor.flash) {
          sponsorNotice.title = '+$' + String(Math.floor(d.sponsor.flash.amount)).replace(/\B(?=(\d{3})+(?!\d))/g, ',') + ' SPONSOR BONUS'
          return sponsorNotice
        }
        if (d.perk && d.perk.flash) {
          perkNotice.title = d.perk.flash.title
          return perkNotice
        }
        if (d.road && d.road.offer) return villageNotice
        if (d.perk && d.perk.offer) {
          offerNotice.title = 'NEW PERK: ' + d.perk.offer.name
          return offerNotice
        }
        if (!d.stateLabel && !d.sessionStatus && !d.saveFeedback) return null
        statusNotice.title = d.stateLabel || ''
        return statusNotice
      }
      // True when there is money, spending or mileage that a Save would keep.
      scope.unsaved = function (d) {
        return !!d && (d.unsavedBalance > 0 || d.unsavedSpending > 0 || d.unsavedDistanceKm >= 0.005)
      }
      scope.save = function () {
        if (scope.data.saveAllowed) call('if beamngEarthEnduro_core then beamngEarthEnduro_core.save() end')
      }
      scope.addTestMoney = function () {
        if (scope.data.testMoneyAllowed) call('if beamngEarthEnduro_core then beamngEarthEnduro_core.addTestMoney() end')
      }
      scope.requestRepairQuote = function () {
        if (scope.data.repairQuoteAllowed) call('if beamngEarthEnduro_core then beamngEarthEnduro_core.requestRepairQuote() end')
      }
      scope.repairVehicle = function () {
        if (scope.data.repairAllowed) call('if beamngEarthEnduro_core then beamngEarthEnduro_core.repairVehicle() end')
      }
      scope.buyParts = function () {
        if (scope.data.buyPartsAllowed) call('if beamngEarthEnduro_core then beamngEarthEnduro_core.buyParts() end')
      }
      scope.buyCar = function () {
        if (scope.data.buyCarAllowed) call('if beamngEarthEnduro_core then beamngEarthEnduro_core.buyCar() end')
      }
      scope.revertCar = function () {
        if (scope.data.revertCarAllowed) call('if beamngEarthEnduro_core then beamngEarthEnduro_core.revertCar() end')
      }
      scope.revertParts = function () {
        if (scope.data.revertPartsAllowed) call('if beamngEarthEnduro_core then beamngEarthEnduro_core.revertParts() end')
      }
      scope.startNextStage = function () {
        if (scope.data.nextStageAllowed) call('if beamngEarthEnduro_core then beamngEarthEnduro_core.startNextStage() end')
      }
      // Any stage can be started from the stage list; only a plain stage id is ever sent to Lua.
      scope.startStage = function (stage) {
        if (!scope.data.stageSelectAllowed || !stage || stage.current || !/^[a-z0-9_]+$/.test(String(stage.id))) return
        call("if beamngEarthEnduro_core then beamngEarthEnduro_core.startStage('" + stage.id + "') end")
      }
      scope.stageButton = function (stage) {
        return scope.data.stageArmed === stage.id ? 'Confirm' : 'Start'
      }
      scope.keepPerk = function () {
        if (scope.data.perk && scope.data.perk.offerAllowed) call('if beamngEarthEnduro_core then beamngEarthEnduro_core.keepPerk() end')
      }
      scope.swapPerk = function () {
        if (scope.data.perk && scope.data.perk.offerAllowed) call('if beamngEarthEnduro_core then beamngEarthEnduro_core.swapPerk() end')
      }
      scope.installRoadPart = function () {
        if (scope.data.road && scope.data.road.installAllowed) call('if beamngEarthEnduro_core then beamngEarthEnduro_core.installRoadPart() end')
      }
      scope.declineRoadPart = function () {
        if (scope.data.road && scope.data.road.declineAllowed) call('if beamngEarthEnduro_core then beamngEarthEnduro_core.declineRoadPart() end')
      }
      scope.activatePerk = function () {
        if (scope.data.perk && scope.data.perk.activateAllowed) call('if beamngEarthEnduro_core then beamngEarthEnduro_core.activatePerk() end')
      }
      scope.enterCarKov = function () {
        if (scope.data.carkov && scope.data.carkov.enterAllowed) call('if beamngEarthEnduro_core then beamngEarthEnduro_core.enterCarKov() end')
      }
      scope.quitCarKov = function () {
        if (scope.data.carkov && scope.data.carkov.quitAllowed) call('if beamngEarthEnduro_core then beamngEarthEnduro_core.quitCarKov() end')
      }
      scope.dismissExtraction = function () {
        if (scope.data.carkov && scope.data.carkov.complete) call('if beamngEarthEnduro_core then beamngEarthEnduro_core.dismissExtraction() end')
      }
      // Distance to the extraction point: km far out, metres once closing in.
      scope.extractionDistance = function (c) {
        if (!c || typeof c.extractionDistanceMetres !== 'number') return ''
        if (c.extractionDistanceMetres < c.closingInMetres) return Math.round(c.extractionDistanceMetres) + ' m'
        return (c.extractionDistanceMetres / 1000).toFixed(1) + ' km'
      }
      scope.closingIn = function (c) {
        return !!c && typeof c.extractionDistanceMetres === 'number' && c.extractionDistanceMetres < c.closingInMetres
      }
      scope.restartStage = function () {
        if (scope.data.restartAllowed) call('if beamngEarthEnduro_core then beamngEarthEnduro_core.restartStage() end')
      }
      // The first press asks Lua to confirm; the second wipes the save.
      scope.newGame = function () {
        if (scope.data.newGameAllowed) call('if beamngEarthEnduro_core then beamngEarthEnduro_core.newGame() end')
      }
      // Stage clock: h:mm:ss of the size of a number of seconds; the sign is shown by the caller.
      scope.clock = function (seconds) {
        if (typeof seconds !== 'number' || !isFinite(seconds)) return '-:--:--'
        var total = Math.floor(Math.abs(seconds))
        var pad = function (n) { return (n < 10 ? '0' : '') + n }
        return Math.floor(total / 3600) + ':' + pad(Math.floor(total / 60) % 60) + ':' + pad(total % 60)
      }
      scope.pace = function (seconds) {
        if (typeof seconds !== 'number' || !isFinite(seconds)) return ''
        return (seconds > 0 ? '+' : (seconds < 0 ? '\u2212' : '')) + Math.abs(seconds) + ' s'
      }
      scope.paceColor = function (seconds) { return seconds > 0 ? '#6fcf97' : (seconds < 0 ? '#eb5757' : '#f2f6f5') }
      // Green with time in hand, amber in the last tenth of the limit, red in overtime.
      scope.timerColor = function (timer) {
        if (!timer) return '#a7e5c9'
        if (timer.remainingSeconds < 0) return '#eb5757'
        if (timer.remainingSeconds < timer.targetSeconds * 0.1) return '#f2c94c'
        return '#a7e5c9'
      }
      scope.timerLabel = function (d) {
        var t = d.timer || {}
        if (d.stageFinished) return t.remainingSeconds < 0 ? 'FINISHED OVER THE LIMIT BY' : 'FINISHED WITH TIME TO SPARE'
        if (t.remainingSeconds < 0) return 'OVERTIME'
        return t.started ? 'TIME LEFT' : 'TIME LIMIT'
      }
      scope.coordinates = function (position) {
        if (!position || typeof position.latitude !== 'number' || typeof position.longitude !== 'number' ||
            !isFinite(position.latitude) || !isFinite(position.longitude) ||
            Math.abs(position.latitude) > 90 || Math.abs(position.longitude) > 180) return ''
        return position.latitude.toFixed(8) + ', ' + position.longitude.toFixed(8)
      }
      scope.copyCoordinates = function (position) {
        var text = scope.coordinates(position)
        if (!text) return
        if (typeof bngApi !== 'undefined' && bngApi.engineLua) {
          bngApi.engineLua('setClipboard("' + text + '")')
        }
      }
      scope.$on('BeamNGEarthEnduroState', function (event, data) {
        if (disposed || !data || typeof data.state !== 'string') return
        lastMessage = Date.now()
        scope.$evalAsync(function () {
          if (disposed) return
          follow(scope.data || {}, data)
          scope.data = data
        })
      })
      mount(true)
      var heartbeat = setInterval(function () {
        if (disposed) return
        mount(true)
        if (Date.now() - lastMessage > 6000) {
          scope.$evalAsync(function () {
            if (disposed) return
            scope.data = {
              state: 'EARTH_UNAVAILABLE', stateLabel: 'WAITING FOR THE RALLY', saveAllowed: false,
              sessionStatus: 'The rally mod is not responding. Check that the mod is enabled, then reload it.'
            }
          })
        }
      }, 3000)
      scope.$on('$destroy', function () {
        disposed = true
        clearInterval(heartbeat)
        mount(false)
      })
    }
  }
}])
