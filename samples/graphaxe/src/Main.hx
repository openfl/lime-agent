package;

import gx.display.Quad;
import gx.display.Sprite;
import gx.events.Event;
import gx.events.PointerEvent;
import gx.events.PointerPhase;
import gx.text.TextField;
import gx.text.TextFormat;
import gx.ui.Button;
import gx.utils.Align;
#if lime_agent
import limeagent.LimeAgent;
#end

/**
	A Graphaxe scene drawn the way a game draws one: cards made of quads and text, a pile to drop them on,
	one card partly under another, a decoration that lets clicks through, a hidden object and a button.
	Cards can be dragged; one dropped over the pile snaps onto it.
**/
class Main extends Sprite {
	public static inline var PILE_X = 480;
	public static inline var PILE_Y = 40;

	var cards:Array<Card> = [];
	var pile:Quad;

	public function new() {
		super();
		addEventListener(Event.ADDED_TO_STAGE, onAddedToStage);
		#if lime_agent
		LimeAgent.label = object -> Std.isOfType(object, Card) ? (cast object : Card).label : null;
		LimeAgent.addInfo("cards", () -> [for (card in cards) {name: card.name, label: card.label, x: card.x, y: card.y}]);
		#end
	}

	function onAddedToStage(_):Void {
		removeEventListener(Event.ADDED_TO_STAGE, onAddedToStage);
		addChild(new Quad(640, 400, 0x26262E));

		pile = new Quad(100, 130, 0x335533);
		pile.name = "pile";
		pile.x = PILE_X;
		pile.y = PILE_Y;
		addChild(pile);

		// The king lies over most of the ace, whose top edge stays visible.
		card("card AS", null, "A", 0xF0F0F0, 60, 60);
		card("card KH", null, "K", 0xCC2222, 80, 90);
		card(null, "queen", "Q", 0x2244CC, 240, 60);

		var shine = new Quad(24, 24, 0xFFFFFF);
		shine.name = "shine";
		shine.alpha = 0.3;
		shine.interactive = false;
		shine.x = 250;
		shine.y = 70;
		addChild(shine);

		var secret = new Quad(50, 50, 0xFF00FF);
		secret.name = "secret";
		secret.visible = false;
		addChild(secret);

		var reset = new Button("Reset");
		reset.name = "reset";
		reset.setSize(120, 36);
		reset.x = 480;
		reset.y = 320;
		reset.addEventListener(Event.TRIGGERED, _ -> {
			for (card in cards) card.home();
			trace("reset");
		});
		addChild(reset);
	}

	function card(label:Null<String>, name:Null<String>, rank:String, color:Int, x:Float, y:Float):Void {
		var card = new Card(label, rank, color, x, y);
		if (name != null) card.name = name;
		card.addEventListener(PointerEvent.POINTER, event -> drag(card, cast event));
		cards.push(card);
		addChild(card);
	}

	var grabX = 0.0;
	var grabY = 0.0;

	function drag(card:Card, event:PointerEvent):Void {
		var pointer = event.getPointer(card);
		if (pointer == null) return;
		switch pointer.phase {
			case PointerPhase.BEGAN:
				grabX = pointer.globalX - card.x;
				grabY = pointer.globalY - card.y;
			case PointerPhase.MOVED:
				card.x = pointer.globalX - grabX;
				card.y = pointer.globalY - grabY;
			case PointerPhase.ENDED:
				card.x = pointer.globalX - grabX;
				card.y = pointer.globalY - grabY;
				var cx = card.x + Card.WIDTH / 2, cy = card.y + Card.HEIGHT / 2;
				if (cx >= pile.x && cx < pile.x + pile.width && cy >= pile.y && cy < pile.y + pile.height) {
					card.x = PILE_X + 10;
					card.y = PILE_Y + 10;
					trace('${card.label != null ? card.label : card.name} on the pile');
				}
			default:
		}
	}
}

/** A playing card: a coloured quad with its rank. The class name and label are what lime-agent's tree shows. */
class Card extends Sprite {
	public static inline var WIDTH = 80;
	public static inline var HEIGHT = 110;

	public var label(default, null):Null<String>;

	var startX:Float;
	var startY:Float;

	public function new(label:Null<String>, rank:String, color:Int, x:Float, y:Float) {
		super();
		this.label = label;
		startX = x;
		startY = y;
		addChild(new Quad(WIDTH, HEIGHT, color));
		var text = new TextField(30, 24, rank, new TextFormat("", 18, 0x101010, Align.LEFT, Align.TOP));
		text.x = 6;
		text.y = 4;
		addChild(text);
		home();
	}

	public function home():Void {
		x = startX;
		y = startY;
	}
}
