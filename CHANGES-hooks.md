### New

- Plugins can plug into Atelier's own features (see docs/PLUGINS.md, "Hooks into Atelier"):
  - **Command palette searches.** A plugin can answer as you type in Command, in a section of its
    own. With a prefix, it answers only to that: type `gh atelier` to search your GitHub
    repositories with the GitHub Hub example.
  - **Menu bar items**, with their own menu (new `menuBar` permission, at most two per plugin).
  - **Dock tile menus and drops.** A plugin's Dock tile can have its own right-click menu (also on
    press and hold), and can take a link or text dropped on it. Files are never handed to plugins.
  - **Stacks from plugins.** A plugin can fill a stack for the Atelier Dock; add it from
    Stacks › From Plugins, or from the plugin's page in Mods.
  - **Live activities**: small live pills under the menu bar, like a timer or a download, at most
    three at once (new `liveActivities` permission).
  - **Scenes**: a plugin can list your Scenes and switch to one (new `scenes` permission).
  - **Windows**: a plugin can open small windows of its own showing its HTML, with no network,
    no files outside its folder and no navigation (new `panels` permission).
- Plugin Dock tiles can now be put on the Atelier Dock: Dock › Tile › From Plugins, or Add to Dock
  on the plugin's page in Mods.
- A new example plugin, GitHub Hub, uses every hook.

### Improved

- A plugin's page in Mods lists its palette searches, stacks, menu bar items and windows under
  In Atelier, and offers Add to Dock for its Dock tiles and stacks.
