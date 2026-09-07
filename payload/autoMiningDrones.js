"use strict";

// Session-only automation. All mining and inventory operations remain in the
// server's normal drone command and mining-cycle handlers.
function create(api) {
  const modes = new Map();
  let issuing = false;
  const retryMs = 5000;
  const idOf = session => Number(session && (session.characterID || session.charid)) || 0;

  function manual(session) {
    if (!issuing) modes.delete(idOf(session));
  }

  function valid(mode) {
    const context = api.context(mode.session);
    return context && context.scene === mode.scene &&
      Number(context.shipRecord.itemID) === mode.shipID ? context : null;
  }

  function command(session, argument) {
    const args = String(argument || "on").trim().toLowerCase().split(/\s+/);
    const first = args[0] || "on";
    const action = ["focus", "spread"].includes(first) ? "on" : first;
    const targeting = action === "on" ? (first === "on" ? args[1] || "focus" : first) : null;
    if ((first === "on" ? args.length > 2 : args.length > 1) ||
        (action === "on" && !["focus", "spread"].includes(targeting))) {
      return "Usage: /autominingdrones on [focus|spread], /autominingdrones off, /autominingdrones status";
    }
    const characterID = idOf(session);
    if (!characterID) return "Select a character first.";
    if (action === "off") {
      modes.delete(characterID);
      return "AutoMiningDrones off. Current mining orders continue; use Return to Drone Bay to recall drones.";
    }
    if (action === "status") {
      const mode = modes.get(characterID);
      if (!mode || !valid(mode)) {
        modes.delete(characterID);
        return "AutoMiningDrones off.";
      }
      return `AutoMiningDrones on: ${mode.drones.size} enrolled drone(s); ${[...mode.drones.values()].filter(s => s.pending).length} waiting. Targeting: ${mode.targeting}. Search radius: up to 20 km from your ship.`;
    }
    if (action !== "on") return "Usage: /autominingdrones on [focus|spread], /autominingdrones off, /autominingdrones status";
    const context = api.context(session);
    if (!context) return "Undock in your ship and stay out of warp before enabling AutoMiningDrones.";
    const candidates = api.drones(context).filter(drone => api.eligible(drone, context) &&
      (!drone.droneCommand || drone.droneCommand === "MINE"));
    if (!candidates.length) return "Launch idle mining drones first. Combat, assigned, and returning drones are not enrolled.";
    const mode = { session, scene: context.scene, shipID: Number(context.shipRecord.itemID), targeting, focusTargets: new Map(), drones: new Map() };
    // Reapplying on (or changing mode) deliberately replaces existing mining
    // orders. Stop them first so a waiting spread drone cannot keep sharing a rock.
    for (const drone of candidates.sort((a, b) => Number(a.itemID) - Number(b.itemID))) {
      if (drone.droneCommand === "MINE") api.idle(drone, context);
      mode.drones.set(Number(drone.itemID), { pending: true, next: 0 });
    }
    modes.set(characterID, mode);
    safeTick(context.scene, Date.now());
    if (!modes.has(characterID)) return "AutoMiningDrones off. No eligible drones remain or the mining hold is full.";
    return `AutoMiningDrones on for ${candidates.length} launched mining drone(s). Targeting: ${targeting}. No target locks required. Manual drone orders disable automation.`;
  }

  function depleted(scene, drone) {
    for (const mode of modes.values()) {
      if (mode.scene !== scene || mode.shipID !== Number(drone.controllerID)) continue;
      const state = mode.drones.get(Number(drone.itemID));
      if (state) { state.pending = true; state.next = 0; }
    }
  }

  function recall(characterID, mode, context) {
    const ids = [...mode.drones.keys()].filter(id => {
      const drone = api.drone(context, id);
      return drone && Number(drone.controllerID) === mode.shipID;
    });
    modes.delete(characterID);
    api.recall(mode.session, ids);
    api.notify(mode.session, "AutoMiningDrones: mining hold full. Returning enrolled mining drones to bay; automation off.");
  }

  function beforeCycle(scene, drone) {
    for (const [characterID, mode] of modes) {
      if (mode.scene !== scene || !mode.drones.has(Number(drone.itemID))) continue;
      const context = valid(mode);
      if (!context) { modes.delete(characterID); return false; }
      if (api.full(context, drone)) { recall(characterID, mode, context); return true; }
    }
    return false;
  }

  function tick(scene, now) {
    const clock = Number(now) || Date.now();
    for (const [characterID, mode] of modes) {
      // Also discard departed sessions when a previously occupied scene stops ticking.
      const context = valid(mode);
      if (!context) { modes.delete(characterID); continue; }
      if (mode.scene !== scene) continue;
      if (clock < (mode.nextCheck || 0)) continue;
      mode.nextCheck = clock + 1000;
      let targets = null;
      const reserved = new Set();
      const groups = new Map();
      for (const [id, state] of mode.drones) {
        const drone = api.drone(context, id);
        if (!drone || !api.eligible(drone, context) ||
            (!state.pending && drone.droneCommand !== "MINE") ||
            (state.pending && drone.droneCommand && drone.droneCommand !== "MINE")) {
          mode.drones.delete(id); continue;
        }
        const family = api.family(drone);
        if (!groups.has(family)) groups.set(family, []);
        groups.get(family).push(drone);
        if (!state.pending && drone.droneCommand === "MINE") reserved.add(Number(drone.targetID));
      }
      for (const [droneID, state] of mode.drones) {
        const drone = api.drone(context, droneID);
        if (!drone || !api.eligible(drone, context)) {
          mode.drones.delete(droneID); continue;
        }
        if (api.full(context, drone)) { recall(characterID, mode, context); break; }
        if (!state.pending) {
          // Full hold, loss of visibility, and other non-depletion interruptions
          // are not permission to resume a stopped mining order.
          if (drone.droneCommand !== "MINE") mode.drones.delete(droneID);
          continue;
        }
        if (drone.droneCommand && drone.droneCommand !== "MINE") {
          mode.drones.delete(droneID); continue;
        }
        if (clock < state.next) continue;
        state.next = clock + retryMs;
        if (!targets) targets = api.targets(context);
        const family = api.family(drone);
        const candidates = targets.filter(t => api.allowed(drone, t, context) &&
          (mode.targeting === "spread" ? !reserved.has(Number(t.itemID)) :
            groups.get(family).every(peer => api.allowed(peer, t, context))))
          .map(t => ({ target: t, distance: api.distance(drone, t, context) }))
          .filter(t => Number.isFinite(t.distance))
          .sort((a, b) => a.distance - b.distance || Number(a.target.itemID) - Number(b.target.itemID));
        const target = mode.targeting === "focus"
          ? candidates.find(t => Number(t.target.itemID) === mode.focusTargets.get(family)) || candidates[0]
          : candidates[0];
        if (!target) continue;
        if (api.full(context, drone, target.target)) { recall(characterID, mode, context); break; }
        try {
          issuing = true;
          api.mine(mode.session, [droneID], Number(target.target.itemID));
        } finally { issuing = false; }
        if (drone.droneCommand === "MINE" && Number(drone.targetID) === Number(target.target.itemID)) {
          state.pending = false;
          reserved.add(Number(target.target.itemID));
          if (mode.targeting === "focus") mode.focusTargets.set(family, Number(target.target.itemID));
        }
      }
      if (!mode.drones.size) modes.delete(characterID);
    }
  }

  function safeTick(scene, now) {
    try { tick(scene, now); }
    catch (error) {
      // A patch fault must not stop the normal drone tick or repeatedly issue orders.
      modes.clear();
      api.error(error);
    }
  }
  function safeBeforeCycle(scene, drone) {
    try { return beforeCycle(scene, drone); }
    catch (error) { modes.clear(); api.error(error); return false; }
  }
  return { command, manual, depleted, beforeCycle: safeBeforeCycle, tick: safeTick };
}

module.exports = { create };
