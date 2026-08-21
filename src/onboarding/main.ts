import { mount } from "svelte";
import { applyPlatformClass, loadPlatformInfo } from "../shared/platform";
import "../shared/tokens.css";
import App from "./App.svelte";

void loadPlatformInfo().then(applyPlatformClass);

const app = mount(App, {
  target: document.getElementById("app")!,
});

export default app;
