package Pickups 
{
	import flash.geom.Point;
	import net.flashpunk.graphics.Spritemap;
	import net.flashpunk.FP;
	import Scenery.Tile;
	/**
	 * ...
	 * @author Time
	 */
	public class BossTotemPart extends Pickup
	{
		[Embed(source = "../../assets/graphics/BossTotemParts.png")] private var imgBossTotemPart:Class;
		private var sprBossTotemPart:Spritemap = new Spritemap(imgBossTotemPart, 24, 24);
		
		private var totemPart:int;
		private var doActions:Boolean = true;
		
		/** P4E (C4): the persistence tag the host bound, -1 for vanilla. */
		private var tag:int = -1;
		
		public function BossTotemPart(_x:int, _y:int, _t:int, _tag:int=-1) 
		{
			tag = _tag;
			super(_x + Tile.w/2, _y + Tile.h/2, sprBossTotemPart, new Point(), false);
			sprBossTotemPart.frame = _t;
			sprBossTotemPart.centerOO();
			setHitbox(16, 16, 8, 8);
			totemPart = _t;
			layer = -(y - originY + height);
			
			special = true;
		}
		
		override public function check():void
		{
			super.check();
			if (Player.hasTotemPart(totemPart))
			{
				doActions = false;
				FP.world.remove(this);
			}
		}
		
		override public function removed():void
		{
			if (doActions)
			{
				Player.hasTotemPartSet(totemPart, true);
				// P4E (C4): the check report's choke point (`Game.pendingCheck`).
				if (tag >= 0) Game.setPersistence(tag, false);
			}
		}
	}

}