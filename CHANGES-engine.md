### New
- Plugin widgets can have buttons and switches that call back into the plugin, images (from the plugin's own folder, or from its allowed sites), bar, line and area charts, grids, progress bars and dividers. Stacks can fade, slide or scale their contents in and out.
- Plugins can declare settings in their manifest: text, numbers, switches, choices, colours, shortcut hints and secrets. Atelier draws them on the plugin's page in Mods and in its details in Mods › Library. Secrets are kept in the Keychain and never shown again.
- Plugins can start only when needed (a command, a widget on screen, a Dock tile click, a hot corner, a timer or an event) and go back to sleep after 10 idle minutes. Their commands, widgets and tiles show while they sleep.
- Load Plugin Folder… in Mods › Library runs a plugin straight from its folder, marked Development, and restarts it moments after each save, keeping its storage.
- A plugin's details show its activity: calls and script time per minute, and its recent network requests.
- Safe mode: after two launches in a row that crashed while plugins ran, Atelier starts with plugins off, says which were running, and offers to turn them back on.
- Plugins can message each other when both list the other in their manifest.
- Plugins can send data with POST, PUT, PATCH and DELETE, to the same allowed sites as before.
- New plugin events: update (once, after the plugin is updated), settings changed, sleep and wake, screen locked and unlocked, displays changed, and power source.
- Plugins can carry their text in several languages; Atelier picks yours, with English as the fallback.
- The Pomodoro example plugin has Start and Reset buttons, a chart of the week's sessions, and settings for focus and break lengths.

### Improved
- A plugin stopped for running too long now posts a notification naming it.
- Plugin views may hold up to 240 elements, up from 160.
