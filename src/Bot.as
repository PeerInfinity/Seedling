package
{
	import flash.events.KeyboardEvent;
	import flash.external.ExternalInterface;
	import net.flashpunk.FP;

	/**
	 * Bot — a generic, data-driven INPUT TAPE INTERPRETER compiled into the
	 * game, driving it through synthesized keyboard events and recording
	 * what the player did.
	 *
	 * Part of the Archipelago-CC region-atlas Phase 8 "real-game surface"
	 * arc. Its counterpart is `frontend/modules/seedlingDemo/` over there:
	 * the same tape format is consumed by a JS transcription of the
	 * player physics, and a differential harness replays each tape through
	 * BOTH and compares the observation streams. This side is the ORACLE —
	 * it is the real game — so where the two disagree, this one is right.
	 *
	 * ── Why a data-driven interpreter and not a scripted bot ─────────────
	 * One AS3 edit costs the FULL toolchain: mxmlc, the AP bridge
	 * injection, SWFRecomp's ~165MB C regeneration, and an effectively
	 * cold emcc pass. That is far too slow an iteration loop to put
	 * behaviour in. So this class is deliberately dumb and generic — it
	 * gets compiled in ONCE per ladder rung, and all the iteration happens
	 * in tapes and in the JS engine.
	 *
	 * ── Input synthesis is patch-free ────────────────────────────────────
	 * FlashPunk's `Input` keeps its key state in `private static` vectors
	 * with no public setter, but `Input.enable()` registers its listeners
	 * on `FP.stage` — so dispatching a KeyboardEvent there drives input on
	 * exactly the path hardware uses. (Verified to hold in the RECOMPILED
	 * runtime too, not just Flash Player: its own key delivery ends at the
	 * same `avm2_dispatch_event`.) `Input.onKeyDown` reads only `keyCode`
	 * and `shiftKey`, and its `_key[code]` guard makes a repeated KEY_DOWN
	 * idempotent, so a hold is just "dispatch DOWN once, dispatch UP when
	 * the span ends".
	 *
	 * ── Where this runs, and why that is the only correct place ──────────
	 * `Main.update()`, at the top, BEFORE `super.update()`. That is after
	 * the previous frame's `Input.update()` cleared the edge queues and
	 * before `World.update()` reaches `Player.input()`, so an event
	 * dispatched here is live for exactly one frame and self-clears.
	 *
	 * ── RECORD-THEN-ACT ──────────────────────────────────────────────────
	 * Because the only hook is before the movement, the bot records the
	 * state it can see — the result of the PREVIOUS tick — and only then
	 * dispatches this tick's edges. Observation `t` is therefore the state
	 * after exactly `t` completed movement ticks: index 0 is the boot
	 * position under no input, and an N-tick tape yields N+1 observations.
	 * `tapeRunner.js` mirrors this exactly; getting it off by one makes
	 * every differential red for a reason that is not physics.
	 *
	 * ── Dead frames must not consume tape ────────────────────────────────
	 * `Game.update` skips `super.update()` entirely while `blackCover > 0`
	 * (~20 frames after every room load), and `Mobile.mobileUpdate` skips
	 * the whole friction/input/move block while `Game.freezeObjects`. On
	 * such a frame nothing moves, so advancing the tick counter would
	 * desync the tape from the physics. Both are checked below.
	 */
	public class Bot
	{
		/**
		 * When true, `Player.moveX/moveY` skip their collision probe and
		 * apply every step unconditionally. Default FALSE, so a build with
		 * the flag unset plays exactly like the stock game. Set from the
		 * tape header at `botLoadTape`.
		 *
		 * NOTE the flag is consulted in the PLAYER overrides, not in
		 * `Mobile` — `Player` overrides both movers, so patching the base
		 * class would be a silent no-op for the player.
		 */
		public static var noclip:Boolean = false;

		/**
		 * ── The R0 relaxations (subtractive ladder rung 0) ────────────────
		 * All default FALSE / empty, so a build with no tape loaded plays
		 * exactly like the stock game. Each is read by ONE-LINE guards in
		 * `Player.as`, the `Bot.noclip` pattern.
		 */

		/**
		 * `Player.hit()` returns before sound/shake/knockback/die.
		 *
		 * ⚠ This is NOT "enemies are harmless". `Player.knockback` has only
		 * two callers — inside `hit()` and the sword dash — so guarding
		 * `hit()` is the minimal complete guard for the DAMAGE path. But
		 * seven classes reach around it entirely and write the player's
		 * position or input state directly: LavaTrap (drags and kills),
		 * Whirlpool (displaces, then drowns), Pull (adds force every tick),
		 * IceTurretBlast (freezes), ShieldLock, Pod and BossTotem. Those are
		 * classified as proximity hazards on the JS side and ROUTED AROUND;
		 * no flag here covers them.
		 */
		public static var noDamage:Boolean = false;

		/**
		 * The hazard SET, one flag per dangerous terrain state.
		 *
		 * A set rather than a single boolean because rung 4 re-arms hazards
		 * ONE AT A TIME — a boolean could not express a single R4 rung, and
		 * shipping one would have cost a second full pipeline run to change
		 * its type. The tape names them ("water", "pit", ...); the mapping
		 * to `Tile.types` indices lives in `coerceState` below and in
		 * `tapeFormat.HAZARD_STATES` on the other side.
		 */
		public static var noWater:Boolean = false;      // state 1
		public static var noPit:Boolean = false;        // state 6
		public static var noLava:Boolean = false;       // state 17
		public static var noIce:Boolean = false;        // state 22
		public static var noWaterfall:Boolean = false;  // state 25

		/**
		 * The terrain state the PHYSICS consumes, given what `getState()`
		 * actually resolved.
		 *
		 * ⚠ `Player._state` keeps the RAW value. The change gate
		 * (`_s != _state`), `lastState` and the splash-sound comparison are
		 * therefore byte-identical whether the flags are on or off, and only
		 * the EFFECT sites read through this — the pit branch, onIce /
		 * onWaterfall / inWater / inLava, `moveSpeed` in the setter AND the
		 * second assignment at `Player.as:523`, and `checkDrowning`'s two
		 * tests. Missing that second `moveSpeed` assignment is the way to
		 * write this patch and have it silently not work.
		 *
		 * Stairs (10) and Ghost Step (30) are deliberately NOT here: they
		 * are merely slower, they are already modelled, and flattening them
		 * would erase real physics rather than a hazard.
		 */
		public static function coerceState(s:int):int
		{
			if (noWater && s == 1) return 0;
			if (noPit && s == 6) return 0;
			if (noLava && s == 17) return 0;
			if (noIce && s == 22) return 0;
			if (noWaterfall && s == 25) return 0;
			return s;
		}

		/** Canonical key-name -> keycode table. MUST match tapeFormat.js. */
		private static const KEY_RIGHT:int = 39;
		private static const KEY_UP:int = 38;
		private static const KEY_LEFT:int = 37;
		private static const KEY_DOWN:int = 40;
		private static const KEY_PRIMARY:int = 88;    // Key.X
		private static const KEY_SECONDARY:int = 67;  // Key.C
		private static const KEY_INVENTORY:int = 86;  // Key.V
		private static const KEY_INVENTORY2:int = 73; // Key.I

		private static var registered:Boolean = false;

		// Tape state.
		private static var loaded:Boolean = false;
		private static var armed:Boolean = false;
		private static var finished:Boolean = false;
		private static var errorText:String = "";
		private static var tick:int = 0;
		private static var tickCount:int = 0;
		private static var bootLevel:int = 0;

		// Spans, as parallel arrays (no per-span object churn per frame).
		private static var spanCode:Array = new Array();
		private static var spanFrom:Array = new Array();
		private static var spanTo:Array = new Array();

		// Observation buffer, likewise parallel.
		private static var obsX:Array = new Array();
		private static var obsY:Array = new Array();
		private static var obsLevel:Array = new Array();
		private static var obsBase:int = 0; // tick index of obsX[0] after a drain

		/** Sticky: did the game ever refuse input while we were armed? */
		private static var sawInputRefused:Boolean = false;
		/** Sticky: did we ever skip a frame as a dead/frozen frame? */
		private static var deadFrames:int = 0;

		// The boot block, honored from R0 on (see `botStart`).
		private static var bootX:int = 80;
		private static var bootY:int = 128;

		// Grants: parallel arrays, one row per {level, items}. Rows are
		// consumed on FIRST entry (the level is set to -1), because `health`
		// ADDS to hitsMax and a re-grant on a revisit would inflate it.
		private static var grantLevel:Array = new Array();
		private static var grantItems:Array = new Array();   // Array of Array of String
		/** Sticky report: which grants fired, and at which observation tick. */
		private static var grantsFired:Array = new Array();

		/**
		 * Dialogue auto-advance, counted in DEAD frames.
		 *
		 * ⚠ The key is `primary` (X, 88), NOT V. `NPC.talk()` dismisses on
		 * `Input.released(p.keys[6])`, and `Player.as:59` is
		 * `[RIGHT, UP, LEFT, DOWN, X, C, X, V, I]` — index 6 is the SECOND
		 * `Key.X`, labelled "Talk". V is index 7 and opens the inventory.
		 * Dispatching V here would leave every ceremony undismissed and the
		 * feature would ship silently dead.
		 *
		 * The cadence is fixed and counted in dead frames, so the number of
		 * frozen frames a ceremony takes is a pure function of the tape —
		 * which matters because the recompiled runtime's Math.random() is one
		 * global LFSR stream, and a frozen-frame count that varied run to run
		 * would shift every downstream RNG-derived value.
		 */
		private static const AUTO_ADVANCE_CADENCE:int = 8;
		private static var autoAdvancePhase:int = 0;
		private static var sawAutoAdvance:int = 0;

		private static function keyCodeFor(name:String):int
		{
			switch (name)
			{
				case "right":      return KEY_RIGHT;
				case "up":         return KEY_UP;
				case "left":       return KEY_LEFT;
				case "down":       return KEY_DOWN;
				case "primary":    return KEY_PRIMARY;
				case "secondary":  return KEY_SECONDARY;
				case "inventory":  return KEY_INVENTORY;
				case "inventory2": return KEY_INVENTORY2;
			}
			// M / R / Esc / W are not merely absent from the table: they
			// rebuild the world or open a URL. An unknown name is a loud
			// error on both sides, never a skipped input.
			return -1;
		}

		/**
		 * Register the control surface. Called lazily from `update()` so it
		 * cannot race ExternalInterface availability at boot.
		 *
		 * The page shim auto-wraps every addCallback as
		 * `__swfBridge.game.<name>`, so this needs NO change to
		 * BridgeGeneric, to games/seedling.json, or to the one-configure-
		 * per-instance fence.
		 */
		public static function init():void
		{
			if (registered) return;
			registered = true;
			try
			{
				ExternalInterface.addCallback("botLoadTape", botLoadTape);
				ExternalInterface.addCallback("botStart", botStart);
				ExternalInterface.addCallback("botStatus", botStatus);
				ExternalInterface.addCallback("botDrain", botDrain);
				ExternalInterface.addCallback("botReset", botReset);
			}
			catch (e:Error)
			{
				// No page shim (e.g. a standalone player). The bot is then
				// inert rather than fatal — but say so in the log, because
				// silence here would look identical to a working bot that
				// was never told to do anything.
				trace("Bot: ExternalInterface unavailable — " + e.message);
			}
		}

		/** Parse and install a tape. Returns "ok" or "error:...". */
		public static function botLoadTape(json:String):String
		{
			try
			{
				var t:Object = JSON.parse(json);

				var version:int = int(t.tape_version);
				if (version != 1 && version != 2)
					return "error:tape_version must be 1 or 2, got " + t.tape_version;
				if (t.game != "seedling")
					return "error:game must be seedling, got " + t.game;
				if (!(t.noclip is Boolean))
					return "error:noclip must be a boolean (no default)";
				if (t.boot == null)
					return "error:missing boot";
				if (!(t.inputs is Array))
					return "error:inputs must be an array";

				// ── the version 2 relaxations ─────────────────────────────
				// Version 1 MEANS noDamage false / no hazards / no grants,
				// so a v1 tape that declares any of them is a tape the two
				// consumers would read differently. Same rule as parseTape.
				var relaxDamage:Boolean = false;
				var relaxWater:Boolean = false;
				var relaxPit:Boolean = false;
				var relaxLava:Boolean = false;
				var relaxIce:Boolean = false;
				var relaxWaterfall:Boolean = false;
				var newGrantLevel:Array = new Array();
				var newGrantItems:Array = new Array();
				var j:int;

				if (version == 1)
				{
					if (t.noDamage != null || t.noHazards != null || t.grants != null)
						return "error:tape_version 1 must not declare noDamage, "
							+ "noHazards or grants";
				}
				else
				{
					if (!(t.noDamage is Boolean))
						return "error:noDamage must be a boolean on a version 2 tape";
					if (!(t.noHazards is Array))
						return "error:noHazards must be an ARRAY of hazard names "
							+ "(R4 re-arms hazards one at a time)";
					if (!(t.grants is Array))
						return "error:grants must be an array";
					relaxDamage = t.noDamage;
					var hazards:Array = t.noHazards as Array;
					for (j = 0; j < hazards.length; j++)
					{
						var hz:String = String(hazards[j]);
						if (hz == "water") relaxWater = true;
						else if (hz == "pit") relaxPit = true;
						else if (hz == "lava") relaxLava = true;
						else if (hz == "ice") relaxIce = true;
						else if (hz == "waterfall") relaxWaterfall = true;
						else return "error:noHazards[" + j + "] \"" + hz
							+ "\" is not a hazard name";
					}
					var grants:Array = t.grants as Array;
					for (j = 0; j < grants.length; j++)
					{
						var g:Object = grants[j];
						if (g == null || !(g.items is Array))
							return "error:grants[" + j + "] must be {level, items}";
						var names:Array = g.items as Array;
						for (var k:int = 0; k < names.length; k++)
						{
							if (!knownItem(String(names[k])))
								return "error:grants[" + j + "].items[" + k + "] \""
									+ names[k] + "\" is not an item name";
						}
						newGrantLevel.push(int(g.level));
						newGrantItems.push(names);
					}
				}

				var codes:Array = new Array();
				var froms:Array = new Array();
				var tos:Array = new Array();
				var inputs:Array = t.inputs as Array;
				var maxTo:int = 0;
				for (var i:int = 0; i < inputs.length; i++)
				{
					var span:Object = inputs[i];
					var code:int = keyCodeFor(String(span.key));
					if (code < 0)
						return "error:inputs[" + i + "].key \"" + span.key
							+ "\" is not a known key name";
					var from:int = int(span.from);
					var to:int = int(span.to);
					if (from < 0) return "error:inputs[" + i + "].from < 0";
					if (to <= from)
						return "error:inputs[" + i + "].to must be > from";
					codes.push(code);
					froms.push(from);
					tos.push(to);
					if (to > maxTo) maxTo = to;
				}

				var count:int = (t.tick_count == null) ? maxTo : int(t.tick_count);
				if (count < maxTo)
					return "error:tick_count " + count + " is shorter than the "
						+ "longest span end " + maxTo;

				spanCode = codes;
				spanFrom = froms;
				spanTo = tos;
				tickCount = count;
				bootLevel = int(t.boot.level);
				bootX = int(t.boot.x);
				bootY = int(t.boot.y);
				noclip = t.noclip;
				noDamage = relaxDamage;
				noWater = relaxWater;
				noPit = relaxPit;
				noLava = relaxLava;
				noIce = relaxIce;
				noWaterfall = relaxWaterfall;
				grantLevel = newGrantLevel;
				grantItems = newGrantItems;
				grantsFired = new Array();

				loaded = true;
				armed = false;
				finished = false;
				errorText = "";
				tick = 0;
				sawInputRefused = false;
				deadFrames = 0;
				autoAdvancePhase = 0;
				sawAutoAdvance = 0;
				clearObservations();
				return "ok";
			}
			catch (e:Error)
			{
				return "error:" + e.message;
			}
			// Unreachable — every path above returns. mxmlc's flow analysis
			// does not credit returns inside try/catch, so this satisfies
			// -strict rather than documenting a real case.
			return "error:unreachable";
		}

		/**
		 * Arm the loaded tape. Tick 0 is the next live frame.
		 *
		 * ⚠ THE BOOT BLOCK IS NOW HONORED. Until R0 the spawn was baked into
		 * `Main.as:51` and `Bot.as` parsed `boot.level` into a field it never
		 * read — so a tape declaring anything else was honoured by the JS
		 * engine and ignored here, and the differential blamed physics for
		 * bookkeeping. Re-booting into the tape's own block closes that, and
		 * it is what makes the v2 bounded vacuities reachable: the level-83
		 * stickiness hole and the four arrival-on-a-trigger latch pairs all
		 * need to start somewhere other than level 0.
		 *
		 * `FP.world = new Game(...)` only records a `_goto`; the swap lands
		 * at end-of-tick and the ~19 `blackCover` frames that follow are dead
		 * frames the tick counter already skips. So tick 0 is still the first
		 * frame anything moves, in whichever world the tape asked for.
		 */
		public static function botStart():String
		{
			if (!loaded) return "error:no tape loaded";
			if (armed) return "error:already running";
			if (bootLevel != Main.level || !atBootPosition())
			{
				FP.world = new Game(bootLevel, bootX, bootY);
			}
			armed = true;
			finished = false;
			errorText = "";
			tick = 0;
			sawInputRefused = false;
			deadFrames = 0;
			autoAdvancePhase = 0;
			sawAutoAdvance = 0;
			grantsFired = new Array();
			clearObservations();
			return "ok";
		}

		/**
		 * Is the player already where the tape's boot block asks for?
		 *
		 * `Main.playerPositionX/Y` are SPAWN coordinates — written at every
		 * `Game` construction — which is exactly the comparison wanted here:
		 * "was this world built from these constructor args", not "is the
		 * player standing there now". Skipping a redundant re-boot keeps the
		 * eleven committed v1 fixtures on precisely the frame sequence they
		 * were recorded with.
		 */
		private static function atBootPosition():Boolean
		{
			return Main.playerPositionX == bootX && Main.playerPositionY == bootY;
		}

		/**
		 * Status as JSON. Surfaces `receiveInput == false` rather than
		 * stalling on it: the game silently drops input during cutscenes,
		 * pit falls and boss sequences, and a bot that just sat there would
		 * be indistinguishable from one making slow progress.
		 */
		public static function botStatus():String
		{
			var p:Player = findPlayer();
			var o:Object = {
				loaded: loaded,
				armed: armed,
				finished: finished,
				error: errorText,
				tick: tick,
				tick_count: tickCount,
				buffered: obsX.length,
				dead_frames: deadFrames,
				noclip: noclip,
				receive_input: (p == null) ? true : p.receiveInput,
				saw_input_refused: sawInputRefused,
				level: Main.level,
				x: (p == null) ? 0 : p.x,
				y: (p == null) ? 0 : p.y,
				// ── R0's ACCEPTANCE SIGNAL ────────────────────────────────
				// Read LIVE off the game's own statics. The ladder's terminal
				// assertions — "13 item properties true" at R1, the win at R6
				// — are made from HERE and never from the JS mirror, because
				// a mirror asserting itself is not evidence about the game.
				//
				// ⚠ Thirteen booleans and ONE int: `health` is `hitsMax`,
				// which ADDS over a base of 3.
				items: itemReadout(),
				// Both endings are observable from public statics
				// (`Pickups/Seed.as`): the bloody path sets cutscene[1] and
				// re-boots into level 1, the tree path sets `Game.menu`.
				cutscene: Game.cutscene,
				menu: Game.menu,
				grants: grantsFired,
				saw_auto_advance: sawAutoAdvance
			};
			return JSON.stringify(o);
		}

		/** The 14 item properties, live off `Player`'s statics. */
		private static function itemReadout():Object
		{
			return {
				hasSword: Player.hasSword,
				hasDarkSword: Player.hasDarkSword,
				hasGhostSword: Player.hasGhostSword,
				hasShield: Player.hasShield,
				hasDarkShield: Player.hasDarkShield,
				hasFire: Player.hasFire,
				hasWand: Player.hasWand,
				hasFireWand: Player.hasFireWand,
				canSwim: Player.canSwim,
				hasFeather: Player.hasFeather,
				hasSpear: Player.hasSpear,
				hasDarkSuit: Player.hasDarkSuit,
				hasTorch: Player.hasTorch,
				hitsMax: Player.hitsMax
			};
		}

		/** The tape's item vocabulary — `games/seedling.json`'s flash_names. */
		private static function knownItem(name:String):Boolean
		{
			switch (name)
			{
				case "sword":      case "darksword": case "ghostsword":
				case "shield":     case "darkshield": case "fire":
				case "wand":       case "firewand":  case "conch":
				case "feather":    case "spear":     case "darksuit":
				case "torch":      case "health":
					return true;
			}
			return false;
		}

		/**
		 * Write one item. A fixed name -> setter table, so tapes stay DATA.
		 *
		 * ⚠ `health` is not a flag: it ADDS 1 to `hitsMax` over the AS3
		 * default of 3 (`Player.hitsMaxDef`). Treating it as a boolean is
		 * the one way to get this table wrong and still look right.
		 */
		private static function grantItem(name:String):void
		{
			switch (name)
			{
				case "sword":      Player.hasSword = true; break;
				case "darksword":  Player.hasDarkSword = true; break;
				case "ghostsword": Player.hasGhostSword = true; break;
				case "shield":     Player.hasShield = true; break;
				case "darkshield": Player.hasDarkShield = true; break;
				case "fire":       Player.hasFire = true; break;
				case "wand":       Player.hasWand = true; break;
				case "firewand":   Player.hasFireWand = true; break;
				case "conch":      Player.canSwim = true; break;
				case "feather":    Player.hasFeather = true; break;
				case "spear":      Player.hasSpear = true; break;
				case "darksuit":   Player.hasDarkSuit = true; break;
				case "torch":      Player.hasTorch = true; break;
				case "health":     Player.hitsMax = Player.hitsMax + 1; break;
			}
		}

		/**
		 * Apply any grant naming this level, at observation tick `t`.
		 *
		 * The shared contract: a grant fires on the FIRST OBSERVATION TICK
		 * whose level equals the grant's level. Called immediately after the
		 * observation is recorded, so `t` is that observation's own index —
		 * which is exactly what `levelRun` reports on the other side.
		 *
		 * Grants are PROPERTY WRITES ONLY. `Game.setPersistence` is
		 * deliberately not called: persistence tags are a shared cross-level
		 * namespace the endgame reads (`Scenery/FinalDoor.as:50` reads level
		 * 114's tag 0), a grant on the arrival tick is already too late to
		 * despawn the pickup for that visit anyway, and leaving persistence
		 * alone is what makes "crutch off, real collection on" a clean swap
		 * at R3.
		 */
		private static function applyGrantsFor(lvl:int, t:int):void
		{
			for (var i:int = 0; i < grantLevel.length; i++)
			{
				if (int(grantLevel[i]) != lvl) continue;
				var names:Array = grantItems[i] as Array;
				for (var j:int = 0; j < names.length; j++)
				{
					grantItem(String(names[j]));
				}
				// FIRST entry only — a revisit must not re-grant, or hitsMax
				// would climb one per visit.
				grantLevel[i] = -1;
				grantsFired.push({ t: t, level: lvl, items: names });
			}
		}

		/**
		 * Drain the observation buffer as JSON and clear it.
		 *
		 * ⚠ MUST NEVER RETURN THE EMPTY STRING: the page shim normalizes a
		 * "" result to null (no bridge callback legitimately returns ""),
		 * so an empty drain has to come back as a well-formed envelope with
		 * an empty ticks array.
		 */
		public static function botDrain():String
		{
			var ticks:Array = new Array();
			for (var i:int = 0; i < obsX.length; i++)
			{
				ticks.push({
					t: obsBase + i,
					x: obsX[i],
					y: obsY[i],
					level: obsLevel[i]
				});
			}
			obsBase += obsX.length;
			clearObservations(true);
			// `transitions` is empty at the v1 rung; the field exists now so
			// the format does not churn when v2 starts crossing levels.
			return JSON.stringify({ ticks: ticks, transitions: [] });
		}

		/** Disarm and forget the tape and the buffer. */
		public static function botReset():String
		{
			loaded = false;
			armed = false;
			finished = false;
			errorText = "";
			tick = 0;
			tickCount = 0;
			noclip = false;
			noDamage = false;
			noWater = false;
			noPit = false;
			noLava = false;
			noIce = false;
			noWaterfall = false;
			spanCode = new Array();
			spanFrom = new Array();
			spanTo = new Array();
			grantLevel = new Array();
			grantItems = new Array();
			grantsFired = new Array();
			sawInputRefused = false;
			deadFrames = 0;
			autoAdvancePhase = 0;
			sawAutoAdvance = 0;
			clearObservations();
			return "ok";
		}

		private static function clearObservations(keepBase:Boolean = false):void
		{
			obsX = new Array();
			obsY = new Array();
			obsLevel = new Array();
			if (!keepBase) obsBase = 0;
		}

		private static function findPlayer():Player
		{
			if (FP.world == null) return null;
			return FP.world.classFirst(Player) as Player;
		}

		/**
		 * One armed frame. Call from the top of `Main.update()`, before
		 * `super.update()`.
		 */
		public static function update():void
		{
			init();
			if (!armed) return;

			var game:Game = FP.world as Game;
			if (game == null) return;

			// Dead-frame gate. On these frames nothing moves, so the tape
			// must not advance (see the class comment).
			if (game.blackCover > 0 || Game.freezeObjects)
			{
				deadFrames++;
				autoAdvance();
				return;
			}
			autoAdvancePhase = 0;

			var p:Player = findPlayer();
			if (p == null)
			{
				deadFrames++;
				return;
			}
			if (!p.receiveInput) sawInputRefused = true;

			// RECORD, then act.
			obsX.push(p.x);
			obsY.push(p.y);
			obsLevel.push(Main.level);

			// The grant fires on the observation just recorded, so its `t`
			// is this tick — the same instant the JS side's world swap makes
			// `run.level` the new level. Nothing here moves the player, so
			// the observation stream is unchanged either way; what the two
			// sides have to agree on is WHEN.
			applyGrantsFor(Main.level, tick);

			// Edges for this tick: UP for every span ending here, DOWN for
			// every span starting here. Releases go first so a tape that
			// ends one hold and begins another on the same key at the same
			// tick still produces both edges.
			var i:int;
			for (i = 0; i < spanCode.length; i++)
			{
				if (int(spanTo[i]) == tick) dispatchKey(int(spanCode[i]), false);
			}
			for (i = 0; i < spanCode.length; i++)
			{
				if (int(spanFrom[i]) == tick) dispatchKey(int(spanCode[i]), true);
			}

			if (tick >= tickCount)
			{
				// The final observation has been recorded and every hold
				// released; disarm without consuming another tick.
				armed = false;
				finished = true;
				return;
			}
			tick++;
		}

		/**
		 * Dismiss a dialogue that is holding the game frozen, on a FIXED
		 * dead-frame cadence.
		 *
		 * The problem this exists for: a "special" pickup sets
		 * `Game.freezeObjects = true` and spawns an NPC whose text is
		 * dismissed only by `Input.released` — and `NPC.talk()` runs DURING
		 * frozen frames while the bot's tick counter skips them, so a tape
		 * can never reach the release. A walked-over pickup deadlocks it.
		 *
		 * It has to be IN-GAME and frame-deterministic. Dismissing from the
		 * harness would make the frozen-frame count depend on wall-clock
		 * scheduling, and the recompiled runtime's Math.random() is one
		 * global LFSR stream — so a frozen-frame count that varied run to run
		 * would shift every downstream RNG-derived value and no recording
		 * would reproduce.
		 *
		 * ⚠ THE KEY IS X (88), NOT V. `NPC.talk()` reads
		 * `Input.released(p.keys[6])` and `Player.as:59` is
		 * `[RIGHT, UP, LEFT, DOWN, X, C, X, V, I]` — index 6 is the second
		 * `Key.X`, the one the comment labels "Talk". V is index 7 and opens
		 * the inventory, which would freeze the game rather than unfreeze it.
		 *
		 * R0's routes avoid every ceremony, so this ships DARK. It exists for
		 * R3 (real collection) and as the named safety if a census miss ever
		 * lets one fire — `saw_auto_advance` in `botStatus` is how a run that
		 * needed it says so, rather than quietly succeeding for a reason
		 * nobody asked for.
		 */
		private static function autoAdvance():void
		{
			if (!Game.talking)
			{
				autoAdvancePhase = 0;
				return;
			}
			var phase:int = autoAdvancePhase % AUTO_ADVANCE_CADENCE;
			if (phase == 0)
			{
				dispatchKey(KEY_PRIMARY, true);
			}
			else if (phase == 1)
			{
				dispatchKey(KEY_PRIMARY, false);
				sawAutoAdvance++;
			}
			autoAdvancePhase++;
		}

		private static function dispatchKey(code:int, down:Boolean):void
		{
			if (FP.stage == null) return;
			FP.stage.dispatchEvent(new KeyboardEvent(
				down ? KeyboardEvent.KEY_DOWN : KeyboardEvent.KEY_UP,
				true, false, 0, code));
		}
	}
}
