package
{
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

		/** The mounted set, or null = the built-in `Game.levels` embeds. */
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
		public static function acceptChunk(chunk:Object, maxRooms:int = -1):String
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
			// ⛔ A SET BIGGER THAN THE PERSISTENCE TABLE IS REFUSED, because the
			// table is still sized from the compiled-in `Game.levels.length`
			// (`Main.as:319`) until plan phase 4 lands. Rows past its end read
			// as *every tag already cleared* and the game reports itself
			// healthy — §8.3 drove exactly that at levels 116 and 200. The
			// caller passes the capacity it measured; -1 means unbounded and
			// is for tests that are not about persistence.
			if (maxRooms >= 0 && assembled.length > maxRooms)
			{
				var tooMany:int = assembled.length;
				resetStaging();
				return "error:set has " + tooMany + " rooms but the persistence"
					+ " table addresses " + maxRooms + " (plan phase 4 lifts this)";
			}
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
	}
}
