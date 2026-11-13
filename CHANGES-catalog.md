### New
- Mods: authors can sign their own packages. A mod's page says "Signed by the author and the catalog" (with the key's fingerprint) or "Signed by the catalog", and Atelier checks both signatures before installing.
- Mods: "This mod changed hands". An update signed by a different author key than the version you have waits on a sheet until you confirm you trust the new publisher.
- Mods: Roll Back to the previous version from a mod's page or the ⋯ menu of its row in Installed, and Install This Version on any row of the version history. An older version asks first, and stays put until you choose Allow Updates.
- Mods: updates that ask for new permissions or network hosts show exactly what is new and ask before installing. Update All never installs them; they are marked Needs review.
- Mods: Featured this week, with a note from the maintainers, and collections as shelves in Browse.
- Mods: author pages, with all of an author's mods, their installs and links to their GitHub and site. "More by" on every mod page; searching for an author lists them.
- Mods: install counts ("1.2k installs") and likes on cards and pages, and Discuss on GitHub on every mod page. Counts come from GitHub's own download counts and discussion reactions; Atelier sends nothing.
- Mods › Installed: Export Setup… and Import Setup…. A `.ateliersetup` file holds your mods and versions, which plugins are on and your theme or Look, never a secret. Include plugin data adds what plugins keep, without anything that looks like a token or password. Import shows what it will do first and still asks for each plugin's permissions.
- Website: collections, Featured this week, author pages (mods.html?author=…), install counts, likes, Discuss on GitHub, and filters for every kind of mod.

### Improved
- Mods: packages download from the catalog's GitHub Release assets first, with the catalog's own copy as the fallback; size and checksum are checked the same way either way.
- Mods: every install, update and rollback goes through the same review. Website search also matches mod ids.
