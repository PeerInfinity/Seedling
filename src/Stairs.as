package  
{
	import flash.geom.Point;
	import net.flashpunk.Entity;
	import net.flashpunk.FP;
	import net.flashpunk.graphics.Spritemap;
	/**
	 * ...
	 * @author Time
	 */
	public class Stairs extends Teleporter
	{
		[Embed(source = "../assets/graphics/Stairs.png")] private var imgStairs:Class;
		private var sprStairs:Spritemap = new Spritemap(imgStairs, 16, 16);
		
		private var up:Boolean;
		
		public function Stairs(_x:int, _y:int, _up:Boolean=true, _flip:Boolean=false, _to:int=0, _px:int=0, _py:int=0, _sign:int=0) 
		{
			super(_x, _y, _to, _px, _py, true, -1, false, _sign);
			up = _up;
			// ⛓ M1: so the host's rebuilt exit id (`out_<type>_<x>_<y>`) says
			// which of the three LINK_TAGS this door is. The report itself is
			// inherited — Stairs.update() is super.update().
			exitType = _up ? "stairsup" : "stairsdown";
			graphic = sprStairs;
			sprStairs.frame = int(!up);
			if (up)
				soundIndex = 1;
			else
				soundIndex = 2;
			sprStairs.originX = sprStairs.width / 2;
			
			if (_flip)
			{
				sprStairs.scaleX = -1;
			}
			renderLight = false;
		}
		
		override public function update():void
		{
			super.update();
			if (!isNaN(originY) && !isNaN(height))
			{
				layer = -y;
			}
		}
	}

}