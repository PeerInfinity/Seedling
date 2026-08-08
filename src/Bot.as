package
{
	import flash.events.KeyboardEvent;
	import flash.external.ExternalInterface;
	import flash.utils.getQualifiedClassName;
	import net.flashpunk.FP;
	import net.flashpunk.graphics.Image;
	import net.flashpunk.graphics.Spritemap;
	import NPCs.Help;
	import Enemies.Enemy;
	import Enemies.ShieldBoss;
	import Scenery.Pod;

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
		/**
		 * ── The R5 DETERMINISM PINS (kickoff §3.6 / §13) ─────────────────
		 *
		 * A different CLASSIFICATION from everything above it. The R0
		 * relaxations are *crutches* — a later rung retires each one. These
		 * two are **PINS**: they select WHICH vanilla-reachable execution the
		 * run gets (the one a steady-60 fps browser gives) and create no
		 * vanilla-unreachable one, so they are kept forever and every
		 * recording made under them is still a real-game run.
		 *
		 * Both default FALSE. That is not tidiness — it is what makes the R0
		 * byte-inertness gate mean anything: all 57 frozen fixtures replay
		 * through the vanilla path on this build, and a pin that had changed
		 * a live tick would show up there rather than in a mystery
		 * divergence later.
		 *
		 * Set from a version-5 tape's `pins` list. The rationale for each is
		 * at its own site — `Music.pinStep` and `Game.stepBlackCover` — and
		 * NOT here, because the site is where somebody reading the mechanism
		 * will be.
		 */
		public static var pinSoundClock:Boolean = false;
		public static var pinDeadFrames:Boolean = false;

		/**
		 * ── The version-7 block: the RNG STATE AS TAPE DATA ───────────────
		 *
		 * `Math.random()` is one global LFSR (see `Rng`), so what it returns
		 * inside a recorded window depends on how many draws the page has
		 * made since it loaded — every `Tile` built, every sound index
		 * rolled, every frame of camera shake, in the title world as much as
		 * this one. A tape that has to say what the Owl's rocks do cannot
		 * inherit that number; it has to DECLARE it, the way it already
		 * declares its boot level and its save arrays.
		 *
		 * `rngSeed` 0 means "inherit the page's stream" — the pre-batch
		 * behaviour, and what every v1..v6 tape normalises to, so those
		 * tapes never reach the reset call at all.
		 */
		public static var rngSeed:Number = 0;
		public static var rngSplit:Boolean = false;

		/**
		 * ── R6 slice 6a: the slash's LIVE dispatch counters ───────────────
		 *
		 * One press is FIVE hit tests (`slashDelayMax` is 0, so `slash()`
		 * dispatches on every tick the animation is up), and five rungs of
		 * the ladder modelled ONE because every arm they reached happened to
		 * be idempotent. The ShieldBoss was the first that was not, and the
		 * miscount could only be seen 13 ticks later as a knockback in a
		 * recording.
		 *
		 * `slashTests` counts the dispatches, `slashHits` the ones that
		 * reached `genericHit`. Instrument only: nothing reads them but
		 * `botStatus`.
		 */
		public static var slashTests:int = 0;
		public static var slashHits:int = 0;

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

		/**
		 * A pin could not do its job. STOPS THE TAPE.
		 *
		 * ⚠ Disarming, not just recording. Neither the differential harness
		 * nor the Windows replay driver reads `botStatus.error`, so an error
		 * that only recorded itself would be invisible — the silent-watcher
		 * family, and here it would be worse than invisible: a pin that
		 * quietly stopped pinning would hand back a recording that LOOKS
		 * frame-exact and is not. Disarming truncates the observation
		 * stream, which every consumer already compares exactly.
		 *
		 * The first fault wins; a later one must not overwrite the cause.
		 */
		public static function pinFault(why:String):void
		{
			if (errorText != "") return;
			errorText = why;
			armed = false;
			finished = true;
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
		 * R2, tape version 3: PERSISTENCE CLEARS.
		 *
		 * Parallel arrays, one row per {level, tag}. Applied by `botStart`
		 * BEFORE the first world is built, because every class that responds
		 * to a cleared flag reads it in its CONSTRUCTOR or in the `check()`
		 * the new world runs on its first frame — apply them after and the
		 * blocker is already there.
		 *
		 * Clears ONLY. There is no way to set a flag true from a tape, which
		 * is deliberate: persistence is a shared, cross-level, endgame
		 * load-bearing namespace (`FinalDoor` reads level 114's tag 0;
		 * `Moonrock` writes level 2's from level 0), and a crutch that could
		 * write either way could forge an ending.
		 *
		 * ⚠ This is the SAME state the game itself reaches: `Lock.turnOff()`
		 * runs `Game.setPersistence(tag, false)` when a lock opens. The
		 * crutch does not invent a state, it skips the puzzle that produces
		 * one — which is why R3 retires it class by class as real item use
		 * lands, rather than having to undo anything.
		 */
		private static var persistLevel:Array = new Array();
		private static var persistTag:Array = new Array();

		/**
		 * R4, tape version 4: EQUIPS — `[{t, slot}]`, one write to
		 * `Main.primary` at observation tick `t`.
		 *
		 * ⚠ WHY THIS IS A DIRECTIVE AND NOT A TAPE SPAN. `Player.useItem`
		 * switches on `Inventory.getItem(Main.primary)`, so pressing X with
		 * `Main.primary` at its default 0 is always a SWORD SLASH — and the
		 * bridge tile at `Player.as:1098` decrements only under `t == "Spear"`.
		 * The game's only in-game way to change the slot is the inventory
		 * screen, and `Inventory.set open` IS `Game.freezeObjects = _open`
		 * with one writer and no per-frame reset: the R4 slice-0 probe opened
		 * it from a tape and the tick counter PINNED two ticks later with
		 * `dead_frames` climbing without bound. Frozen frames are dead frames,
		 * so no span in any tape can ever reach the arrows, the X, or the
		 * closing V. (This is NOT the dialogue phase, where several writers
		 * move the flag within a frame and the tape does keep ticking.)
		 *
		 * So the directive is UI SUPPRESSION, the same classification R1's
		 * `Inventory.help = false` earned and for the same reason: it grants
		 * nothing. The slot must already hold the item, `useItem` still routes
		 * through `Inventory.getItem`, and the game's OWN debug warps write
		 * `Main.primary` (`Player.as:1793`, `:1812`, `:1832`, and two more).
		 * `Main.primary` is SharedObject-backed and slice 0 confirmed the
		 * store is page-local — two fresh pages after a granting run both boot
		 * with every flag false — so the write adds no cross-recording risk.
		 */
		private static var equipTick:Array = new Array();
		private static var equipSlot:Array = new Array();
		/** Sticky report: which equips fired, and at which observation tick. */
		private static var equipsFired:Array = new Array();
		/**
		 * Equips whose slot has not been validated yet, and why the check
		 * cannot be eager.
		 *
		 * `Inventory.items` is filled by `addItemsFromSave`, which runs inside
		 * `inventory.update()` — LATER in the same frame than the grant/equip
		 * site, and only while `canInventory()`. A segment tape inherits its
		 * items through a boot-level grant and its slot through
		 * `equips: [{t: 0, slot: 1}]`, so an eager `slot < itemCount` check
		 * would fail at t=0 BY CONSTRUCTION on every segment. The write
		 * happens on time; the check is drained on the first frame the
		 * inventory is non-empty, and it names the equip's own tick.
		 */
		private static var pendEquipSlot:Array = new Array();
		private static var pendEquipTick:Array = new Array();

		/**
		 * R5 slice 23, tape version 6: THE SAVE-ARRAY BOOT BLOCK.
		 *
		 * ── The wall this exists to remove ───────────────────────────────
		 * `Bot`'s boot block honoured exactly two kinds of state — `grants`
		 * (Inventory item booleans) and `persistence` (levelPersistence
		 * tags) — and `Main.SAVE_FILE.data` holds FIVE more kinds, three of
		 * them ARRAYS that gameplay reads:
		 *
		 *   hasTotemPart[5]  `Wand.update` is gated on
		 *                    `Player.hasAllTotemParts()`, so a window that
		 *                    BOOTS into level 43 finds an inert pickup and
		 *                    the wand ceremony can never start.
		 *   hasKey[5]        `BossLock.update` opens on
		 *                    `Player.hasKey(keyType)`.
		 *   hasSealPart[16]  `FinalDoor.update` opens on
		 *                    `SealController.hasAllSealParts()` — the
		 *                    ending's own gate.
		 *
		 * ⚠ THIS IS A BOOT PRESENTATION, NOT A GRANT. It is applied in
		 * `botStart` BEFORE the first world is built, for the same reason
		 * the persistence clears are: `BossTotemPart.check()` and
		 * `BossKey.check()` REMOVE THEMSELVES when the player already holds
		 * their index, and `check()` runs on a new world's first frame. A
		 * write after the world exists leaves the pickup standing for that
		 * visit — the "already too late to despawn" fact the R0 grants
		 * ruling turned on.
		 *
		 * ⚠ AND `hasSealPart` IS AN **INT** ARRAY WITH IDENTITY SLOTS, not
		 * a per-index boolean. `SealController.getSealPart(index)` writes
		 * `index` into the FIRST slot still holding -1, so the array is an
		 * ordered collection LOG and `hasAllSealParts()` is
		 * `hasSealPart(SEALS - 1) != -1` — the LAST SLOT being filled.
		 * Writing `hasSealPartSet(i, 1)` for "has seal i" would be the wrong
		 * shape in a way that reads correctly: it would set seal-part
		 * IDENTITY 1 into slot i, and `hasAllSealParts` would then be
		 * satisfied by any sixteen writes whatsoever. The tape therefore
		 * declares the collection ORDER and this code fills slots 0..n-1.
		 *
		 * ⚠ A RESET PRECEDES THE APPLY, and it is gated on the tape having
		 * declared something — so a v1..v5 tape takes a byte-identical path
		 * to the one it took before this batch. The reset exists so a v6
		 * tape's state is a pure function of the tape rather than of
		 * whatever ran on the page before it. Windows share a page BY
		 * DESIGN (the director's continuations), so "the caller uses a fresh
		 * page" is not available as an argument here the way it was for
		 * `persistence`.
		 *
		 * ⛔ AND THERE IS NO WAY TO UNSET FROM A TAPE beyond the reset: the
		 * three arrays are ADDITIVE state a real playthrough only ever
		 * accumulates, and the reset is to the FRESH-SAVE value (false,
		 * false, -1), which is exactly what `Main.startSave` writes into an
		 * empty store. Nothing here can reach a state the game cannot.
		 */
		private static var saveTotemParts:Array = new Array();  // Array of int
		private static var saveKeys:Array = new Array();        // Array of int
		private static var saveSealParts:Array = new Array();   // Array of int, IN ORDER

		/** The loaded tape's declared version — see `autoAdvance`'s counter. */
		private static var tapeVersion:int = 0;

		/**
		 * Was a `Help` up on the previous dead frame? (R4, the counter fix.)
		 *
		 * `saw_auto_advance` counted on phase 1 — the RELEASE — and a `Help`
		 * ends its freeze on the PRESS, so phase 1 never ran and the counter
		 * could not see it. Counting a Help's ARRIVAL instead of a phase makes
		 * it one per Help however many presses it takes, which is what the
		 * readout is supposed to mean.
		 */
		private static var helpWasUp:Boolean = false;

		/**
		 * Was ANY freeze up on the previous dead frame? (R5, the unification.)
		 *
		 * R4 left two counting rules coexisting: a dialogue counted on the
		 * RELEASE (phase 1) and a `Help` counted on its ARRIVAL, because a
		 * Help ends its freeze on the press and phase 1 never runs for one.
		 * v5 keeps one rule for both — count a FREEZE ARRIVAL — and this is
		 * its edge memory. Reset on every live frame, like `helpWasUp`, so
		 * two freezes separated by live frames count as two.
		 */
		private static var freezeWasUp:Boolean = false;

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
		/**
		 * A KEY_DOWN `autoAdvance` dispatched and has not released yet.
		 *
		 * ⚠ R3: without this, a freeze dismissed by the PRESS strands the
		 * key down for the rest of the run. The cadence releases on phase 1,
		 * which is balanced for an `NPC` — there the RELEASE is the edge
		 * that ends the freeze, so phase 1 always happens. A `Help` reads
		 * `Input.pressed`, so the freeze ends on phase 0; the next frame is
		 * live, the phase resets, and the KEY_UP is never sent. FlashPunk's
		 * `_key[code]` stays true until one arrives, so X would read as held
		 * from then on — and X is `useItem(Main.primary)`.
		 */
		private static var autoAdvanceHeld:Boolean = false;

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
				// ⚠ ITS OWN CALLBACK, not a field on `botStatus` — see
				// `botMobiles`. Every existing caller polls `botStatus` and
				// is therefore byte-inert past this batch by construction.
				ExternalInterface.addCallback("botMobiles", botMobiles);
				ExternalInterface.addCallback("botRngProbe", botRngProbe);
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

		/**
		 * Does a `save` block declare anything at all?
		 *
		 * The v<6 rejection asks about the ARRAYS and not about the block,
		 * because `parseTape` normalises a v1..v5 tape into carrying an
		 * empty block. A `null` array counts as "declares nothing" so an
		 * author may omit a key they do not use.
		 */
		private static function saveBlockDeclaresAnything(b:Object):Boolean
		{
			if (b == null) return false;
			return arrayHasEntries(b.totem_parts)
				|| arrayHasEntries(b.keys)
				|| arrayHasEntries(b.seal_parts);
		}

		private static function arrayHasEntries(a:Object):Boolean
		{
			var arr:Array = a as Array;
			return arr != null && arr.length > 0;
		}

		/**
		 * Parse one index list out of a v6 `save` block into `into`.
		 *
		 * Returns "" on success or an "error:..." string. `limit` is BOTH
		 * the exclusive upper bound on an index AND the maximum length,
		 * because all three arrays are index sets over their own slot count
		 * and no real save can hold a repeat:
		 *
		 *   - `hasTotemPart` / `hasKey` are per-index booleans, so a repeat
		 *     is a second write of `true`, i.e. a bookkeeping error in the
		 *     derivation rather than a harmless one;
		 *   - `hasSealPart` is an ordered LOG whose writer
		 *     (`SealController.getSealPart`) rejection-samples until it
		 *     draws an index it does not already hold, so a repeat is a
		 *     state the game cannot reach.
		 *
		 * ⚠ A NEGATIVE INDEX IS NOT "none" here. `hasSealPart`'s own
		 * EMPTY value is -1, so accepting -1 as an entry would write "this
		 * slot is empty" into a filled slot and make the array's length
		 * disagree with its content — the same class of error a negative
		 * persistence tag would be.
		 */
		private static function parseSaveIndices(raw:Object, what:String,
			limit:int, into:Array):String
		{
			if (raw == null) return "";
			var arr:Array = raw as Array;
			if (arr == null)
				return "error:" + what + " must be an array of indices";
			if (arr.length > limit)
				return "error:" + what + " has " + arr.length + " entries but only "
					+ limit + " slots exist";
			for (var i:int = 0; i < arr.length; i++)
			{
				var v:int = int(arr[i]);
				if (v < 0 || v >= limit)
					return "error:" + what + "[" + i + "] " + v + " is out of range 0.."
						+ (limit - 1) + " (a negative index is not \"none\" — "
						+ "hasSealPart's own empty value is -1)";
				for (var d:int = 0; d < into.length; d++)
				{
					if (int(into[d]) == v)
						return "error:" + what + "[" + i + "] duplicates index " + v;
				}
				into.push(v);
			}
			return "";
		}

		/** Parse and install a tape. Returns "ok" or "error:...". */
		public static function botLoadTape(json:String):String
		{
			try
			{
				var t:Object = JSON.parse(json);

				var version:int = int(t.tape_version);
				if (version < 1 || version > 7)
					return "error:tape_version must be 1, 2, 3, 4, 5, 6 or 7, got "
						+ t.tape_version;
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
				var newPersistLevel:Array = new Array();
				var newPersistTag:Array = new Array();
				var newEquipTick:Array = new Array();
				var newEquipSlot:Array = new Array();
				var newPinSound:Boolean = false;
				var newPinDeadFrames:Boolean = false;
				var newSaveTotem:Array = new Array();
				var newSaveKeys:Array = new Array();
				var newSaveSeals:Array = new Array();
				var j:int;

				if (version == 1)
				{
					// ⚠ The test is on the VALUE, not on presence, and the two
					// are NOT interchangeable. `parseTape` on the JS side is
					// idempotent by design — every consumer re-validates, so a
					// parsed tape carries the three fields NORMALISED to
					// version 1's own semantics — and the harness sends that
					// parsed object over the wire. A presence check here
					// therefore rejects all eleven committed v1 fixtures,
					// which is exactly what it did on the first build of this
					// batch: two consumers reading the same tape differently,
					// the one failure this format exists to prevent.
					if (t.noDamage != null && t.noDamage != false)
						return "error:tape_version 1 means noDamage: false BY DEFINITION";
					if (t.noHazards != null && (t.noHazards as Array) != null
						&& (t.noHazards as Array).length > 0)
						return "error:tape_version 1 means noHazards: [] BY DEFINITION";
					if (t.grants != null && (t.grants as Array) != null
						&& (t.grants as Array).length > 0)
						return "error:tape_version 1 means grants: [] BY DEFINITION";
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

				// ── the version 3 field: persistence clears ───────────────
				// ⚠ THE CHECK IS ON THE VALUE, NOT ON PRESENCE, for exactly
				// the reason the version-1 arm above spells out: `parseTape`
				// is idempotent and NORMALISES, so a parsed v1 or v2 tape
				// arrives over the wire carrying `persistence: []`. A
				// presence check here would reject every committed fixture —
				// which is precisely what the first build of the R0 batch did
				// with `noDamage`, and the reason that comment exists.
				if (version < 3)
				{
					if (t.persistence != null && (t.persistence as Array) != null
						&& (t.persistence as Array).length > 0)
						return "error:tape_version " + version
							+ " means persistence: [] BY DEFINITION";
				}
				else
				{
					if (!(t.persistence is Array))
						return "error:persistence must be an array on a version 3 tape";
					var clears:Array = t.persistence as Array;
					for (j = 0; j < clears.length; j++)
					{
						var c:Object = clears[j];
						if (c == null)
							return "error:persistence[" + j + "] must be {level, tag, note}";
						var cl:int = int(c.level);
						var ct:int = int(c.tag);
						if (cl < 0 || cl >= Game.levels.length)
							return "error:persistence[" + j + "].level " + cl
								+ " is not a level";
						// ⚠ A NEGATIVE TAG IS NOT "no tag" HERE. Entities use
						// -1 to mean untagged and every persistence reader
						// guards on `tag >= 0`, so a clear for -1 could never
						// despawn anything — it would be a line in the audit
						// list that does nothing, which is worse than absent.
						if (ct < 0 || ct >= Game.tagsPerLevel)
							return "error:persistence[" + j + "].tag " + ct
								+ " is out of range 0.." + (Game.tagsPerLevel - 1);
						for (var d:int = 0; d < newPersistLevel.length; d++)
						{
							if (newPersistLevel[d] == cl && newPersistTag[d] == ct)
								return "error:persistence[" + j + "] duplicates level "
									+ cl + " tag " + ct;
						}
						newPersistLevel.push(cl);
						newPersistTag.push(ct);
					}
				}

				// ── the version 4 field: equips ───────────────────────────
				// ⚠ VALUE-SCOPED, NOT PRESENCE-SCOPED — the third time this
				// comment has had to be written, and the reason is unchanged:
				// `parseTape` is idempotent and NORMALISES, so a parsed v1/v2/
				// v3 tape arrives over the wire carrying `equips: []`. A
				// presence check would reject every committed fixture, which
				// is exactly what the first build of the R0 batch did with
				// `noDamage`.
				if (version < 4)
				{
					if (t.equips != null && (t.equips as Array) != null
						&& (t.equips as Array).length > 0)
						return "error:tape_version " + version
							+ " means equips: [] BY DEFINITION";
				}
				else
				{
					if (!(t.equips is Array))
						return "error:equips must be an array on a version 4 tape";
					var equips:Array = t.equips as Array;
					for (j = 0; j < equips.length; j++)
					{
						var eq:Object = equips[j];
						if (eq == null)
							return "error:equips[" + j + "] must be {t, slot}";
						var et:int = int(eq.t);
						var es:int = int(eq.slot);
						if (et < 0)
							return "error:equips[" + j + "].t must be >= 0";
						// The slot's UPPER bound cannot be checked here — the
						// inventory array does not exist until the first
						// `inventory.update()` of the first world. See
						// `pendEquipSlot`. What IS checkable is that it is not
						// negative: `items[-1]` is `undefined`, `useItem`
						// coerces it to 0, and the press would silently become
						// a sword slash.
						if (es < 0)
							return "error:equips[" + j + "].slot must be >= 0";
						for (var ej:int = 0; ej < newEquipTick.length; ej++)
						{
							if (int(newEquipTick[ej]) == et)
								return "error:equips[" + j + "] duplicates tick " + et;
						}
						newEquipTick.push(et);
						newEquipSlot.push(es);
					}
				}

				// ── the version 5 field: the determinism PINS ─────────────
				// ⚠ VALUE-SCOPED, NOT PRESENCE-SCOPED — the fourth time, and
				// the reason has not changed since the R0 batch: `parseTape`
				// is idempotent and NORMALISES, so a parsed v1..v4 tape
				// arrives over the wire carrying `pins: []`. A presence check
				// would reject every committed fixture.
				//
				// An ARRAY OF NAMES rather than two booleans, the `noHazards`
				// shape, and for the same reason: R5 opened the batch with
				// two pins and the next one that gets ruled in must not cost
				// a second full pipeline run to express.
				if (version < 5)
				{
					if (t.pins != null && (t.pins as Array) != null
						&& (t.pins as Array).length > 0)
						return "error:tape_version " + version
							+ " means pins: [] BY DEFINITION";
				}
				else
				{
					if (!(t.pins is Array))
						return "error:pins must be an array on a version 5 tape";
					var pins:Array = t.pins as Array;
					for (j = 0; j < pins.length; j++)
					{
						var pn:String = String(pins[j]);
						if (pn == "sound")
						{
							if (newPinSound)
								return "error:pins[" + j + "] duplicates \"sound\"";
							newPinSound = true;
						}
						else if (pn == "dead_frames")
						{
							if (newPinDeadFrames)
								return "error:pins[" + j + "] duplicates \"dead_frames\"";
							newPinDeadFrames = true;
						}
						else return "error:pins[" + j + "] \"" + pn
							+ "\" is not a pin name";
					}
				}

				// ── the version 6 field: the SAVE-ARRAY boot block ────────
				// ⚠ VALUE-SCOPED, NOT PRESENCE-SCOPED — the FIFTH time, and
				// the reason is the one the R0 batch learned the hard way:
				// `parseTape` is idempotent and NORMALISES, so a parsed
				// v1..v5 tape arrives over the wire carrying
				// `save: {totem_parts: [], keys: [], seal_parts: []}`. A
				// presence check would reject all 98 committed fixtures.
				//
				// ⚠ AND THE EMPTINESS TEST IS OVER THE THREE ARRAYS rather
				// than over the block, for the same reason: the normalised
				// block is a non-null Object on every tape.
				var saveBlock:Object = t.save;
				if (version < 6)
				{
					if (saveBlock != null && saveBlockDeclaresAnything(saveBlock))
						return "error:tape_version " + version + " means save: "
							+ "{totem_parts: [], keys: [], seal_parts: []} BY "
							+ "DEFINITION — the build had no such field to read, so "
							+ "the game would boot with an empty save while the JS "
							+ "engine honoured the block. Bump tape_version to 6.";
				}
				else
				{
					if (saveBlock == null || (saveBlock is Array)
						|| !(saveBlock is Object))
						return "error:save must be an object {totem_parts, keys, "
							+ "seal_parts} on a tape_version 6 tape";
					var se:String = parseSaveIndices(saveBlock.totem_parts,
						"save.totem_parts", Player.totemParts, newSaveTotem);
					if (se != "") return se;
					se = parseSaveIndices(saveBlock.keys,
						"save.keys", Player.totalKeys, newSaveKeys);
					if (se != "") return se;
					se = parseSaveIndices(saveBlock.seal_parts,
						"save.seal_parts", SealController.SEALS, newSaveSeals);
					if (se != "") return se;
				}

				// ── the version 7 block: the RNG state ────────────────────
				// ⚠ VALUE-SCOPED, NOT PRESENCE-SCOPED — the SIXTH time, and
				// the reason has not moved since the R0 batch: `parseTape` is
				// idempotent and NORMALISES, so a parsed v1..v6 tape arrives
				// over the wire carrying `rng: {seed: 0, split: false}`. A
				// presence check would reject all 108 committed fixtures.
				//
				// ⛓ `seed: 0` IS THE "declares nothing" VALUE and it is not
				// a state: the LFSR never enters 0 (an odd value xors to a
				// nonzero mask, an even one shifts down through odd), so 0 is
				// free to mean "inherit the page's stream" — which is what
				// every tape recorded before this batch did.
				var rngBlock:Object = t.rng;
				var newRngSeed:Number = 0;
				var newRngSplit:Boolean = false;
				if (version < 7)
				{
					if (rngBlock != null
						&& (Number(rngBlock.seed) != 0 || rngBlock.split == true))
						return "error:tape_version " + version + " means rng: "
							+ "{seed: 0, split: false} BY DEFINITION — the build "
							+ "had no such field to read, so the game would run on "
							+ "the page's inherited stream while the JS engine "
							+ "honoured the block. Bump tape_version to 7.";
				}
				else
				{
					if (rngBlock == null || (rngBlock is Array)
						|| !(rngBlock is Object))
						return "error:rng must be an object {seed, split} on a "
							+ "tape_version 7 tape";
					if (!(rngBlock.split is Boolean))
						return "error:rng.split must be a boolean on a "
							+ "tape_version 7 tape";
					newRngSplit = rngBlock.split;
					// ⛔ THE BOUND IS 2^31 - 1 AND THE TRANSPORT IS HALF THE
					// REASON. The n=31 tap is 0x48000000, whose top bit is
					// clear, so the orbit lives entirely in [1, 2^31) — a
					// larger seed is not a state the game can be in. AND
					// `JSON.parse` here coerces an integral Number to int32,
					// so a tape declaring 2147483648 arrives as
					// -2147483648: the negative arm below is that value, not
					// an author's typo, and it says so.
					var seedRaw:Number = Number(rngBlock.seed);
					if (seedRaw < 0)
						return "error:rng.seed arrived as " + seedRaw + " — a "
							+ "negative seed is impossible to declare, so this is "
							+ "JSON.parse's int32 coercion of a value above "
							+ "2147483647. The orbit only reaches 2^31 - 1; "
							+ "declare a seed in 1..2147483647.";
					if (!(seedRaw == seedRaw) || seedRaw != Math.floor(seedRaw)
						|| seedRaw > 2147483647)
						return "error:rng.seed must be an integer in 0..2147483647, "
							+ "got " + rngBlock.seed;
					newRngSeed = seedRaw;
					// ⛔ A DECLARED SEED WITH NO HOOKS IS A REFUSAL, NOT A
					// WARNING. Without the runtime hooks the reset silently
					// does nothing and the tape runs on whatever the page had
					// — a recording that looks like every other one and is
					// about a different stream position. Same for the split:
					// `Rng.cos()` would keep falling through to
					// `Math.random()` and the tape's whole claim would be
					// that the split had no effect.
					if ((newRngSeed != 0 || newRngSplit) && !Rng.available)
						return "error:rng declares seed " + newRngSeed + "/split "
							+ newRngSplit + " but this build has no swfmodern.Rng "
							+ "hooks — the declaration would be silently ignored";
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
				persistLevel = newPersistLevel;
				persistTag = newPersistTag;
				saveTotemParts = newSaveTotem;
				saveKeys = newSaveKeys;
				saveSealParts = newSaveSeals;
				equipTick = newEquipTick;
				equipSlot = newEquipSlot;
				equipsFired = new Array();
				pendEquipSlot = new Array();
				pendEquipTick = new Array();
				pinSoundClock = newPinSound;
				pinDeadFrames = newPinDeadFrames;
				rngSeed = newRngSeed;
				rngSplit = newRngSplit;
				tapeVersion = version;

				loaded = true;
				armed = false;
				finished = false;
				errorText = "";
				tick = 0;
				sawInputRefused = false;
				deadFrames = 0;
				autoAdvancePhase = 0;
				sawAutoAdvance = 0;
				helpWasUp = false;
				freezeWasUp = false;
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
			// ⚠ THE ONE CEREMONY NO TAPE CAN DISMISS.
			//
			// `Inventory.update` sets `firstUse` as soon as `items.length >=
			// 2` (addItemsFromSave adds one entry each for sword/fire/wand/
			// spear), and sets `extended` as soon as canSwim or hasFeather;
			// BOTH setters raise a tutorial that holds `Game.freezeObjects`
			// until a key is pressed. Frozen frames are DEAD frames, so the
			// tape's tick counter skips them and no span in the tape can ever
			// reach the release — and `autoAdvance` cannot help either,
			// because it gates on `Game.talking` and a `Help` is not an NPC.
			// A walk that collects two items therefore deadlocks forever,
			// which is exactly what an R1 segment did: tick stuck at 2,
			// dead_frames climbing, cutscene and menu both false.
			//
			// One boolean gates both ceremonies at their source
			// (`if (!firstUse && _fu && help)`), and the GAME'S OWN debug
			// warps set exactly this line for exactly this reason
			// (Player.as:1875, :1897, :1919, :1941, :1963). It suppresses a
			// UI tutorial and nothing else — no physics, no collision, no
			// damage, no hazard — so it is not a crutch a later rung has to
			// retire; R3's real collection needs it too.
			//
			// Byte-inert for every pre-R1 fixture: none of them grants two
			// weapon-shaped items, and none grants conch or feather.
			Inventory.help = false;
			// ── R2: the persistence clears, BEFORE the world is built ─────
			//
			// Every class that responds to a cleared flag reads it either in
			// its CONSTRUCTOR (`FallRock`, `Watcher`, `Teleporter`) or in the
			// `check()` that `Game.update` runs on a new world's first frame,
			// above the blackCover gate. Applying a clear after the world
			// exists would leave the blocker standing for this visit, which
			// is the same "already too late to despawn" fact the R0 grants
			// ruling turned on.
			//
			// ⚠ The RESET is gated on there being clears at all, so a v1 or
			// v2 tape takes a byte-identical path to the one it took before
			// this batch. It exists so that a v3 tape's state is a pure
			// function of the tape rather than of whatever ran on the page
			// before it: the harness uses a fresh page per tape, but "the
			// feature is correct because the caller is careful" is how order
			// dependence gets in.
			if (persistLevel.length > 0)
			{
				var levelCount:int = Game.levels.length;
				for (var li:int = 0; li < levelCount; li++)
				{
					for (var ti:int = 0; ti < Game.tagsPerLevel; ti++)
					{
						Main.levelPersistenceSet(li, ti, true);
					}
				}
				for (var pi:int = 0; pi < persistLevel.length; pi++)
				{
					Game.setPersistence(persistTag[pi], false, persistLevel[pi]);
				}
			}
			// ── R5 slice 23: the SAVE ARRAYS, also BEFORE the world ───────
			//
			// Same site and same reason as the clears above: `check()` runs
			// on a new world's first frame and `BossTotemPart`/`BossKey`
			// REMOVE THEMSELVES there when the player already holds their
			// index. A write after `new Game(...)` leaves the pickup
			// standing for this visit — which for the wand window is worse
			// than useless, because `Wand.update`'s whole body is gated on
			// `Player.hasAllTotemParts()` and it would run on the wrong
			// side of the arrival.
			//
			// ⚠ THE RESET IS GATED ON THE TAPE DECLARING SOMETHING, so a
			// v1..v5 tape takes a byte-identical path to the one it took
			// before this batch — the R0 byte-inertness gate is what says
			// so, and the gate is the reason the arm is written this way
			// rather than resetting unconditionally.
			//
			// ⚠ AND THE RESET IS TO THE FRESH-SAVE VALUES, which
			// `Main.startSave` writes into an empty store: false, false and
			// **-1** (not 0, and not false — `hasSealPart` is an INT array
			// whose empty slot is -1, and `hasAllSealParts()` tests
			// `!= -1`).
			if (saveTotemParts.length > 0 || saveKeys.length > 0
				|| saveSealParts.length > 0)
			{
				var si:int;
				for (si = 0; si < Player.totemParts; si++)
					Main.hasTotemPartSet(si, false);
				for (si = 0; si < Player.totalKeys; si++)
					Main.hasKeySet(si, false);
				for (si = 0; si < SealController.SEALS; si++)
					Main.hasSealPartSet(si, -1);
				for (si = 0; si < saveTotemParts.length; si++)
					Main.hasTotemPartSet(int(saveTotemParts[si]), true);
				for (si = 0; si < saveKeys.length; si++)
					Main.hasKeySet(int(saveKeys[si]), true);
				// ⛔ THE SEAL WRITE IS POSITIONAL: slot `si` gets the seal
				// IDENTITY the tape declared in position `si`, because
				// `SealController.getSealPart` fills the first -1 slot with
				// the identity it drew. Indexing by identity would set
				// `hasSealPart[identity] = identity` — a different array,
				// which `hasAllSealParts()` would then read as complete
				// only if identity 15 happened to be collected.
				for (si = 0; si < saveSealParts.length; si++)
					Main.hasSealPartSet(si, int(saveSealParts[si]));
			}
			if (bootLevel != Main.level || !atBootPosition())
			{
				FP.world = new Game(bootLevel, bootX, bootY);
			}
			// ── R6 slice 6a: the RNG reset, AFTER the world is built ──────
			//
			// ⛓⛓⛓ THE POSITION OF THIS LINE IS THE WHOLE POINT. `new Game`
			// runs its constructor synchronously right above — three
			// `Math.random()` draws for every Tile it builds, one per Enemy —
			// and the swap itself is deferred to end-of-tick. Resetting BELOW
			// it means the model owes nothing for the world build, and
			// nothing for the page's whole history before it: the stream
			// starts at a number the TAPE declared. Resetting above it would
			// have handed the model a tile census to count instead.
			//
			// ⚠ Both writes are gated on the tape declaring something, so a
			// v1..v6 tape takes a byte-identical path to the one it took
			// before this batch — the same shape as the persistence and save
			// resets above, and for the same reason. `Rng.split` is assigned
			// unconditionally because it is a STATIC that outlives a tape:
			// leaving a previous tape's true behind would be the order
			// dependence the declaration exists to remove. Assigning false
			// is inert.
			//
			// ⛓ The COSMETIC stream is reset to 0 — the BUILD's own boot
			// seed — and not to the tape's. Deliberately not the same
			// number: two generators started at the same state return the
			// same first value, which is exactly the coincidence that would
			// let a MISROUTED draw (a gameplay site accidentally on the
			// cosmetic stream) look correct on the tick that matters.
			Rng.split = rngSplit;
			if (rngSeed != 0) Rng.setState(rngSeed);
			if (rngSplit) Rng.setCosmeticState(0);
			armed = true;
			finished = false;
			errorText = "";
			tick = 0;
			// Per-WINDOW, like `tick` — a director boundary starts the count
			// again, which is what a claim about "this window's presses" is
			// about.
			slashTests = 0;
			slashHits = 0;
			sawInputRefused = false;
			deadFrames = 0;
			autoAdvancePhase = 0;
			autoAdvanceHeld = false;
			sawAutoAdvance = 0;
			helpWasUp = false;
			freezeWasUp = false;
			grantsFired = new Array();
			equipsFired = new Array();
			pendEquipSlot = new Array();
			pendEquipTick = new Array();
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
		/**
		 * Each declared clear, as the GAME now holds it.
		 *
		 * `cleared` is `!Main.levelPersistence(level, tag)` — read back, not
		 * remembered. A readout that echoed `persistLevel`/`persistTag`
		 * would go on saying "applied" if `botStart` never ran, which is the
		 * one failure an audit surface exists to catch.
		 */
		private static function persistenceReadout():Array
		{
			var out:Array = new Array();
			for (var i:int = 0; i < persistLevel.length; i++)
			{
				out.push({
					level: persistLevel[i],
					tag: persistTag[i],
					cleared: !Main.levelPersistence(persistLevel[i], persistTag[i])
				});
			}
			return out;
		}

		/**
		 * EVERY persistence flag the run has turned off, whoever turned it
		 * off — the full audit surface, not the tape's own echo.
		 *
		 * ── Why R3 needs this and no earlier rung did ────────────────────
		 * `persistenceReadout()` above answers "did my declared clears
		 * apply", which is the right question while a clear is the only way
		 * a flag ever goes false. R3 retires that crutch, so the flags now
		 * go false because the PLAYER did something: `Sword.removed()` calls
		 * `Game.setPersistence(tag, false)`, so does every other pickup, and
		 * so does `Lock.turnOff()` when a shield lock finishes its fade. The
		 * ledger claim — "collected for real, not granted" — is exactly the
		 * difference between those two lists.
		 *
		 * ⚠ DERIVED FROM THE ARRAY, NOT FROM A DECLARED LIST, deliberately.
		 * A readout that took (level, tag) pairs from the tape could only
		 * ever confirm what the tape already believed; scanning the whole
		 * array reports flags nobody asked about, which is the only way a
		 * clear reaching further than intended shows up. `Main.begin` fills
		 * the array with `true` on a fresh boot, so on a fresh run this list
		 * is precisely what the run changed — and at R3 that is about a
		 * dozen entries.
		 *
		 * It also needs no tape field and therefore no version bump: the R0
		 * value-vs-presence lesson is that every new tape field is a place
		 * for two consumers to disagree, and this one buys the same evidence
		 * for none of that risk.
		 */
		private static function persistenceClearedAll():Array
		{
			var out:Array = new Array();
			for (var lv:int = 0; lv < Game.levels.length; lv++)
			{
				for (var tg:int = 0; tg < Game.tagsPerLevel; tg++)
				{
					if (!Main.levelPersistence(lv, tg))
					{
						out.push({ level: lv, tag: tg });
					}
				}
			}
			return out;
		}

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
				// R2: the clears this run applied, read back from the GAME's
				// own persistence array rather than echoed from the tape. An
				// audit surface that repeated its input would confirm only
				// that the tape was parsed; this confirms the flag is false
				// where the tape said, in the game's own state.
				persistence: persistenceReadout(),
				// R3: every flag currently off, whoever turned it off. The
				// crutch ledger is the difference between this and the line
				// above — a flag here but not there was cleared by the
				// PLAYER, which is what "collected for real" means.
				persistence_cleared: persistenceClearedAll(),
				saw_auto_advance: sawAutoAdvance,
				// ── R4 ────────────────────────────────────────────────────
				// The equip, two-sidedly. `primary` is read from the game's
				// own `Main.primary` and `inventory_slots` is SCANNED from
				// `Inventory` — never echoed from the tape — so the JS slot
				// mirror (its transcription of `addItemsFromSave`'s order:
				// sword, fire, wand, spear, with the fusion splices) is
				// asserted against the game on every tape. A new tape field
				// is a place for two consumers to disagree, and a slot-order
				// divergence would otherwise surface much later as a
				// mysterious slash-instead-of-thrust.
				primary: Main.primary,
				secondary: Main.secondary,
				inventory_slots: slotsReadout(),
				equips: equipsFired,
				// `Player.drownTimer` is CUMULATIVE and is never reset once a
				// hazard has touched it — the only writes are `= drownTimerMax`
				// on the first contact tick, the decrement, and `drown()`'s own
				// spiral. So a walk that declares lava armed and reports 0 here
				// has, in the GAME's own accounting, never stood on an
				// unprotected hazard tile. That is the positive control the
				// forbidden-floor policy needs; without it "the walk avoided
				// the lava" is only ever a claim about the planner.
				drown_timer: (p == null) ? 0 : p.drownTimer,
				// ── R5, THE FOUR READOUTS ────────────────────────────────
				// All four are READOUTS: they change no gameplay at all, and
				// they exist because of what a check can then be PHRASED
				// from. R4 closed with every kill witnessed only by what it
				// OPENS; these make the game report the fight itself.
				//
				// `hits` is the damage TAKEN (0..hitsMax), `hits_timer` the
				// i-frame countdown after a hit, `frozen_timer` the
				// IceTurretBlast freeze. Together with `drown_timer` above
				// they are the whole of "what has happened to this player" —
				// so a walk claiming a clean crossing has a POSITIVE control
				// for it, and a kill window that took a hit on the way is a
				// named failure instead of an unexplained position drift.
				hits: (p == null) ? 0 : p.hits,
				hits_timer: (p == null) ? 0 : p.hitsTimer,
				frozen_timer: (p == null) ? 0 : p.frozenTicks,
				// `Game.time` IS `Main.time` — a static that survives every
				// world swap (Game.as:490-497), which is exactly why it can
				// be read at a window boundary at all. `timeRate` is 1 for
				// every bot tape (it decays only in the intro cutscene), so
				// this is the live tick count the `Game.worldFrame`-coupled
				// family reads. It turns hazard phase from a DERIVATION with
				// a ±k band into a MEASUREMENT, and lets the director
				// wait-to-align at a safe stance before a crossing.
				//
				// ⚠ It is a readout, not a pin, and the two are independent:
				// with `dead_frames` pinned this number is also predictable,
				// but the readout is what proves that rather than assuming
				// it.
				game_time: Game.time,
				// The pinned mixer's own numbers for the ONE set with a
				// gameplay reader. `len_frames` 0 on a set that has played
				// means `Sfx.length` did not answer — see `Music.pinPlayed`,
				// which faults rather than carrying on.
				sound_pin: pinSoundClock ? Music.pinReadout("Swim") : null,
				pins: { sound: pinSoundClock, dead_frames: pinDeadFrames },
				// ── R5 slice 23: the SAVE ARRAYS, read back from the GAME ─
				// Never echoed from the tape. `save.totem_parts` here is
				// what `Player.hasTotemPart(i)` answers, so a v6 tape's boot
				// presentation is asserted against the game's own state on
				// every replay — the same two-sidedness `inventory_slots`
				// buys for the equip.
				//
				// ⛓ AND `seal_parts` IS THE RAW INT ARRAY, slot by slot,
				// -1 and all. A boolean summary ("has all seals") would be
				// the one shape that cannot show the identity-slot bug this
				// field exists to make visible.
				save: saveReadout(),
				// ── R6 slice 6a ──────────────────────────────────────────
				// The stream's own position, read live off the generator.
				// `seed`/`split` are echoed from the tape and the two STATE
				// fields are not — so a replay asserts that the declared
				// reset actually landed, rather than that the tape was
				// parsed. `-1` means a build without the hooks, which a
				// seeded tape refuses at load rather than reaching here.
				rng: {
					state: Rng.state,
					cosmetic_state: Rng.cosmeticState,
					seed: rngSeed,
					split: rngSplit,
					hooks: Rng.available
				},
				// The credits state, read DIRECTLY. `R6_MENU_WRITERS`
				// eliminates four writers to make `menu === true` a sound
				// witness of the ending; this is the number that witness was
				// standing in for (2 = the credits).
				menu_state: Game.menuStateReadout,
				// One press is FIVE hit tests. `tests` counts the
				// dispatches, `hits` the ones that reached `genericHit` — so
				// a model claiming "the first hit is swallowed" is checked
				// against the count rather than against a knockback 13 ticks
				// downstream.
				slash: { tests: slashTests, hits: slashHits }
			};
			return JSON.stringify(o);
		}

		/**
		 * The three save ARRAYS, live off `Main`'s own accessors.
		 *
		 * ⚠ Read through `Player.hasTotemPart` / `Player.hasKey` rather
		 * than `Main.` where the game's own gates do, so the readout and
		 * the gate cannot disagree about which accessor is authoritative.
		 */
		private static function saveReadout():Object
		{
			var i:int;
			var totem:Array = new Array();
			for (i = 0; i < Player.totemParts; i++) totem.push(Player.hasTotemPart(i));
			var keys:Array = new Array();
			for (i = 0; i < Player.totalKeys; i++) keys.push(Player.hasKey(i));
			var seals:Array = new Array();
			for (i = 0; i < SealController.SEALS; i++) seals.push(Main.hasSealPart(i));
			return {
				totem_parts: totem,
				keys: keys,
				seal_parts: seals,
				has_all_totem_parts: Player.hasAllTotemParts(),
				has_all_seal_parts: SealController.hasAllSealParts()
			};
		}

		/**
		 * ── R5 slice 23: THE MOBILE-STATE READOUT ────────────────────────
		 *
		 * Every live `Mobile` in the world, as RAW FIELDS. Not a summary,
		 * not a derived state name, not "is it dead" — the fields the
		 * classes themselves declare, so a consumer that turns out to need
		 * a different question can ask it without a second pipeline run.
		 *
		 * ⛔ IT IS ITS OWN CALLBACK RATHER THAN A FIELD ON `botStatus`, AND
		 * THAT IS THE WHOLE DESIGN. `botStatus` is polled to detect the end
		 * of a tape, on the same thread as the update/render loop whose
		 * RATIO the dead-frame band rides on (`Game.stepBlackCover`'s
		 * docblock, and R5 slice 0's 319/321/319/321/319). A world walk
		 * plus reflection plus a few KB of JSON on every poll is exactly
		 * the kind of cost that could move that ratio — so it is inert BY
		 * CONSTRUCTION for every caller that does not ask, which is a
		 * stronger guarantee than a flag defaulting to off.
		 *
		 * ⛓ THE SET IS `Mobile`, NOT `Enemy`, and that is deliberate.
		 * `Enemy` is what the wall named, but choosing it would be a GUESS
		 * about which movers a later question is about — and the R5 arc's
		 * two hardest measurements were about an `IceTurretBlast` (a
		 * `Mobile`, not an `Enemy`) and a `PushableBlock` (likewise). The
		 * `Enemy`-only fields ride in a nested object which is `null` for a
		 * row that is not one: a shape that says "not an Enemy" rather than
		 * a sentinel value in a real field.
		 *
		 * ⛓ `getClass` walks the UPDATE LIST, so the array is in UPDATE
		 * ORDER — which `World.addUpdate` PREPENDS to, so it is the reverse
		 * of the loader's order and is exactly the order that decided the
		 * camera contest in `r5Totem.L43_BOSS_WAKE.updateOrder`.
		 *
		 * ⛓ `alpha` IS IN THE ROW BECAUSE `destroy` IS NOT REMOVAL:
		 * `Mobile.death()` fades the graphic over eleven ticks and the body
		 * is counted the whole time. The fade is the only field that can
		 * tell a corpse mid-fade from one that is gone.
		 */
		public static function botMobiles():String
		{
			var out:Array = new Array();
			var pods:Array = new Array();
			if (FP.world != null)
			{
				var v:Vector.<Mobile> = new Vector.<Mobile>();
				FP.world.getClass(Mobile, v);
				for each (var m:Mobile in v)
				{
					out.push(mobileRow(m));
				}
				// ── R6 slice 6a: the PODS ────────────────────────────────
				//
				// Their own list because a `Pod` is NOT a `Mobile` — it is
				// Scenery with no velocity — and the roster above walks
				// exactly that class. Slice 0 recorded the absence as a
				// wanted-not-wall; it is wanted because the Owl's whole
				// phase loop is driven by which pod is open, and a window
				// that cannot see the pods can only infer the phase from the
				// boss's position.
				//
				// `anim` and `frame` rather than `open` alone: `open` is a
				// derived boolean (`"open" || "opened"`) and the 22-update
				// open/close animations are what a tick-exact schedule needs.
				var pv:Vector.<Pod> = new Vector.<Pod>();
				FP.world.getClass(Pod, pv);
				for each (var pd:Pod in pv)
				{
					pods.push({
						x: pd.x, y: pd.y,
						open: pd.open,
						anim: pd.anim,
						frame: pd.frame,
						type: pd.type
					});
				}
			}
			return JSON.stringify({ tick: tick, mobiles: out, pods: pods });
		}

		private static function mobileRow(m:Mobile):Object
		{
			var spr:Spritemap = m.graphic as Spritemap;
			var img:Image = m.graphic as Image;
			var row:Object = {
				// `getQualifiedClassName` is what `Entity`'s own
				// constructor uses, so it is known to work on this runtime.
				cls: getQualifiedClassName(m),
				x: m.x, y: m.y,
				vx: m.v.x, vy: m.v.y,
				// The AS3 COLLISION TYPE, as a string. R5 slice 20 turned on
				// this field moving: an IceTurret's `"Solid"` is the
				// else-arm of `if (currentAnim != "dead")`, so a dead one is
				// not a wall.
				type: m.type,
				destroy: m.destroy,
				f: m.f,
				layer: m.layer,
				visible: m.visible,
				collidable: m.collidable,
				width: m.width, height: m.height,
				origin_x: m.originX, origin_y: m.originY,
				// null rather than a sentinel when the graphic is not one.
				anim: (spr == null) ? null : spr.currentAnim,
				frame: (spr == null) ? null : spr.frame,
				anim_index: (spr == null) ? null : spr.index,
				anim_complete: (spr == null) ? null : spr.complete,
				alpha: (img == null) ? null : img.alpha,
				angle: (img == null) ? null : img.angle,
				// The camera gate, which R5 slice 22 found decides WHERE an
				// IceTurret stands and not only whether it moves.
				on_screen: m.onScreen(),
				enemy: null
			};
			var e:Enemy = m as Enemy;
			if (e != null)
			{
				row.enemy = {
					hits: e.hits, hits_max: e.hitsMax, hits_timer: e.hitsTimer,
					damage: e.damage,
					can_hit: e.canHit, just_knock: e.justKnock,
					can_fall_in_pit: e.canFallInPit, fall_in_pit: e.fallInPit,
					fell: e.fell,
					hit_by_fire: e.hitByFire, hit_by_dark_stuff: e.hitByDarkStuff,
					die_in_water: e.dieInWater, die_in_lava: e.dieInLava,
					active_off_screen: e.activeOffScreen,
					only_hit_by: e.onlyHitBy, max_force: e.maxForce,
					// ── R6 slice 6a ──────────────────────────────────────
					// `null` for every enemy but the one that has the field.
					// The ShieldBoss's arming is a PRIVATE var and slice 5
					// could only check it by its consequence — which is how
					// "the first hit of every entry is swallowed" survived
					// being wrong for a whole slice (the arming press armed
					// him on hit test 1 and made him retaliate on test 2).
					activated: (m is ShieldBoss)
						? (m as ShieldBoss).isActivated : null
				};
			}
			return row;
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

		/**
		 * The inventory's slot array, scanned rather than reconstructed.
		 *
		 * The ids are `Inventory`'s own: 0 sword, 1 fire, 2 wand, 3 spear,
		 * 4 ghostsword, 5 firewand. `Player.useItem` switches on exactly
		 * these, so this is the array `Main.primary` indexes into and the
		 * one the JS mirror has to reproduce.
		 */
		private static function slotsReadout():Array
		{
			var out:Array = new Array();
			var n:int = Inventory.itemCount;
			for (var i:int = 0; i < n; i++)
			{
				out.push(Inventory.getItem(i));
			}
			return out;
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
		 * Apply any equip naming observation tick `t`.
		 *
		 * Called immediately AFTER `applyGrantsFor` on the same observation,
		 * so a tape may grant an item and select it on the same tick — which
		 * is exactly what a segment does at t=0.
		 *
		 * The write itself is one line. Everything around it is the
		 * validation, because `Player.useItem`'s `switch` on an out-of-range
		 * slot falls through to nothing: a wrong slot is a SILENT no-op, the
		 * failure mode a tape format exists to prevent.
		 */
		private static function applyEquipsFor(t:int):void
		{
			for (var i:int = 0; i < equipTick.length; i++)
			{
				if (int(equipTick[i]) != t) continue;
				var slot:int = int(equipSlot[i]);
				Main.primary = slot;
				equipsFired.push({ t: t, slot: slot });
				pendEquipSlot.push(slot);
				pendEquipTick.push(t);
			}
		}

		/**
		 * Drain the deferred slot checks, once the inventory exists.
		 *
		 * ⚠ The FAILURE STOPS THE TAPE rather than only setting `errorText`.
		 * Neither the differential harness nor the Windows replay driver
		 * reads `botStatus.error`, so an error that only recorded itself
		 * would be invisible — and "the run reported a problem nobody read"
		 * is the silent-watcher family. Disarming truncates the observation
		 * stream, which every consumer already compares exactly.
		 */
		private static function drainEquipChecks():void
		{
			if (pendEquipTick.length == 0) return;
			if (Inventory.itemCount <= 0) return;
			for (var i:int = 0; i < pendEquipTick.length; i++)
			{
				var slot:int = int(pendEquipSlot[i]);
				if (slot < Inventory.itemCount) continue;
				errorText = "equip at tick " + pendEquipTick[i] + " selected slot "
					+ slot + " but the inventory holds " + Inventory.itemCount
					+ " item(s); useItem on an out-of-range slot is a silent no-op";
				armed = false;
				finished = true;
				return;
			}
			pendEquipSlot = new Array();
			pendEquipTick = new Array();
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

		/**
		 * Draw N values from a stream at a declared seed — THE ORACLE for
		 * the JS transcription of the generator.
		 *
		 * `{"seed": <uint32>, "count": <n>, "cosmetic": <bool>}` in, a JSON
		 * array of that many `Math.random()`-shaped Numbers out.
		 *
		 * ⛓⛓ THE GAME IS THE ONLY ORACLE. A JS `rng.js` checked against a
		 * hand-copied vector table would be checking the transcription
		 * against itself; this draws the expected stream from the same
		 * generator the game draws from, through the same `Math.random()`
		 * the game calls.
		 *
		 * ⚠ AND IT PUTS THE STATE BACK. Sampling a stream advances it, so a
		 * probe run mid-window would silently move every draw after it. The
		 * write hook is what makes this measurable rather than destructive —
		 * which is the second reason it exists, beyond the reset.
		 */
		public static function botRngProbe(json:String):String
		{
			try
			{
				if (!Rng.available)
					return "error:this build has no swfmodern.Rng hooks";
				var q:Object = JSON.parse(json);
				var count:int = int(q.count);
				if (count < 0 || count > 4096)
					return "error:count must be in 0..4096, got " + q.count;
				var cosmetic:Boolean = (q.cosmetic == true);
				var seed:Number = Number(q.seed);
				if (!(seed == seed) || seed != Math.floor(seed)
					|| seed < 0 || seed > 2147483647)
					return "error:seed must be an integer in 0..2147483647, got "
						+ q.seed + " (a negative here is JSON.parse's int32 "
						+ "coercion of a value above 2147483647)";
				var before:Number = cosmetic ? Rng.cosmeticState : Rng.state;
				if (cosmetic) Rng.setCosmeticState(seed);
				else Rng.setState(seed);
				var draws:Array = new Array();
				var states:Array = new Array();
				for (var i:int = 0; i < count; i++)
				{
					// ⚠ The GAMEPLAY arm calls `Math.random()` itself, not a
					// hook that happens to share the generator: the claim
					// being checked is about the function the game calls.
					draws.push(cosmetic ? Rng.cosDraw() : Math.random());
					states.push(cosmetic ? Rng.cosmeticState : Rng.state);
				}
				if (cosmetic) Rng.setCosmeticState(before);
				else Rng.setState(before);
				return JSON.stringify({
					seed: seed, count: count, cosmetic: cosmetic,
					draws: draws, states: states, restored: before
				});
			}
			catch (e:Error)
			{
				return "error:" + e.message;
			}
			// Unreachable — mxmlc's flow analysis does not credit returns
			// inside try/catch. Same shape as `botLoadTape`.
			return "error:unreachable";
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
			// ⚠ The pinned mixer is forgotten HERE and nowhere else — never
			// from `botStart`. `botStart` is also the CONTINUATION path (the
			// director's window boundaries), and a real mixer does not
			// restart because a window ended: a swim sound that is 12 frames
			// in stays 12 frames in across the boundary. Resetting there
			// would make the pin disagree with the thing it is pinning, and
			// would do it exactly where the player is mid-swim. `botReset` is
			// "forget the tape", which is what a fresh page does anyway.
			pinSoundClock = false;
			pinDeadFrames = false;
			Music.pinReset();
			// ⚠ FORGOTTEN, NOT UNDONE — the `saveTotemParts` rule below,
			// applied to the stream. The declaration is dropped and
			// `Rng.split` goes back off (a static outliving the tape is the
			// order dependence the v7 block exists to remove), but the
			// generator's STATE is left exactly where the tape left it: a
			// reset is a rewind the game itself can never do, and the next
			// tape's own `rng.seed` is what decides where it starts.
			rngSeed = 0;
			rngSplit = false;
			Rng.split = false;
			slashTests = 0;
			slashHits = 0;
			spanCode = new Array();
			spanFrom = new Array();
			spanTo = new Array();
			grantLevel = new Array();
			grantItems = new Array();
			grantsFired = new Array();
			// ⚠ FORGOTTEN, NOT UNDONE. `botReset` means "forget the tape",
			// which is what a fresh page does anyway — it does not roll the
			// save arrays back, exactly as it does not roll the persistence
			// clears or the grants back. The next tape's own boot block is
			// what decides the state, and a v6 tape's reset arm above is
			// what makes that a pure function of the tape.
			saveTotemParts = new Array();
			saveKeys = new Array();
			saveSealParts = new Array();
			sawInputRefused = false;
			deadFrames = 0;
			autoAdvancePhase = 0;
			autoAdvanceHeld = false;
			sawAutoAdvance = 0;
			helpWasUp = false;
			freezeWasUp = false;
			tapeVersion = 0;
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
			// ⚠ ABOVE the armed check, and on EVERY frame including dead and
			// frozen ones. The thing being pinned is a mixer, and a mixer
			// does not stop because the tape is between windows or because
			// the room is fading. Gating this on `armed` would make the swim
			// clock jump at exactly the boundaries the director cuts on.
			if (pinSoundClock) Music.pinStep();
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
			// The first LIVE frame after an auto-advance press. Release
			// before anything else this frame, so the edge lands before
			// `Player.input()` reads `Input.pressed`/`Input.check` and the
			// key cannot be seen as held into the tape's own spans.
			if (autoAdvanceHeld)
			{
				dispatchKey(KEY_PRIMARY, false);
				autoAdvanceHeld = false;
			}
			autoAdvancePhase = 0;
			// A live frame ends whatever freeze there was, so the next Help
			// is a NEW arrival. Without this, two Helps separated by live
			// frames would count as one — the counter's whole job is to be a
			// census guard, and a guard that under-counts is worse than one
			// that is absent.
			helpWasUp = false;
			freezeWasUp = false;

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
			// R4: the slot selection, on the same observation and AFTER the
			// grants, so a segment can inherit `spear` and select it at t=0.
			applyEquipsFor(tick);
			drainEquipChecks();
			if (!armed) return;

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
				// ⚠ An equip whose check never drained is a FAILURE, not a
				// pass. `drainEquipChecks` no-ops while the inventory is
				// empty, so a tape that equipped a slot in a run that never
				// built an inventory at all would otherwise finish green
				// having validated nothing — a check that cannot fail is
				// indistinguishable from one that is absent.
				if (pendEquipTick.length > 0)
				{
					errorText = "equip at tick " + pendEquipTick[0] + " was never "
						+ "validated: the inventory was empty for the whole tape, so "
						+ "the slot cannot have held anything and every press was a "
						+ "silent no-op";
				}
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
		 * R0's routes avoid every ceremony, so this shipped DARK.
		 *
		 * ── R3 MEASURED WHAT IT IS ACTUALLY FOR, and it is not dialogue ──
		 *
		 * The R3 ceremony probe walked onto a real pickup and found that the
		 * bot KEEPS TICKING through the dialogue phase: `Game.freezeObjects`
		 * is a sticky static with several writers and no per-frame reset, so
		 * it is TRUE when `Mobile.mobileUpdate` reads it and FALSE again by
		 * the time the next frame's dead-frame gate does. The player cannot
		 * move, but the tape advances — and `NPC.talk()` runs in the NPC's
		 * own update, OUTSIDE the frozen block. So **the tape dismisses its
		 * own dialogues**, with a `primary` span like any other input, and
		 * that is where the behaviour belongs (tapes and JS, never AS3).
		 *
		 * What no tape can EVER reach is a `Help`. `Sword.removed()` adds
		 * one (`Help(3)`, the attack tutorial) and it is NOT gated by
		 * `Inventory.help` — only `Inventory.as:158`'s own popup is, so R1's
		 * line does not cover it. A `Help` is the sole writer of the freeze
		 * flag while it is up, so the gate behaves CORRECTLY, the tick
		 * counter stops, and no span can ever be dispatched again. Measured:
		 * the probe collected the sword and then pinned at tick 62 with
		 * `dead_frames` climbing without bound.
		 *
		 * Hence the division this rung settles on, and the gate below:
		 * **the tape drives every dialogue; `autoAdvance` handles only the
		 * freeze no tape can reach.**
		 *
		 * ⚠ A `Help` is dismissed by `Input.pressed`, not `Input.released`
		 * (`Help.update` reads `pressed` over its own key list, which for
		 * frame 3 is [X, C]). So the freeze ends on phase 0 and the release
		 * has to be carried into the next live frame — see
		 * `autoAdvanceHeld`.
		 *
		 * ── ⛔ AND THAT GIVES `saw_auto_advance` A BLIND SPOT ────────────
		 *
		 * The counter increments on phase 1, the RELEASE. A `Help` ends its
		 * freeze on phase 0, so the next frame is LIVE, the phase resets,
		 * the carried release is drained by the live path — which does not
		 * count — and **the counter never sees it.** The sword's `Help(3)`
		 * is auto-advanced on every run that collects the sword and
		 * `saw_auto_advance` still reports 0.
		 *
		 * ⚠ THE PREVIOUS VERSION OF THIS COMMENT CLAIMED THE OPPOSITE —
		 * "non-zero means a `Help` fired, which at R3 is exactly once, for
		 * the sword" — two lines above the paragraph that disproves it. Both
		 * were written in the same batch and neither was checked against the
		 * other. Recorded here rather than quietly deleted, because a
		 * docblock that contradicts its own code two lines later is the
		 * failure worth remembering.
		 *
		 * So the readout means "**no NPC dialogue was auto-advanced**", NOT
		 * "no ceremony fired". That matters because `saw_auto_advance == 0`
		 * is asserted on every fixture as a CENSUS GUARD — "a freeze fired
		 * that nobody planned for" — and the whole `Help` class is currently
		 * invisible to it. Nothing built on it is wrong (the JS model
		 * reproduces every tape exactly, which is the real evidence), but
		 * the guard has a hole in the shape of the thing the R3 batch added.
		 *
		 * THE FIX IS AS3 and therefore belongs to the NEXT BATCH, not to a
		 * build of its own: count in `dispatchKey`'s phase-0 arm as well, or
		 * count once per freeze rather than once per release. R3 closed
		 * under a zero-further-AS3 rule, so this comment is the whole of the
		 * change it was allowed to make.
		 */
		private static function autoAdvance():void
		{
			// ⚠ `classFirst` on a world that is mid-load can be null; the
			// blackCover arm of the caller covers those frames, but the
			// world reference is re-read here rather than assumed.
			var helpUp:Boolean = FP.world != null
				&& FP.world.classFirst(Help) != null;
			// ── R4: THE COUNTER FIX, AND WHY IT IS VERSION-SCOPED ─────────
			//
			// The blind spot the paragraph above describes, closed: count a
			// Help's ARRIVAL rather than a phase. A Help ends its freeze on
			// the PRESS (phase 0), so phase 1 — where the counter lived —
			// never runs for one; counting the arrival is also immune to a
			// Help that needs more than one press, which a phase-0 counter
			// would double-count.
			//
			// ⚠ IT IS NOT BYTE-INERT, WHICH IS WHY IT IS SCOPED TO v4. The
			// sword's `Help(3)` is auto-advanced on every run that collects
			// the sword, so an unscoped fix changes the REPORTED VALUE for
			// ~8 frozen R3 collection fixtures whose committed expectations
			// say `saw_auto_advance: 0` and whose sweep asserts that field
			// per tape. They would fail the flags-off inertness gate BY
			// BEING CORRECT. v<=3 tapes keep the bug-compatible count; a v4
			// tape gets the honest one, and R4 asserts it as a POSITIVE.
			// ── R5: THE UNIFICATION, AND WHY IT IS ALSO VERSION-SCOPED ────
			//
			// R4's fix above closed the blind spot but left TWO counting
			// rules in one counter: a dialogue counted on the RELEASE, a
			// `Help` on its ARRIVAL. So `saw_auto_advance` meant "dialogue
			// releases plus Help arrivals" — a number with no single unit,
			// which is not a census guard so much as two guards sharing a
			// field. R3 recorded the fix as owed and R4 could only do half of
			// it; this is the other half.
			//
			// v5's rule is ONE: count a FREEZE ARRIVAL, whatever raised it.
			// The unit is then "ceremonies the bot dismissed", which is what
			// the readout was always supposed to mean and what the fixture
			// sweeps assert as `0`.
			//
			// ⚠ SCOPED, for the R4 reason exactly: it is NOT byte-inert. A
			// dialogue that takes several presses counted once per release
			// under v<=4 and counts once TOTAL under v5, so an unscoped
			// change would move the reported value for committed fixtures
			// whose expectations say `saw_auto_advance: 0` and whose sweep
			// asserts that field per tape — they would fail the flags-off
			// inertness gate BY BEING CORRECT.
			var freezeUp:Boolean = Game.talking || helpUp;
			if (tapeVersion >= 5)
			{
				if (freezeUp && !freezeWasUp) sawAutoAdvance++;
			}
			else if (tapeVersion == 4)
			{
				if (helpUp && !helpWasUp) sawAutoAdvance++;
			}
			freezeWasUp = freezeUp;
			helpWasUp = helpUp;
			if (!freezeUp)
			{
				autoAdvancePhase = 0;
				return;
			}
			var phase:int = autoAdvancePhase % AUTO_ADVANCE_CADENCE;
			if (phase == 0)
			{
				dispatchKey(KEY_PRIMARY, true);
				autoAdvanceHeld = true;
			}
			else if (phase == 1)
			{
				dispatchKey(KEY_PRIMARY, false);
				autoAdvanceHeld = false;
				// v5 counts arrivals above; counting here too would
				// double-count a multi-press dialogue, which is the defect
				// the unification exists to remove.
				if (tapeVersion < 5) sawAutoAdvance++;
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
