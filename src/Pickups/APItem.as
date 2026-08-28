package Pickups
{
	import net.flashpunk.FP;
	import net.flashpunk.Graphic;
	import net.flashpunk.graphics.Image;
	import net.flashpunk.graphics.Spritemap;
	import Scenery.Tile;
	/**
	 * ⛓⛓ THE ARCHIPELAGO PLACEMENT PICKUP (procgen EDITOR INTEGRATION, M1).
	 *
	 * Built from `<apitem x=… y=… tag="<n>" look="<name>"/>`, the element the
	 * HOST writes into every randomized location of a delivered level set
	 * (`apPlacementRewriter.js`). It is the only entity in this game that
	 * GRANTS NOTHING: collecting it clears its persistence slot, which is what
	 * `Game.setPersistence` reports to the host as `pendingCheck`, and the
	 * host — which alone knows what Archipelago placed here and for whom —
	 * grants the item back through the bridge's existing property writes.
	 * ⇒ ONE writer of every `Main.*` item flag, so no echo/undo race.
	 *
	 * ⛔ NO `Player.*` WRITE, NO `Main.*` WRITE, NO `Help`, NO medal. A second
	 * grant path is exactly what this class exists to remove.
	 *
	 * `@look` is a CLOSED vocabulary of 21 names, and each names ONE sprite on
	 * its own — 14 pickup graphics, the five boss keys (which differ only by
	 * frame, so the index rides in the name), the seed, and `ap`, the
	 * Archipelago logo that stands for everything this game has no graphic
	 * for: another world's item, another player's item, and `Fire`, which is a
	 * boss drop and has no pickup entity anywhere in the game.
	 * An unknown look draws `ap` and traces; it never throws, because a level
	 * set is data and a room that refuses to build is worse than a wrong icon.
	 */
	public class APItem extends Pickup
	{
		/**
		 * ⛓ THE SPRITES ARE RE-EMBEDDED, NOT BORROWED, AND THAT WAS MEASURED.
		 * Every pickup class binds its own graphic through a PRIVATE per-class
		 * `[Embed]` (`Sword.as:14`, and 14 more like it), so there is no sheet
		 * to look a name up in. The obvious shortcut — construct a throwaway
		 * `new Sword(0,0,-1)` and steal its `graphic` — is UNSAFE: `Chest`'s
		 * own field initialiser calls `Rng.cos()` (`Chest.as:22`) and its
		 * constructor calls `FP.world.remove(this)` via `checkBySeal()`, so a
		 * discarded instance would move the RNG stream every tape is recorded
		 * against and touch the outgoing world. Re-embedding costs ~1 KB of
		 * PNG per look and moves nothing.
		 *
		 * ⛔ THE FRAME SIZE IS PART OF THE BINDING. `Spritemap(img, w, h)` with
		 * the wrong `w`/`h` draws a slice of the sheet, not a smaller sprite;
		 * every number below is copied from the class that owns that PNG.
		 * A `0` frame size means the class binds an `Image` (the whole file) —
		 * `DarkShield.as:13` and `DarkSuit.as:13` are the two that do.
		 */
		[Embed(source = "../../assets/graphics/Sword.png")] private static var imgSword:Class;
		[Embed(source = "../../assets/graphics/Shield.png")] private static var imgShield:Class;
		[Embed(source = "../../assets/graphics/DarkShield.png")] private static var imgDarkShield:Class;
		[Embed(source = "../../assets/graphics/Conch.png")] private static var imgConch:Class;
		[Embed(source = "../../assets/graphics/Feather.png")] private static var imgFeather:Class;
		[Embed(source = "../../assets/graphics/WandPickup.png")] private static var imgWand:Class;
		[Embed(source = "../../assets/graphics/FireWandPickup.png")] private static var imgFireWand:Class;
		[Embed(source = "../../assets/graphics/GhostSpear.png")] private static var imgGhostSpear:Class;
		[Embed(source = "../../assets/graphics/GhostSwordPickup.png")] private static var imgGhostSword:Class;
		[Embed(source = "../../assets/graphics/DarkSuit.png")] private static var imgDarkSuit:Class;
		[Embed(source = "../../assets/graphics/TorchPickup.png")] private static var imgTorchPickup:Class;
		[Embed(source = "../../assets/graphics/HealthPickup.png")] private static var imgHealth:Class;
		[Embed(source = "../../assets/graphics/BossTotemParts.png")] private static var imgTotemPart:Class;
		[Embed(source = "../../assets/graphics/Chest.png")] private static var imgChest:Class;
		[Embed(source = "../../assets/graphics/Seed.png")] private static var imgSeed:Class;
		/**
		 * The placeholder. SOURCE: Archipelago-CC `data/icon.png` (the
		 * Archipelago application icon, 512x512 RGBA), Lanczos-downscaled to
		 * 16x16. LICENCE: the Archipelago repository's own root `LICENSE`
		 * (MIT). ⛔ NOT `WebHostLib/static/static/branding/*` — that directory
		 * ships its own LICENSE reading "All rights reserved".
		 */
		[Embed(source = "../../assets/graphics/ArchipelagoLogo.png")] private static var imgAP:Class;

		/**
		 * look -> [embedded PNG, frame width, frame height]; 0x0 = an Image.
		 * ⛔ BUILT ON FIRST USE, not at declaration: an `[Embed]` static is
		 * assigned by generated class-initialiser code, and a const table that
		 * captured those Classes at declaration time would depend on that
		 * generated code having run first. One `if` buys independence from it.
		 */
		private static var SHEETS:Object = null;
		private static function sheets():Object
		{
			if (SHEETS != null) return SHEETS;
			SHEETS = {
				"sword": [imgSword, 16, 16], "shield": [imgShield, 7, 7],
				"darkshield": [imgDarkShield, 0, 0], "conch": [imgConch, 8, 8],
				"feather": [imgFeather, 12, 12], "wand": [imgWand, 5, 9],
				"firewand": [imgFireWand, 5, 9], "ghostspear": [imgGhostSpear, 20, 7],
				"ghostsword": [imgGhostSword, 24, 7], "darksuit": [imgDarkSuit, 0, 0],
				"torchpickup": [imgTorchPickup, 12, 12], "health": [imgHealth, 8, 8],
				"totempart": [imgTotemPart, 24, 24], "chest": [imgChest, 16, 16],
				"seed": [imgSeed, 9, 13], "ap": [imgAP, 0, 0]
			};
			return SHEETS;
		}
		/** The look prefix whose sprite is a shared `Game.bossKeys` frame. */
		private static const KEY_LOOK:String = "bosskey";

		private var tag:int;
		/**
		 * ⛓ The same latch the fourteen pickup classes carry. `check()` removes
		 * an already-collected item on re-entry, and that removal must NOT
		 * re-report the check — so it clears this first and `removed()` reads it.
		 */
		private var doActions:Boolean = true;

		public function APItem(_x:int, _y:int, _tag:int, _look:String)
		{
			// The same half-tile offset every pickup applies, so an APItem
			// stands exactly where the entity it replaced stood.
			super(_x + Tile.w / 2, _y + Tile.h / 2, graphicFor(_look), null, false);
			setHitbox(8, 8, 4, 4);
			tag = _tag;
		}

		/**
		 * ⛔ THE COLLECTED MARKER IS `false`, NOT `true` — MEASURED.
		 * `Main.buildLevelPersistence` fills the table with `true` ("nothing
		 * cleared", `Main.as:387-394`) and every one of the fourteen pickup
		 * classes clears its slot with `Game.setPersistence(tag, false)`.
		 * Writing `true` here would be a no-op on a fresh save and the item
		 * would come back on re-entry.
		 */
		override public function removed():void
		{
			if (doActions)
			{
				Game.setPersistence(tag, false);
			}
		}

		override public function check():void
		{
			super.check();
			if (tag >= 0 && !Game.checkPersistence(tag))
			{
				doActions = false;
				FP.world.remove(this);
			}
		}

		/**
		 * ONE look, ONE sprite. The five keys share `BossKeyN.png` through
		 * `Game.bossKeys`, already `centerOO()`'d by `Game`'s own constructor
		 * (`Game.as:767-770`) and already shared between entities in vanilla,
		 * so the index is read out of the look rather than re-embedded.
		 */
		private static function graphicFor(_look:String):Graphic
		{
			var look:String = _look == null ? "" : _look;
			if (look.indexOf(KEY_LOOK) == 0)
			{
				var k:int = int(look.substr(KEY_LOOK.length));
				if (k >= 0 && k < Game.bossKeys.length)
				{
					return Game.bossKeys[k] as Graphic;
				}
			}
			var sheet:Array = sheets()[look] as Array;
			if (sheet == null)
			{
				trace("APItem: unknown look " + look + " — drawing the Archipelago logo");
				sheet = sheets()["ap"] as Array;
			}
			var g:Image = sheet[1] > 0
				? new Spritemap(sheet[0] as Class, sheet[1], sheet[2])
				: new Image(sheet[0] as Class);
			g.centerOO();
			return g;
		}
	}
}
