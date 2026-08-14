package
{
	import flash.geom.Point;

	/**
	 * LevelSet — the MOUNTED level table, and the arrival side of the
	 * external-level-set transport.
	 *
	 * Plan: `CC/docs/plans/seedling-external-level-sets.md` in Archipelago-CC
	 * (§4.1 the manifest, §4.4 seams 2–3, §8.1 the chunking measurement, §9
	 * the frozen schema). The wire format is
	 * `frontend/schema/seedling-level-set-chunk.schema.json` and the rooms are
	 * `seedling-level-set.schema.json` rooms.
	 *
	 * ── WHY THIS EXISTS ──────────────────────────────────────────────────
	 *
	 * The browser artifact is a SWFRecomp AVM2 recompile, so a level compiled
	 * into `Game.levels` costs a full source → SWF → wasm run per change. A
	 * set delivered over ExternalInterface costs a few KB of XML. Everything
	 * here is that delivery and nothing else: `mounted` REPLACES the built-in
	 * table (⚖ user, plan §1) and is the one authority for its length.
	 *
	 * ── WHAT THIS SIDE OWNS, AND WHAT IT DOES NOT ────────────────────────
	 *
	 * `frontend/modules/seedlingDemo/levelSetValidator.js` is the authority on
	 * whether a set is VALID: level-index range on the three OEL attributes,
	 * the 30-tag ceiling, `ButtonRoom`'s tset-as-tag, the closed 7-entry sign
	 * table, `named_rooms` completeness, the content hash. It is JavaScript
	 * and cannot run in here, and none of it is re-implemented here — two
	 * validators that can disagree is the failure this arc keeps finding.
	 *
	 * ⇒ THIS SIDE OWNS ARRIVAL, WHICH IS A DIFFERENT QUESTION: did a whole,
	 * self-consistent delivery show up? Envelope shape, `schema_version`, one
	 * `set_id` per delivery, every `chunk_index` exactly once, room ids dense
	 * from 0, and rooms this build can actually serve. Those checks cannot
	 * contradict the validator because they are not about validity; the one
	 * rule both sides do implement — assembly — is pinned to a shared
	 * conformance fixture, because the sender assembles a batch it already
	 * holds and this side must assemble a STREAM, and there is no way to have
	 * only one implementation of that.
	 *
	 * ⛔ NOTHING IS MOUNTED UNTIL THE DELIVERY IS COMPLETE. A chunk that
	 * overruns the AVM2 arena kills the runtime mid-call (§8.1), so an
	 * incremental mount would leave a PARTIAL table mounted — on which the
	 * game runs happily, every index past the end reading as *already
	 * cleared* and reporting itself healthy (§8.3, driven). Stage, check,
	 * then swap.
	 */
	public class LevelSet
	{
		/** The only version this build speaks. Frozen in plan §9. */
		public static const SCHEMA_VERSION:int = 1;

		/**
		 * Mirrors `MAX_ROOMS_PER_CHUNK` in `levelSetValidator.js`, measured at
		 * 16 and proven by REPETITION over 15 consecutive calls (§8.1).
		 *
		 * ⚠ IT CANNOT PROTECT THIS SIDE AND IS NOT HERE FOR THAT. An oversized
		 * chunk dies inside `JSON.parse` in the arena, before one line of this
		 * class runs. Its only job is that a delivery the sender would refuse
		 * is refused here too, so the two never disagree about a verdict.
		 */
		public static const MAX_ROOMS_PER_CHUNK:int = 16;

		/**
		 * The DELIVERED set, or null = the built-in vanilla manifest.
		 *
		 * ⛔ NULL NO LONGER MEANS "no set" — phase 3b. Read the effective
		 * table through `active()`, which answers with `VanillaSet.build()`
		 * when nothing has been delivered, so there is one code path and the
		 * ordinary game walks it on every boot. This field stays the
		 * *delivered* set on purpose: phase 4's save stamp has to be able to
		 * tell "the player is on vanilla" from "the player is on a set that
		 * happens to be identical", and a readout that erased the difference
		 * would make that undecidable.
		 */
		public static var mounted:LevelSet = null;

		public var setId:String;
		/** Room objects in set order; index IS the level id. */
		public var rooms:Array;
		/** The set metadata that rode on chunk 0, or null. Phase 3b reads it. */
		public var meta:Object;

		// ── staging: one delivery in flight ──────────────────────────────
		private static var stageSetId:String = null;
		private static var stageChunkCount:int = -1;
		private static var stageSeen:Array = null;    // chunk_index -> true
		private static var stageSeenCount:int = 0;
		private static var stageRoomById:Array = null;
		private static var stageRoomCount:int = 0;
		private static var stageMeta:Object = null;

		public function LevelSet(id:String, roomsInOrder:Array, metadata:Object)
		{
			setId = id;
			rooms = roomsInOrder;
			meta = metadata;
			seedRuntimeTables();
			reconcileSave();
		}

		/**
		 * Copy the manifest's per-room music into `Game.levelMusics`, the one
		 * table the game MUTATES while it plays.
		 *
		 * ⛔ THE CONSTRUCTOR IS THE RIGHT PLACE AND THE ONLY ONE. A set
		 * becomes real exactly once, here, whether it arrived over
		 * ExternalInterface or was built from the embeds — so seeding here is
		 * exactly-once per set by construction, and a mount that forgot to
		 * seed cannot exist.
		 *
		 * ⛔ AND IT IS A COPY, NEVER AN ALIAS. Seven boss classes assign
		 * `Game.levelMusics[level]` during play — `bossMusic` on wake, -1 on
		 * death, 14 call sites (§8.2c). Aliasing the manifest's array would
		 * let a boss fight rewrite the SET, so a re-mount would inherit the
		 * previous playthrough's state and the manifest would stop describing
		 * itself. This is state initialised from data; the data stays data.
		 */
		private function seedRuntimeTables():void
		{
			var musics:Array = new Array();
			for (var i:int = 0; i < rooms.length; i++)
			{
				var room:Object = rooms[i];
				musics.push(room == null || room.music == null ? -1 : int(room.music));
			}
			Game.levelMusics = musics;
		}

		/** The XML text for a level id, or null if this build cannot serve it. */
		public function xmlFor(index:int):String
		{
			if (index < 0 || index >= rooms.length)
				return null;
			var room:Object = rooms[index];
			if (room == null || room.source == null)
				return null;
			return room.source.xml as String;
		}

		/** Rooms in the mounted set, or -1 when the built-in table is in use. */
		public static function mountedRoomCount():int
		{
			return mounted == null ? -1 : mounted.rooms.length;
		}

		/** Drop any delivery in flight. Does NOT unmount a mounted set. */
		public static function resetStaging():void
		{
			stageSetId = null;
			stageChunkCount = -1;
			stageSeen = null;
			stageSeenCount = 0;
			stageRoomById = null;
			stageRoomCount = 0;
			stageMeta = null;
		}

		/** Chunks of the delivery in flight that have arrived. */
		public static function stagedChunks():int
		{
			return stageSeenCount;
		}

		/** Chunks the delivery in flight declares, or -1 if none is open. */
		public static function stagedChunkCount():int
		{
			return stageChunkCount;
		}

		private static function isInt(v:*):Boolean
		{
			return (v is Number) && (Number(v) == int(Number(v)));
		}

		private static function isText(v:*):Boolean
		{
			return (v is String) && (v as String).length > 0;
		}

		/**
		 * Accept one chunk envelope. Returns "ok" when this chunk COMPLETED
		 * the delivery and the set is now mounted, "pending" when it was
		 * accepted and more are owed, or "error:..." — which refuses the whole
		 * delivery and drops what was staged, because a delivery with one bad
		 * envelope in it is not a set that can be repaired by the next call.
		 *
		 * Chunks may arrive in ANY order, deliberately: the sender's
		 * `assembleLevelSetChunks` accepts any order, and a receiver that
		 * demanded chunk 0 first would refuse deliveries the sender calls
		 * valid — a verdict disagreement, which is the thing being avoided.
		 * Room `id` is the authority for placement either way (§9.1).
		 */
		public static function acceptChunk(chunk:Object):String
		{
			if (chunk == null)
				return "error:chunk must be an object";

			if (!isInt(chunk.schema_version)
				|| int(chunk.schema_version) != SCHEMA_VERSION)
			{
				resetStaging();
				return "error:chunk.schema_version must be " + SCHEMA_VERSION
					+ ", got " + chunk.schema_version;
			}
			if (!isText(chunk.set_id))
			{
				resetStaging();
				return "error:chunk.set_id must be a non-empty string";
			}
			if (!isInt(chunk.chunk_count) || int(chunk.chunk_count) < 1)
			{
				resetStaging();
				return "error:chunk.chunk_count must be a positive integer, got "
					+ chunk.chunk_count;
			}
			if (!isInt(chunk.chunk_index) || int(chunk.chunk_index) < 0)
			{
				resetStaging();
				return "error:chunk.chunk_index must be a non-negative integer, got "
					+ chunk.chunk_index;
			}
			if (!(chunk.rooms is Array) || (chunk.rooms as Array).length == 0)
			{
				resetStaging();
				return "error:chunk.rooms must be a non-empty array";
			}

			var index:int = int(chunk.chunk_index);
			var count:int = int(chunk.chunk_count);
			var incoming:Array = chunk.rooms as Array;

			if (incoming.length > MAX_ROOMS_PER_CHUNK)
			{
				resetStaging();
				return "error:chunk.rooms carries " + incoming.length
					+ " rooms, above MAX_ROOMS_PER_CHUNK (" + MAX_ROOMS_PER_CHUNK + ")";
			}
			if (index >= count)
			{
				resetStaging();
				return "error:chunk.chunk_index " + index
					+ " is outside chunk_count " + count;
			}

			if (stageSeen == null)
			{
				// First chunk of a delivery — whichever index it carries.
				stageSetId = chunk.set_id as String;
				stageChunkCount = count;
				stageSeen = new Array();
				stageSeenCount = 0;
				stageRoomById = new Array();
				stageRoomCount = 0;
				stageMeta = null;
			}
			else
			{
				// ⚠ THE OPEN DELIVERY'S VALUES ARE READ INTO LOCALS FIRST.
				// `resetStaging()` nulls them, and AS3 evaluates the return
				// expression AFTER the call — so building the message inline
				// reported `disagrees with "null"` and `disagrees with -1`,
				// naming the field but not the value it conflicted with. The
				// verdict was right and the reason was useless, which is the
				// half of a refusal this arc keeps insisting on.
				var openId:String = stageSetId;
				var openCount:int = stageChunkCount;
				if ((chunk.set_id as String) != openId)
				{
					var otherId:String = chunk.set_id as String;
					resetStaging();
					return "error:chunk.set_id \"" + otherId + "\" disagrees with \""
						+ openId + "\" — a delivery must not splice two sets";
				}
				if (count != openCount)
				{
					resetStaging();
					return "error:chunk.chunk_count " + count + " disagrees with "
						+ openCount;
				}
				if (stageSeen[index] == true)
				{
					resetStaging();
					return "error:chunk.chunk_index " + index + " is a duplicate";
				}
			}

			// ⛔ The metadata travels ONCE, on chunk 0 — the sender's rule, and
			// the reason is that a delivery with two manifests has no defined
			// identity. Mirrored here so the verdicts match.
			if (index == 0)
			{
				if (chunk.set == null)
				{
					resetStaging();
					return "error:chunk.set is required on chunk_index 0";
				}
				stageMeta = chunk.set;
			}
			else if (chunk.set != null)
			{
				resetStaging();
				return "error:chunk.set is forbidden on chunk_index " + index;
			}

			var i:int;
			for (i = 0; i < incoming.length; i++)
			{
				var room:Object = incoming[i];
				if (room == null || !isInt(room.id) || int(room.id) < 0)
				{
					resetStaging();
					return "error:chunk.rooms[" + i
						+ "] has no non-negative integer id — room id is the"
						+ " authority, not chunk position";
				}
				var id:int = int(room.id);
				if (stageRoomById[id] != null)
				{
					resetStaging();
					return "error:duplicate room id " + id;
				}
				stageRoomById[id] = room;
				stageRoomCount++;
			}

			stageSeen[index] = true;
			stageSeenCount++;
			if (stageSeenCount < stageChunkCount)
				return "pending";

			// ── the delivery is complete: check it, then swap ──────────────
			var assembled:Array = new Array();
			for (i = 0; i < stageRoomCount; i++)
			{
				if (stageRoomById[i] == null)
				{
					var missingOf:int = stageRoomCount;
					resetStaging();
					return "error:assembled rooms are missing id " + i
						+ " — ids must be exactly 0.." + (missingOf - 1)
						+ " with no gaps";
				}
				assembled.push(stageRoomById[i]);
			}
			// ⛓ THE CAPACITY REFUSAL IS GONE — PHASE 4 LIFTED IT, as phase 3
			// said it would. A set bigger than the persistence table used to be
			// refused here because the table was sized from the compiled-in
			// `Game.levels.length` and rows past its end read as *every tag
			// already cleared* while the game reported itself healthy (§8.3).
			// The table is now built from the MOUNTED set — `reconcileSave()`
			// below, called from the constructor — so a set of any size gets a
			// table that addresses it, and there is nothing left to refuse.
			// ⚠ AND THE PARAMETER WENT WITH IT. An ignored `maxRooms` would be
			// an argument every caller still computes and nobody reads — the
			// rule is gone, so its input is gone; `Bot.persistenceLevelCapacity`
			// went too, its job now being `Main.levelPersistenceLevels()`.
			// A room this build cannot serve is refused HERE rather than at the
			// moment the player walks into it. ⚠ The sender's validator calls an
			// `embed` room valid and merely unchecked; this build has no
			// embedded-asset resolver yet (plan §4.3 shape (c), phase 3b), so
			// "valid" and "servable" genuinely differ and the difference is
			// declared rather than silent.
			for (i = 0; i < assembled.length; i++)
			{
				var r:Object = assembled[i];
				if (r.source == null || !isText(r.source.xml))
				{
					var badId:int = i;
					resetStaging();
					return "error:room " + badId
						+ " has no source.xml — this build cannot resolve an"
						+ " embed reference (plan phase 3b)";
				}
			}

			var readySetId:String = stageSetId;
			var readyMeta:Object = stageMeta;
			resetStaging();
			mounted = new LevelSet(readySetId, assembled, readyMeta);
			return "ok";
		}

		// ─────────────────────────────────────────────────────────────────
		// PHASE 3b — the built-in manifest, and the six things `Game.as`
		// used to hold as literals (plan §3.5, §4.3).
		//
		// Everything below reads the ACTIVE set's metadata. There is no
		// vanilla branch in `Game`: the ordinary game is a set like any
		// other, which is what makes every boot a test of this class.
		// ─────────────────────────────────────────────────────────────────

		/** The built-in vanilla set, constructed on first use, then kept. */
		private static var builtInSet:LevelSet = null;

		/**
		 * The EFFECTIVE level table: the delivered set when there is one, the
		 * built-in vanilla manifest otherwise.
		 *
		 * ⚠ CALLED PER FRAME from `Game.update` (the snow gradient and both
		 * music overrides), so it is a null check and a return. The vanilla
		 * set is built once — 116 object literals holding `Class` references,
		 * no XML conversion (see `VanillaSet.build`).
		 */
		public static function active():LevelSet
		{
			if (mounted != null)
				return mounted;
			if (builtInSet == null)
				builtInSet = VanillaSet.build();
			return builtInSet;
		}

		/**
		 * The compiled-in `[Embed]` Class for a room, or null when this room
		 * carries XML text instead — the second arm of §4.3 shape (c).
		 *
		 * ⛓ THE CONVERSION IS NOT HERE, deliberately. `Game.loadlevel(Class)`
		 * is already the three-line embed resolver (`new`, `readUTFBytes`,
		 * `loadLevelXML`) and phase 3 left it exactly as the original wrote
		 * it. This says WHICH class; that says what to do with it, unchanged,
		 * on the path the ordinary game has always taken.
		 */
		public function embedFor(index:int):Class
		{
			if (index < 0 || index >= rooms.length)
				return null;
			var room:Object = rooms[index];
			if (room == null || room.source == null)
				return null;
			return room.source.embed as Class;
		}

		/** Where a new game begins — `Game.as:796`'s literal 0, as data. */
		public function get startLevel():int
		{
			return meta == null || meta.start == null ? 0 : int(meta.start.level);
		}

		/**
		 * Put a fresh game at the set's start. Level always; position only
		 * when the manifest supplies one.
		 *
		 * ⛔ THE OMITTED CASE IS NOT "0, 0" — the schema says an absent x/y
		 * means the `Game` constructor's own defaults (80, 128), which is
		 * where `playerPosition` already is by the time this runs. So an
		 * absent position must leave it ALONE rather than write a default
		 * back, or vanilla (which omits both) would move.
		 */
		public function applyStart(game:Game):void
		{
			game.level = startLevel;
			var spawn:Object = meta == null ? null : meta.start;
			if (spawn == null || spawn.x == null || spawn.y == null)
				return;
			game.playerPosition = new Point(int(spawn.x), int(spawn.y));
		}

		/** Title-screen rooms, in order — `Game.as:449`'s `menuLevels`. */
		public function menuRoom(index:int):int
		{
			var list:Array = menuRooms;
			if (list == null || list.length == 0)
				return 0;
			return int(list[((index % list.length) + list.length) % list.length]);
		}

		/**
		 * How many rooms the title screen cycles. ⛔ NEVER 0: `Game.as:1294`
		 * computes `menuIndex % menuRoomCount()`, and a zero-length list makes
		 * that NaN and the next `menuRoom` lookup undefined. The validator
		 * requires `menu_rooms` to be non-empty; this refuses to return the
		 * value that would break the modulo even if one slipped through.
		 */
		public function menuRoomCount():int
		{
			var list:Array = menuRooms;
			return list == null || list.length == 0 ? 1 : list.length;
		}

		private function get menuRooms():Array
		{
			return meta == null ? null : meta.menu_rooms as Array;
		}

		/** `Game.as:908`'s `level == 45` — the snow gradient, as a room flag. */
		public function hasSnowGradient(index:int):Boolean
		{
			return roomFlag(index, "snow_gradient");
		}

		/**
		 * `Game.as:1175`/`:1181`'s `level != 10` — this room is exempt from
		 * BOTH sword/shield music overrides. Note the polarity flip: the
		 * literal was an exemption written as an inequality, and the flag says
		 * what it means.
		 */
		public function isMusicExempt(index:int):Boolean
		{
			return roomFlag(index, "music_override_exempt");
		}

		private function roomFlag(index:int, flag:String):Boolean
		{
			if (index < 0 || index >= rooms.length)
				return false;
			var room:Object = rooms[index];
			return room != null && room[flag] == true;
		}

		/**
		 * The six CODE-BUILT room references (`named_rooms`, plan §8.2a) — the
		 * ones no bundle rewrite can reach, because they are constructed in
		 * ActionScript rather than read out of an .oel.
		 *
		 * ⛔ A MISSING NAME RETURNS THE SET'S START ROOM, LOUDLY. The sender's
		 * validator requires all six and refuses a set missing one, so this
		 * branch is unreachable through a delivered set; if it is ever
		 * reached, a silent 0 would put the player in a real room that is not
		 * the right one — the failure this arc keeps catching. It is named in
		 * `Game.levelSetError` instead.
		 */
		public function namedLevel(name:String):int
		{
			var ref:Object = namedRoom(name);
			if (ref == null)
			{
				Game.levelSetError = "named_rooms is missing \"" + name + "\"";
				return startLevel;
			}
			return int(ref.level);
		}

		/** Arrival x for a named warp; the `Game` constructor's 80 if absent. */
		public function namedX(name:String):int
		{
			var ref:Object = namedRoom(name);
			return ref == null || ref.x == null ? 80 : int(ref.x);
		}

		/** Arrival y for a named warp; the `Game` constructor's 128 if absent. */
		public function namedY(name:String):int
		{
			var ref:Object = namedRoom(name);
			return ref == null || ref.y == null ? 128 : int(ref.y);
		}

		private function namedRoom(name:String):Object
		{
			if (meta == null || meta.named_rooms == null)
				return null;
			return meta.named_rooms[name];
		}

		// ─────────────────────────────────────────────────────────────────
		// PHASE 4 — the save belongs to a SET, and the persistence table is
		// that set's size (plan §4.2).
		// ─────────────────────────────────────────────────────────────────

		/**
		 * Decide what the save on disk means now that THIS set is real, and
		 * make the persistence table match it.
		 *
		 * ⛔ WHY THE CONSTRUCTOR, beside `seedRuntimeTables` and for the same
		 * reason: a set becomes real exactly once, here, whether it arrived
		 * over ExternalInterface or was built from the embeds. Reconciling
		 * here is exactly-once per set BY CONSTRUCTION, so a mount that
		 * forgot to reconcile cannot exist. Two call sites could disagree;
		 * one cannot.
		 *
		 * ⛔ WHAT A MISMATCH COSTS IF IT IS NOT CAUGHT: the save carries
		 * `level`, `playerPositionX/Y`, ~28 inventory booleans and the
		 * persistence table, and every one of them is SET-RELATIVE. Load a
		 * save from set A under set B and the player resumes at an index that
		 * means a different room, with a table whose rows describe entities
		 * that are not there. Nothing errors; it quietly means something
		 * else. So a mismatch takes the WHOLE save, not just the table.
		 *
		 * ⛓ THE COMPARISON IS `set_id`, AND THAT IS THE CONTENT HASH. The
		 * sender stamps every set as `<base>-<FNV-1a of the canonical
		 * document>` and refuses one whose id does not end in its own hash
		 * (plan §9.1 rule 2), so an EDITED set reusing its name is already a
		 * different `set_id` by construction. This build does not recompute
		 * the hash — that would be two implementations of one identity, the
		 * one place a divergence is invisible — it relies on the rule the
		 * sender owns (§10.2's split), and cross-checks the SIZE below, which
		 * it can see for itself.
		 */
		private function reconcileSave():void
		{
			// A set can be built before the save is open (a unit-style call,
			// or a future caller). Nothing to reconcile against; the boot path
			// opens SAVE_FILE before it ever asks for a set.
			if (Main.SAVE_FILE == null)
				return;

			var want:int = rooms.length * Game.tagsPerLevel;
			var table:Array = Main.SAVE_FILE.data.levelPersistence as Array;
			var have:int = table == null ? -1 : table.length;
			var savedId:String = Main.levelSetOnSave;

			if (savedId == "" && table == null)
			{
				// ⛓ NO SAVE AT ALL IS NOT A RESET, and saying so matters. This
				// is every first boot; reporting it as a discarded save would
				// put a reason string in the readout on every single launch,
				// and a field that cries wolf on the healthy path is a field
				// the next reader learns to skip. `levelSetReset` means
				// something WAS thrown away.
				Main.buildLevelPersistence(rooms.length);
				Main.levelSetOnSave = setId;
				return;
			}

			if (savedId == null || savedId == "")
			{
				// ⛓ AN UNSTAMPED SAVE IS ADOPTED, NOT DESTROYED — but only on
				// the evidence of its own size. Every save written before this
				// phase was written under the compiled-in 116 rooms, because
				// no earlier build could size the table any other way, so a
				// table that fits the set being mounted IS that set's table.
				// One that does not fit says the save came from somewhere this
				// build cannot identify, and the safe reading of an
				// unidentifiable save is that it is not ours.
				if (have == want)
				{
					Main.levelSetOnSave = setId;
					return;
				}
				Main.freshSaveForLevelSet(setId, rooms.length,
					"an unstamped save whose table holds " + levelsIn(have)
					+ " level(s), but \"" + setId + "\" has " + rooms.length);
				return;
			}

			if (savedId == setId)
			{
				if (have == want)
					return;                      // the ordinary path: keep it all

				// ⛔ THE STAMP MATCHES AND THE SIZE DOES NOT, so one of them is
				// lying. `set_id` is content-derived, so a set with this id
				// cannot have a different room count — which means this
				// delivery is not what its id claims (a hand-rolled envelope
				// that never went through the sender), or the table was
				// truncated under us. ⛓ THE PLAN CALLED FOR EXTENDING THE
				// TABLE WITH `true` HERE. That would paper over the only
				// evidence of the disagreement, so it NAMES it instead and
				// rebuilds — the whole point of §4.2 is that a set mismatch
				// must never be quietly reinterpreted, and a stamp that
				// matches wrongly is still a mismatch.
				Main.freshSaveForLevelSet(setId, rooms.length,
					"save stamp \"" + savedId + "\" matches, but its table holds "
					+ levelsIn(have) + " level(s) and this set has " + rooms.length
					+ " — the id is content-derived, so it cannot describe both");
				return;
			}

			Main.freshSaveForLevelSet(setId, rooms.length,
				"the save was written under \"" + savedId + "\" and this is \""
				+ setId + "\" — level, position, inventory and every persistence "
				+ "row are set-relative, so none of them carries over");
		}

		/** Whole levels a table of `n` booleans addresses; -1 for no table. */
		private static function levelsIn(n:int):int
		{
			return n < 0 ? -1 : int(n / Game.tagsPerLevel);
		}
	}
}
