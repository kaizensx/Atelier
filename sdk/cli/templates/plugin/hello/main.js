// A widget that shows the time and how often you said hello, and a command that says hello.
// Add the widget on the board with the Plugin widget kind; the command is in the Command palette.

let count = atelier.storage.get("count", 0);

const clock = atelier.widget({
  id: "hello",
  title: "Hello",
  refresh: 60,
  view: () => atelier.ui.vstack([
    atelier.ui.text("Hello", { size: 22, weight: "bold" }),
    atelier.ui.text(new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }), { color: "secondary" }),
    atelier.ui.text(count === 1 ? "Said hello once" : `Said hello ${count} times`, { size: 11, color: "tertiary" }),
  ]),
});

atelier.command({
  id: "say-hello",
  title: "Say Hello",
  run: () => {
    count += 1;
    atelier.storage.set("count", count);
    console.log("Hello! That makes " + count + ".");
    clock.refresh();
  },
});
