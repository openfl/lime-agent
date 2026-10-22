package;

import feathers.controls.Application;
import feathers.controls.Button;
import feathers.controls.Label;
import feathers.controls.TextInput;
import feathers.events.TriggerEvent;
import feathers.layout.VerticalLayout;

/** A Feathers UI form, to check the OpenFL and Feathers adapters: tree, masking, clicks, typing and an uncaught error. */
class Main extends Application {
	public function new() {
		super();
		var layout = new VerticalLayout();
		layout.gap = 12;
		layout.setPadding(24);
		this.layout = layout;

		var title = new Label("Feathers sample");
		var name = new TextInput();
		name.name = "name";
		name.prompt = "Your name";
		var password = new TextInput();
		password.name = "password";
		password.displayAsPassword = true;
		password.text = "hunter2";
		var status = new Label("Not saved");
		status.name = "status";
		var save = new Button("Save");
		save.name = "save";
		save.addEventListener(TriggerEvent.TRIGGER, _ -> {
			status.text = 'Saved ${name.text}';
			trace(status.text);
		});
		var crash = new Button("Crash");
		crash.name = "crash";
		crash.addEventListener(TriggerEvent.TRIGGER, _ -> throw "feathers crash");
		for (control in [title, name, password, save, status, crash]) addChild(control);
	}
}
