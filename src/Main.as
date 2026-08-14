package 
{
	import com.newgrounds.*;
	import com.newgrounds.components.MedalPopup;
	import flash.display.DisplayObject;
	import flash.events.Event;
	import flash.geom.Point;
	import flash.media.SoundTransform;
	import flash.net.SharedObject;
	import net.flashpunk.Engine;
	import net.flashpunk.FP;
	
	/**
	 * ...
	 * @author Time
	 */
	public class Main extends Engine 
	{
		public static const SAVE_NAME:String = "shrumsave";
		public static var SAVE_FILE:SharedObject;
		public static var tempPersistence:Array;
		public static const badges:Object = ["The Quest", "Sardol", "Mower", "Lighting the Path",
											 "Health", "Fall of Time", "Fall of the Totem", "Fall of the Tentacled Beast",
											 "Fall of the Shieldspire", "Fall of the Owl", "Fall of the Lights", "Fall of the King of Fire",
											 "Enchantments", "Bloody", "Bloodless"];
		
		public static const FPS:int = 60;
		
		public static var medals:Vector.<MedalPopup> = new Vector.<MedalPopup>();
		
		private static var READY_TO_SUBMIT_BADGES:Boolean = false;
		private static var SUBMITTED_BADGES:Boolean = false;
		
		public function Main():void 
		{
			super(160, 160, FPS);
			begin();
		}
		
		public static function begin():void
		{
			//if (Preloader.CONNORULLMANN || Preloader.NEWGROUNDS)
			//{
			SAVE_FILE = SharedObject.getLocal(SAVE_NAME);
			startSave();
			printItems();
			
			Music.begin();
			
			Game.menu = false;  // TELEPORT: skip title/"press any key" -> straight into play
			FP.world = new Game(0, 80, 128);// TELEPORT: skip splashes -> OverWorld1 @ start. Was: new Splash();
			
			FP.screen.color = 0x000000;
			FP.screen.scale = 3;
			
			var popup:MedalPopup = new MedalPopup();
			FP.engine.addChild(popup);
			//}
		}
		
		override public function update():void
		{
			// BOT: drive the tape before entities update. This must stay
			// ABOVE super.update() — Input.update() clears the edge queues
			// at the end of the previous frame, so an event dispatched here
			// is live for exactly this frame and self-clears.
			Bot.update();
			super.update();
			Music.update();
			
			if (READY_TO_SUBMIT_BADGES && QuickKong.LOADED && !SUBMITTED_BADGES)
			{
				for (var i:int = 0; i < Main.badges.length; i++)
				{
					if (Main.hasBadge(Main.badges[i]))
					{
						Main.unlockMedal(Main.badges[i]);
					}
					else
					{
						QuickKong.stats.submit(Main.badges[i], 0);
					}
				}
				SUBMITTED_BADGES = true;
			}
		}
		
		public static function printItems():void
		{
			var i:int;
			trace("-------------------------");
			trace("P-Pos:    " + playerPositionX + ", " + playerPositionY);
			trace("Level:    " + level);
			trace("Item <X>: " + primary);
			trace("Item <C>: " + secondary);
			trace("Grass cut:" + grassCut);
			
			/*trace("Sword:    " + hasSword);
			trace("G-Sword:  " + hasGhostSword);
			trace("Shield:   " + hasShield);
			trace("Fire:     " + hasFire);
			trace("Wand:     " + hasWand);
			trace("Fire Wand:" + hasFireWand);
			trace("Swim:     " + canSwim);
			trace("Spear:    " + hasSpear);
			trace("D-Shield: " + hasDarkShield);
			trace("D-Suit:   " + hasDarkSuit);
			trace("D-Sword:  " + hasDarkSword);
			trace("Feather:  " + hasFeather);
			trace("Torch:    " + hasTorch);
			trace("Beam:     " + beam);
			trace("Rock Set: " + rockSet);
			trace("Hits Max: " + hitsMax);
			trace("First Use:" + firstUse); //Inventory first used
			trace("Extended: " + extended); //Inventory all the way out
			
			trace("Totem Parts:");
			for (i = 0; i < SAVE_FILE.data.hasTotemPart.length; i++)
			{
				trace(i + ": " + hasTotemPart(i));
			}
			trace("Keys:");
			for (i = 0; i < SAVE_FILE.data.hasKey.length; i++)
			{
				trace(i + ": " + hasKey(i));
			}
			for (i = 0; i < SAVE_FILE.data.hasSealPart.length; i++)
			{
				trace(i + ": " + hasSealPart(i));
			}
			*/
			var s:String = "";
			for (i = 0; i < Game.tagsPerLevel; i++)
			{
				s += String(int(levelPersistence(Math.max(level, 0), i)));
			}
			trace(level + ": " + s);
		}
		
		public static function get hasSword():Boolean { return SAVE_FILE.data.hasSword; }
		public static function get hasGhostSword():Boolean { return SAVE_FILE.data.hasGhostSword; }
		public static function get hasShield():Boolean {return SAVE_FILE.data.hasShield; }
		public static function get hasFire():Boolean {return SAVE_FILE.data.hasFire; }
		public static function get hasWand():Boolean { return SAVE_FILE.data.hasWand; }
		public static function get hasFireWand():Boolean {return SAVE_FILE.data.hasFireWand; }
		public static function get canSwim():Boolean {return SAVE_FILE.data.canSwim; }
		public static function get hasSpear():Boolean {return SAVE_FILE.data.hasSpear; }
		public static function get hasDarkShield():Boolean {return SAVE_FILE.data.hasDarkShield; }
		public static function get hasDarkSuit():Boolean {return SAVE_FILE.data.hasDarkSuit; }
		public static function get hasDarkSword():Boolean {return SAVE_FILE.data.hasDarkSword; }
		public static function get hasFeather():Boolean { return SAVE_FILE.data.hasFeather; }
		public static function get hasTorch():Boolean { return SAVE_FILE.data.hasTorch; }
		public static function get beam():Boolean { return SAVE_FILE.data.beam; }
		public static function get rockSet():Boolean { return SAVE_FILE.data.rockSet; }
		public static function get hitsMax():int { if (!SAVE_FILE.data.hitsMax) return Player.hitsMaxDef; return SAVE_FILE.data.hitsMax; }
		public static function get firstUse():Boolean { return SAVE_FILE.data.firstUse; }
		public static function get extended():Boolean { return SAVE_FILE.data.extended; }
		public static function get time():Number { if (!SAVE_FILE.data.time) return Game.dayLength / 2; return SAVE_FILE.data.time; }
		public static function get primary():int { if (!SAVE_FILE.data.primary) return 0; return SAVE_FILE.data.primary; }
		public static function get secondary():int { if (!SAVE_FILE.data.secondary) return 0; return SAVE_FILE.data.secondary; }
		public static function get grassCut():int { if (!SAVE_FILE.data.grassCut) return 0; return SAVE_FILE.data.grassCut; }
		public static function hasKey(i:int):Boolean {return SAVE_FILE.data.hasKey[i]; }
		public static function hasTotemPart(i:int):Boolean { return SAVE_FILE.data.hasTotemPart[i]; }
		public static function hasSealPart(i:int):int { return SAVE_FILE.data.hasSealPart[i]; }
		public static function hasBadge(s:String):Boolean { return SAVE_FILE.data.hasBadge[s]; }
		
		public static function set hasSword(_t:Boolean):void { SAVE_FILE.data.hasSword = _t; }
		public static function set hasGhostSword(_t:Boolean):void { SAVE_FILE.data.hasGhostSword = _t; }
		public static function set hasShield(_t:Boolean):void { SAVE_FILE.data.hasShield = _t; }
		public static function set hasFire(_t:Boolean):void { SAVE_FILE.data.hasFire = _t; }
		public static function set hasWand(_t:Boolean):void { SAVE_FILE.data.hasWand = _t; }
		public static function set hasFireWand(_t:Boolean):void { SAVE_FILE.data.hasFireWand = _t; }
		public static function set canSwim(_t:Boolean):void { SAVE_FILE.data.canSwim = _t; }
		public static function set hasSpear(_t:Boolean):void { SAVE_FILE.data.hasSpear = _t; }
		public static function set hasDarkShield(_t:Boolean):void { SAVE_FILE.data.hasDarkShield = _t; }
		public static function set hasDarkSuit(_t:Boolean):void { SAVE_FILE.data.hasDarkSuit = _t; }
		public static function set hasDarkSword(_t:Boolean):void { SAVE_FILE.data.hasDarkSword = _t; }
		public static function set hasFeather(_t:Boolean):void { SAVE_FILE.data.hasFeather = _t; }
		public static function set hasTorch(_t:Boolean):void { SAVE_FILE.data.hasTorch = _t; }
		public static function set beam(_t:Boolean):void { SAVE_FILE.data.beam = _t; }
		public static function set rockSet(_t:Boolean):void { SAVE_FILE.data.rockSet = _t; }
		public static function set hitsMax(_t:int):void { SAVE_FILE.data.hitsMax = _t; }
		public static function set firstUse(_t:Boolean):void { SAVE_FILE.data.firstUse = _t; }
		public static function set extended(_t:Boolean):void { SAVE_FILE.data.extended = _t; }
		public static function set time(_t:Number):void { SAVE_FILE.data.time = _t; }
		public static function set primary(_t:int):void { SAVE_FILE.data.primary = _t; }
		public static function set secondary(_t:int):void { SAVE_FILE.data.secondary = _t; }
		public static function set grassCut(_t:int):void { SAVE_FILE.data.grassCut = _t; if (SAVE_FILE.data.grassCut >= 10000) unlockMedal(Main.badges[2]); }
		public static function hasKeySet(i:int, _t:Boolean):void { SAVE_FILE.data.hasKey[i] = _t;}
		public static function hasTotemPartSet(i:int, _t:Boolean):void { SAVE_FILE.data.hasTotemPart[i] = _t; }
		public static function hasSealPartSet(i:int, _t:int):void { SAVE_FILE.data.hasSealPart[i] = _t; }
		public static function hasBadgeSet(s:String, _t:Boolean):void { SAVE_FILE.data.hasBadge[s] = _t; }
		
		public static function get playerPositionX():int  { if (!SAVE_FILE.data.playerPositionX) return 0; return SAVE_FILE.data.playerPositionX; }
		public static function get playerPositionY():int  { if (!SAVE_FILE.data.playerPositionY) return 0; return SAVE_FILE.data.playerPositionY; }
		public static function set playerPositionX(i:int):void  { SAVE_FILE.data.playerPositionX = i; }
		public static function set playerPositionY(i:int):void  { SAVE_FILE.data.playerPositionY = i; }
		public static function get level():int  { if (SAVE_FILE.data.level == null) return -1; return SAVE_FILE.data.level; }
		public static function set level(i:int):void  { SAVE_FILE.data.level = i; }
		
		public static function levelPersistence(i:int, j:int):Boolean { return SAVE_FILE.data.levelPersistence[i*Game.tagsPerLevel+j]; }
		public static function levelPersistenceSet(i:int, j:int, _t:Boolean):void { SAVE_FILE.data.levelPersistence[i*Game.tagsPerLevel+j] = _t;}
		
		public static function clearSave():void
		{
			SAVE_FILE.clear();
			Inventory.clearItems();
			begin();
		}
		
		public static function unlockMedal(medal:String):void
		{
			if (Preloader.ARMORGAMES)
				return;
			if (Preloader.KONGREGATE)
			{
				QuickKong.stats.submit(medal, 1);
				hasBadgeSet(medal, true);
				return;
			}
			var m:Medal = API.getMedal(medal);
			if (!m || (m && m.unlocked))
				return;
			m.unlock();
		}
		
		/*
		 * Initializes all of the save values to whatever they're saved to be--if null, then it turns to false.
		 */
		public static function startSave():void
		{
			insideStartSave = true; LevelSet.active(); hasSword = hasSword;
			hasGhostSword = hasGhostSword;
			hasShield = hasShield;
			hasFire = hasFire;
			hasWand = hasWand;
			hasFireWand = hasFireWand;
			canSwim = canSwim;
			hasSpear = hasSpear;
			hasDarkShield = hasDarkShield;
			hasDarkSuit = hasDarkSuit;
			hasDarkSword = hasDarkSword;
			hasFeather = hasFeather;
			hasTorch = hasTorch;
			beam = beam;
			rockSet = rockSet;
			hitsMax = hitsMax;
			firstUse = firstUse;
			extended = extended;
			time = time;
			primary = primary;
			secondary = secondary;
			grassCut = grassCut;
			
			if (!SAVE_FILE.data.hasBadge)
			{
				var _hasBadge:Object = new Object;
				for (var i:int = 0; i < badges.length; i++)
				{
					_hasBadge[badges[i]] = false;
				}
				SAVE_FILE.data.hasBadge = _hasBadge;				
			}
			else
			{
				for (i = 0; i < badges.length; i++)
				{
					hasBadgeSet(badges[i], hasBadge(badges[i]));
				}
			}
			if (!SAVE_FILE.data.hasKey)
			{
				var _hasKey:Array = new Array();
				for (i = 0; i < Player.totalKeys; i++)
				{
					_hasKey[i] = false;
				}
				SAVE_FILE.data.hasKey = _hasKey;
			}
			else
			{
				for (i = 0; i < Player.totalKeys; i++)
				{
					hasKeySet(i, hasKey(i));
				}
			}
			if (!SAVE_FILE.data.hasTotemPart)
			{
				var _hasTotemPart:Array = new Array();
				for (i = 0; i < Player.totemParts; i++)
				{
					_hasTotemPart[i] = false;
				}
				SAVE_FILE.data.hasTotemPart = _hasTotemPart;
			}
			else
			{
				for (i = 0; i < Player.totemParts; i++)
				{
					hasTotemPartSet(i, hasTotemPart(i));
				}
			}
			if (!SAVE_FILE.data.hasSealPart)
			{
				var _hasSealPart:Array = new Array();
				for (i = 0; i < SealController.SEALS; i++)
				{
					_hasSealPart[i] = -1;
				}
				SAVE_FILE.data.hasSealPart = _hasSealPart;
			}
			else
			{
				for (i = 0; i < SealController.SEALS; i++)
				{
					hasSealPartSet(i, hasSealPart(i));
				}
			}
			/* ⛓ THE PERSISTENCE TABLE MOVED, and it is built EARLIER than this
			 * line now — see `LevelSet.reconcileSave` (plan §4.2). It used to
			 * be `Game.levels.length * tagsPerLevel` booleans created here iff
			 * absent, which sized the save to the COMPILED-IN room count and
			 * could never notice that the save belonged to a different set.
			 *   ⛔ It cannot be built from here any more: a mounted set is the
			 * authority for the length, the save has to be judged against that
			 * set BEFORE the fields above are re-read, and `printItems()` — the
			 * next thing `begin()` calls — already reads the table. So the
			 * FIRST statement here asks for the active set, whose constructor
			 * reconciles; the last drops the re-entry guard that lets a wipe
			 * re-enter this from a runtime mount. Both ride on EXISTING lines:
			 * §4.5's property is ZERO SHIFT, and this file is cited 88 times. */
			
			playerPositionX = playerPositionX;
			playerPositionY = playerPositionY;
			level = level;
			
			READY_TO_SUBMIT_BADGES = true; insideStartSave = false;
		}

		// ─────────────────────────────────────────────────────────────────
		// PHASE 4 — the save belongs to a LEVEL SET (plan §4.2).
		//
		// ⛔ APPENDED AT THE END OF THE CLASS, deliberately. §4.5's property
		// is ZERO SHIFT, not "new fields at the end of the declaration block"
		// — this file is cited by line 88 times in the model, and putting
		// these beside their neighbours at :20 would invalidate every one of
		// those citations exactly as silently as a re-flow would (the reading
		// phase 3 had to correct, plan §10.1).
		// ─────────────────────────────────────────────────────────────────

		/**
		 * The set the save on disk was written under, or "" if it predates
		 * this phase. `set_id` ENDS WITH the content hash of the set document
		 * (plan §9.1 rule 2), so this one string carries both halves of the
		 * stamp §4.2 asks for: an edited set reusing its name is already a
		 * different id, by the sender's construction.
		 */
		public static function get levelSetOnSave():String
		{
			if (SAVE_FILE == null || SAVE_FILE.data.levelSetId == null) return "";
			return String(SAVE_FILE.data.levelSetId);
		}
		public static function set levelSetOnSave(s:String):void { SAVE_FILE.data.levelSetId = s; }

		/**
		 * Why the save was last thrown away, or "" if it never was.
		 *
		 * ⛔ ITS OWN FIELD, NOT `Game.levelSetError`. That one means "a
		 * delivery was REFUSED", and the transport probe reads it as exactly
		 * that. A reset is the opposite — the delivery was accepted and the
		 * save could not come with it — so borrowing that channel would make a
		 * healthy mount read as a refusal and would disarm the gate that
		 * checks refusals. Two outcomes, two channels.
		 */
		public static var levelSetReset:String = "";

		/**
		 * ⛔ Re-entry guard. A runtime mount reconciles from inside
		 * `LevelSet`'s constructor and may wipe the save, which then needs
		 * `startSave()` to re-initialise every field. On the BOOT path that
		 * same constructor runs from inside `startSave()` itself, and calling
		 * it again there would recurse forever.
		 */
		private static var insideStartSave:Boolean = false;

		/** `levelCount * tagsPerLevel` booleans, all true = nothing cleared. */
		public static function buildLevelPersistence(levelCount:int):void
		{
			var table:Array = new Array();
			for (var i:int = 0; i < levelCount * Game.tagsPerLevel; i++)
				table.push(true);
			SAVE_FILE.data.levelPersistence = table;
		}

		/**
		 * Throw the save away and start a fresh one belonging to `setId`.
		 *
		 * ⛔ THE WHOLE SAVE, NOT THE TABLE. `level` and `playerPositionX/Y`
		 * are as set-relative as any persistence row — resuming at index 37 of
		 * a set that never had a room 37, or at (240, 256) in a room whose
		 * geometry is different, is the same silent reinterpretation §4.2
		 * exists to prevent, and the plan's rule named only the table.
		 */
		public static function freshSaveForLevelSet(setId:String, levelCount:int, reason:String):void
		{
			SAVE_FILE.clear();
			// ⚠ RE-OPENED, following `begin()`'s own precedent: the original
			// `clearSave()` calls `clear()` and then goes back through
			// `SharedObject.getLocal`, so nothing here assumes `data` is still
			// a usable object afterwards. Cheap, and the alternative is trusting
			// an emulated SharedObject to behave like the spec.
			SAVE_FILE = SharedObject.getLocal(SAVE_NAME);
			Inventory.clearItems();
			buildLevelPersistence(levelCount);
			levelSetOnSave = setId;
			levelSetReset = reason;
			trace("LEVEL SET RESET: " + reason);
			// Every other field is re-read by `startSave`, which is already
			// running when this is the boot path (see the guard above).
			if (!insideStartSave)
				startSave();
		}

		/** Levels the persistence table addresses; 0 when there is no table. */
		public static function levelPersistenceLevels():int
		{
			if (SAVE_FILE == null) return 0;
			var table:Array = SAVE_FILE.data.levelPersistence as Array;
			if (table == null) return 0;
			return int(table.length / Game.tagsPerLevel);
		}

		/** Raw booleans in the table; -1 when there is none. */
		public static function persistenceTableLength():int
		{
			if (SAVE_FILE == null) return -1;
			var table:Array = SAVE_FILE.data.levelPersistence as Array;
			return table == null ? -1 : table.length;
		}

		/**
		 * Every CLEARED slot, "level:tag" each — the readout the phase 4 gate
		 * diffs (`Bot.botLevelSet`).
		 *
		 * ⛓ THE FALSE ENTRIES, not the true ones, because the polarity makes
		 * that the short list AND the meaningful one: `true` is the default a
		 * fresh table is full of, and every `false` is an entity the game will
		 * refuse to spawn. A fresh table reports [].
		 */
		public static function persistenceClearedList():Array
		{
			var out:Array = new Array();
			if (SAVE_FILE == null) return out;
			var table:Array = SAVE_FILE.data.levelPersistence as Array;
			if (table == null) return out;
			for (var i:int = 0; i < table.length; i++)
			{
				if (!table[i])
					out.push(int(i / Game.tagsPerLevel) + ":" + (i % Game.tagsPerLevel));
			}
			return out;
		}
	}
	
}