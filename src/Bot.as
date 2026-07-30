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

				if (t.tape_version != 1)
					return "error:tape_version must be 1, got " + t.tape_version;
				if (t.game != "seedling")
					return "error:game must be seedling, got " + t.game;
				if (!(t.noclip is Boolean))
					return "error:noclip must be a boolean (no default)";
				if (t.boot == null)
					return "error:missing boot";
				if (!(t.inputs is Array))
					return "error:inputs must be an array";

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
				noclip = t.noclip;

				loaded = true;
				armed = false;
				finished = false;
				errorText = "";
				tick = 0;
				sawInputRefused = false;
				deadFrames = 0;
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

		/** Arm the loaded tape. Tick 0 is the next live frame. */
		public static function botStart():String
		{
			if (!loaded) return "error:no tape loaded";
			if (armed) return "error:already running";
			armed = true;
			finished = false;
			errorText = "";
			tick = 0;
			sawInputRefused = false;
			deadFrames = 0;
			clearObservations();
			return "ok";
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
				y: (p == null) ? 0 : p.y
			};
			return JSON.stringify(o);
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
			spanCode = new Array();
			spanFrom = new Array();
			spanTo = new Array();
			sawInputRefused = false;
			deadFrames = 0;
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
				return;
			}

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

		private static function dispatchKey(code:int, down:Boolean):void
		{
			if (FP.stage == null) return;
			FP.stage.dispatchEvent(new KeyboardEvent(
				down ? KeyboardEvent.KEY_DOWN : KeyboardEvent.KEY_UP,
				true, false, 0, code));
		}
	}
}
