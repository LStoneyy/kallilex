// Safari JavaScript preprocessor for the Kallilex Share Extension (ios-09,
// PLAN.md §8.1/§8.2). Registered via NSExtensionJavaScriptPreprocessingFile
// in Info.plist. Standard ExtensionPreprocessingJS object pattern: Safari
// calls `run()` with a completion function that must receive a
// JSON-serializable object back on `completionFunction`. `InputExtractor`
// reads this under NSExtensionJavaScriptPreprocessingResultsKey.
var ExtensionPreprocessingJS = {
	run: function(arguments) {
		arguments.completionFunction({
			selection: window.getSelection().toString(),
			title: document.title,
			url: document.URL
		});
	}
};
