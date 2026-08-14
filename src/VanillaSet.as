package
{
	/**
	 * VanillaSet — the built-in `seedling-vanilla` MANIFEST, and the reason
	 * there is no privileged built-in path any more.
	 *
	 * Plan: `CC/docs/plans/seedling-external-level-sets.md` §4.3 (⚖ user,
	 * 2026-08-13, shape (c)) and §3.5 (what was keyed to level identity).
	 * Schema: `frontend/schema/seedling-level-set.schema.json`. The committed
	 * JSON twin of this file is
	 * `frontend/modules/seedlingDemo/fixtures/seedling-vanilla-set.json`.
	 *
	 * ── WHY A MANIFEST FOR THE ROOMS THAT ARE ALREADY COMPILED IN ────────
	 *
	 * ANTI-ROT, and that is the whole of it. A loader only custom sets
	 * exercise is a loader that breaks silently between the day it is written
	 * and the day someone uses it. The 116 original rooms are mounted through
	 * the same `LevelSet` every delivered set goes through, so **every boot of
	 * the ordinary game is a test of the level-set loader**.
	 *
	 * ⇒ this file holds the six things `Game.as` used to hold as literals
	 * (§3.5), and it holds them because they are SET data, not game data:
	 * where a new game starts, which rooms the title screen cycles, which room
	 * gets the snow gradient, which room is exempt from the music overrides,
	 * what each room's music is, and the six room references that live in CODE
	 * rather than in level data.
	 *
	 * ── ⛔ WHAT THIS IS *NOT*: THE WIRE FORMAT ───────────────────────────
	 *
	 * A delivered set carries `source.xml` — the room's OEL text. This one
	 * carries `source.embed`, and in THIS BUILD that is the compiled-in
	 * `Class` rather than the schema's asset-path string, because a Class is
	 * what the path resolves to once mxmlc has run. The two arms meet at
	 * `Game.loadLevelIndex`, three lines apart, and both end in the one
	 * `loadLevelXML`. That is §4.3's declared residue, stated here rather than
	 * discovered later: "the external path is the only path" is true of shape
	 * (b) and only nearly true of (c).
	 *
	 * ⚠ AND IT CARRIES NO ROOM NAMES. The JSON twin does (`OverWorld1`, …);
	 * nothing in the game reads them — position is identity — so 116 strings
	 * of transcription risk buy nothing here. The gate compares what this file
	 * *does* carry.
	 *
	 * ── ⛓ WHERE THE NUMBERS CAME FROM ───────────────────────────────────
	 *
	 * MUSICS was MOVED, not retyped: it is `Game.as:199`'s literal, cut and
	 * pasted. The JSON twin was produced independently by
	 * `scripts/procgen/extract-seedling-vanilla-set.py` reading the OELs and
	 * `Game.as`, and `check-seedling-vanilla-manifest.mjs` asserts the two
	 * agree through the BUILT ARTIFACT. Two representations, one truth, and a
	 * gate that fails when they drift.
	 */
	public class VanillaSet
	{
		/**
		 * The set id, content-hashed over the JSON twin (plan §9.1 rule 2).
		 * ⛔ PINNED TO THAT FILE: edit the fixture and this goes stale, which
		 * is what `check-seedling-vanilla-manifest.mjs` exists to catch. It is
		 * not computed here — FNV-1a over a canonical JSON document is not
		 * something this build can reproduce, and a hash computed two ways is
		 * two implementations of one truth.
		 */
		public static const SET_ID:String = "seedling-vanilla-02408e1d";

		/**
		 * ⛓ MOVED FROM `Game.as:199`, unedited — 116 entries, one per room.
		 *
		 * Index into `Music.songs` (14 entries, 0..13; `Game.bossMusic` = 13).
		 * ⛔ `-1` IS DATA, not a hole: the seven rooms whose static value is
		 * -1 are exactly the seven boss rooms (19, 32, 43, 57, 69, 82, 112),
		 * and -1 means *this room's boss writes the slot at runtime*. Seeding
		 * `Game.levelMusics` from this array is therefore a COPY: the bosses
		 * write the copy, and the manifest stays the manifest.
		 */
		public static const MUSICS:Array = new Array(0, 3,
		5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
		0,
		6, 6, 6, 6, 6, 6, -1, 6,
		7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, -1,
		0, 0, 0, 0, 0,
		8, 8, 8, 8, 8, -1,
		0,
		0, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, -1, 9,
		10, 10, 10, 10, 10, 10, 10, 10, 10, 10, -1, 10,
		11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11, -1,
		0, 11, 11, 0, 0, 0, 0, 0, 0,
		0, 12, 0, 0, 11, 11,
		12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
		5, -1, 5, 5, 5);

		/**
		 * ⛓ MOVED FROM `Game.as:449` (`menuLevels`). The rooms the title
		 * screen cycles, IN ORDER — the order is load-bearing, `Game.as:1294`
		 * advances `menuIndex` modulo the length.
		 */
		public static const MENU_ROOMS:Array = new Array(12, 37, 44, 87, 88, 89);

		/** ⛓ MOVED FROM `Game.as:796`. Where a new game begins. */
		public static const START_LEVEL:int = 0;

		/**
		 * ⛓ MOVED FROM `Game.as:908` (`if (level == 45)`) — the rooms whose
		 * snow alpha scales with the player's height up the screen.
		 */
		// ⛔ BRACKETS, NOT `new Array(45)`. A single INTEGER argument is a
		// LENGTH, not an element: `new Array(45)` is 45 empty slots, so
		// `indexOf(45)` is -1 and room 45 loses its snow. Caught by
		// `check-seedling-vanilla-manifest.mjs` on its first run — `[] vs [45]`
		// — which is the whole reason the manifest is read back out of the
		// built artifact rather than trusted from the source.
		public static const SNOW_GRADIENT_ROOMS:Array = [45];

		/**
		 * ⛓ MOVED FROM `Game.as:1175` and `:1181` (`level != 10`) — the rooms
		 * exempt from BOTH sword/shield music overrides.
		 */
		public static const MUSIC_EXEMPT_ROOMS:Array = [10]; // brackets — see above

		/**
		 * ⛓ The six room references that live in CODE and that no bundle
		 * rewrite can reach (§8.2a). A CLOSED vocabulary, all six required —
		 * `named_rooms` in the schema, and the validator refuses a set missing
		 * one rather than letting it fall back to a vanilla index.
		 *
		 * Two shapes: a persistence target carries a level alone; a warp also
		 * carries the arrival position it is constructed with, because falling
		 * back to the `Game` constructor's (80, 128) would put the player in a
		 * wall somewhere plausible-looking.
		 */
		public static const NAMED_ROOMS:Object = {
			// Moonrock.as:134 new Teleporter(…, 2, 48, 32) AND :135 setPersistence(0, false, 2)
			moonrock_target: { level: 2, x: 48, y: 32 },
			// Scenery/FinalDoor.as:50 checkPersistence(0, 114)
			watcher_text: { level: 114 },
			// Player.as:491 new Game(114, 72, 128, false, 2)
			dark_shrum_death: { level: 114, x: 72, y: 128 },
			// Pickups/Seed.as:73 new Game(1, 64, 96, false)
			bloody_seed_ending: { level: 1, x: 64, y: 96 },
			// Enemies/LightBossController.as:104 new Teleporter(x, y, 36, 112, 96, true)
			light_boss_exit: { level: 36, x: 112, y: 96 },
			// Enemies/TentacleBeast.as:213 new Teleporter(..., 58, 56, 96)
			tentacle_beast_mouth: { level: 58, x: 56, y: 96 }
		};

		/**
		 * Build the vanilla set: one room object per compiled-in `[Embed]`,
		 * in `Game.levels` order, plus the manifest metadata.
		 *
		 * ⚠ NOTHING IS CONVERTED HERE. A room holds the `Class`, and the
		 * ByteArray → String conversion happens at room-load time, which is
		 * byte-for-byte the work `Game.loadlevel` already did on every room
		 * load. That is why shape (c) costs nothing: it is 116 object
		 * literals at first use, not 116 XML parses at startup.
		 *
		 * ⛔ IT ALSO CANNOT BE BUILT BEFORE `Game`'s STATICS EXIST, because
		 * `Game.levels` is one of them. `LevelSet.active()` is the only
		 * caller and it runs from instance code (`loadLevelIndex`), never
		 * from a static initialiser.
		 */
		public static function build():LevelSet
		{
			var rooms:Array = new Array();
			var i:int;
			for (i = 0; i < Game.levels.length; i++)
			{
				rooms.push({
					id: i,
					source: { embed: Game.levels[i] },
					music: MUSICS[i],
					snow_gradient: SNOW_GRADIENT_ROOMS.indexOf(i) >= 0,
					music_override_exempt: MUSIC_EXEMPT_ROOMS.indexOf(i) >= 0
				});
			}
			var meta:Object = {
				schema_version: LevelSet.SCHEMA_VERSION,
				set_id: SET_ID,
				start: { level: START_LEVEL },
				menu_rooms: MENU_ROOMS,
				named_rooms: NAMED_ROOMS
			};
			return new LevelSet(SET_ID, rooms, meta);
		}
	}
}
