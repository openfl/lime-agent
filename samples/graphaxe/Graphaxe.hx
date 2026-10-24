package;

import gx.build.Project;
import gx.build.ProjectSpec;
import gx.build.ProjectSpec.LibrarySpec;
import gx.utils.ScaleMode;
import gx.utils.StageAlign;

/** Built with `haxelib run graphaxe build windows`. lime-agent comes from its haxelib: `haxelib dev lime-agent` this checkout first. */
class Graphaxe {
	public static final project:ProjectSpec = Project
		.named("Main")
		.source("src")
		.library(LibrarySpec.haxelib("lime-agent"))
		.identity("LimeAgentGraphaxe", "Lime Agent Graphaxe Sample")
		.window(function(window) {
			window.size(640, 400);
			window.background(0x26262E);
		})
		.graphaxe(function(runtime) {
			runtime.size(640, 400);
			runtime.scaleMode(ScaleMode.SHOW_ALL);
			runtime.stageAlign(StageAlign.TOP_LEFT);
		})
		.assetCatalog(function(catalog) {
			catalog.packageName("limeagentgraphaxe.assets");
		})
		.done();
}
