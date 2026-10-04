package
{
	import flash.utils.getDefinitionByName;

	/**
	 * Rng — the game's side of the recompiled runtime's determinism hooks.
	 *
	 * `Math.random()` in the recompiled build is ONE GLOBAL 31-bit XOR-shift
	 * LFSR whose entire state is a single uint32
	 * (`SWFModernRuntime/src/avm2/avm2_number.c`). That makes a page
	 * reproducible — the same tape on a fresh page draws the same numbers —
	 * and it does NOT make the stream predictable from outside, because the
	 * position at any moment is the whole page's history: three draws per
	 * `Tile` constructed, one per `Enemy`, one per indexed sound, two per
	 * frame of camera shake, and every world built since load including the
	 * title screen. A model that has to state what the Owl's next rock does
	 * needs the ABSOLUTE draw index and no readout carries it.
	 *
	 * The runtime therefore exposes the state, and `Bot.botStart` RESETS it
	 * to a seed the tape declares — which deletes the history question
	 * instead of answering it: after the reset a model owes only the draws
	 * the recorded window itself consumes.
	 *
	 * ── The second half: TWO STREAMS ─────────────────────────────────────
	 * A reset fixes the origin; it does not stop a COSMETIC draw from moving
	 * the gameplay stream. Every sprite frame, particle, sound index and
	 * camera jiggle shifts every gameplay draw that follows it, so without a
	 * split the model must count all of them forever. Only this side knows
	 * which of its own draws are which, so the split lives here: the ~30
	 * call sites whose value nothing gameplay-visible reads call `Rng.cos()`
	 * instead of `Math.random()`.
	 *
	 * ⛓ **ON BY DEFAULT since 3′b (seedling-wasm-leak L4, ⚖ user re-ruling
	 * 2026-10-04); it was off before.** With `split` false, `cos()` IS
	 * `Math.random()` — the same call, in the same order, drawing from the
	 * same generator. Every TAPE still sets the flag from its own declaration
	 * at `botStart` (`tape_version` < 7 means false by definition), so no
	 * tape's own window changes. What the default reaches is play with no
	 * tape armed — the page's boot world, the title, the standalone game, the
	 * frames after `botReset` — where every cosmetic draw now stays off the
	 * gameplay stream. ⚠ The one thing it moves for an UNSEEDED tape is where
	 * the stream it INHERITS from the page starts (the boot world's tile
	 * draws no longer advance it); see the L4 record for the bounded re-run.
	 *
	 * ⛔ CLASSIFYING IS THE RISKY HALF, AND ONE SITE ALREADY MOVED. The
	 * blade positions in `Tile.addGrass()` look like decoration and are NOT:
	 * `Grass` carries a hitbox and `cut()` increments `Main.grassCut`, so
	 * where a blade lands decides whether a sword swing counts one. It stays
	 * on the gameplay stream. A misclassification is silent — it does not
	 * throw, it just makes a value the model predicts land somewhere else —
	 * so the rule is: route a site only when the drawn value's ONLY readers
	 * are `render()`, a `Draw` call, an audio channel, or nothing at all.
	 */
	public class Rng
	{
		/**
		 * The runtime hook class, or null in a build without it.
		 *
		 * Typed `*` deliberately: `swfmodern.Rng` exists only in the
		 * recompiled runtime and has no compile-time declaration here, so
		 * every call through it is a runtime dispatch.
		 */
		private static var hooks:* = null;
		private static var probed:Boolean = false;

		/** Are the cosmetic draws on their own stream? Written by `Bot`;
		 *  true when no tape says otherwise (3′b). */
		public static var split:Boolean = true;

		private static function resolve():void
		{
			if (probed) return;
			probed = true;
			try
			{
				hooks = getDefinitionByName("swfmodern.Rng");
			}
			catch (e:Error)
			{
				// A build without the hooks. Not fatal here — `available`
				// is what `Bot` refuses a seeded tape on, so the absence is
				// reported once, by name, instead of silently running a tape
				// whose declared seed was never applied.
				hooks = null;
			}
		}

		/** Does this build carry the runtime hooks? */
		public static function get available():Boolean
		{
			resolve();
			return hooks != null;
		}

		/**
		 * A COSMETIC draw: `Math.random()` unless the split is on.
		 *
		 * ⚠ The `!split` arm must stay first and must stay a plain
		 * `Math.random()` — it is the byte-inertness of every tape that
		 * declares no split. Under the split the hooks are resolved here
		 * (the default is now on, so this can be the page's first draw), and
		 * a build without them (Flash, Ruffle) falls back to `Math.random()`
		 * rather than throwing.
		 */
		public static function cos():Number
		{
			if (!split) return Math.random();
			resolve();
			if (hooks == null) return Math.random();
			return Number(hooks.cosmetic());
		}

		/**
		 * A cosmetic-stream draw REGARDLESS of `split` — the probe's arm.
		 *
		 * `cos()` is the gameplay-visible path and must fall through when
		 * the split is off; this one always reads the second generator, so
		 * an instrument can measure that stream on a tape that is not
		 * running split.
		 */
		public static function cosDraw():Number
		{
			resolve();
			return (hooks == null) ? -1 : Number(hooks.cosmetic());
		}

		/** The gameplay stream's state (its one uint32), or -1 with no hooks. */
		public static function get state():Number
		{
			resolve();
			return (hooks == null) ? -1 : Number(hooks.state());
		}

		/** The cosmetic stream's state, or -1 with no hooks. */
		public static function get cosmeticState():Number
		{
			resolve();
			return (hooks == null) ? -1 : Number(hooks.cosmeticState());
		}

		/**
		 * Reseed the gameplay stream. 0 means the build's own boot seed.
		 *
		 * ⛓ Write and reset are the SAME operation for this generator: the
		 * state is one uint32 and the seed is written straight into it, so
		 * "reset to seed s" and "put the state back to s" are one call. That
		 * is what lets `Bot.botRngProbe` sample the stream and restore it.
		 */
		public static function setState(v:Number):void
		{
			resolve();
			if (hooks != null) hooks.setState(v);
		}

		/** Reseed the cosmetic stream. 0 means the build's own boot seed. */
		public static function setCosmeticState(v:Number):void
		{
			resolve();
			if (hooks != null) hooks.setCosmeticState(v);
		}
	}
}
