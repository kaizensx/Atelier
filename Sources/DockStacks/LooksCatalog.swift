import DockCore
import Foundation

/// The curated Looks. Each is an ordinary theme, written in the same format a user's theme is,
/// so every Look is also a worked example of the format. They are validated at first use; a
/// Look that fails validation is left out and the reason logged, never half-applied.
@MainActor
enum LooksCatalog {
    static let all: [InstalledTheme] = sources.compactMap { source in
        let (value, validation) = ThemeValidator.validate(data: Data(source.utf8), files: [])
        guard let root = value?.object, validation.isValid else {
            NSLog("Atelier: a built-in Look failed validation: %@", validation.errors.map(\.description).joined(separator: "; "))
            return nil
        }
        return InstalledTheme(document: ThemeDocument(root: root), bundle: nil, warnings: validation.warnings)
    }

    /// The six old Looks, by their old names, to the new ones.
    static func migrate(_ old: String) -> String? {
        ["Classic": "atelier.look.classic", "Midnight": "atelier.look.midnight-glass", "Aurora": "atelier.look.aurora",
         "Ember": "atelier.look.ember-forge", "Ocean": "atelier.look.lagoon", "Dusk": "atelier.look.orchid"][old]
    }

    private static let sources: [String] = [
        #"""
        {"format":1,"id":"atelier.look.midnight-glass","name":"Midnight Glass","version":"1.0.0","author":"Atelier",
         "description":"Ink-blue glass over a slow nebula. Quiet, deep and crisp.","tags":["dark","blue","calm"],"appearance":"dark",
         "colors":{"accent":"#8FB8FF","secondary":"#B49CFF","glassTint":"#1B2A55"},
         "dock":{"style":"glass","accent":"blue","indicator":"dot","roundness":0.72,"padding":0.14,"curve":"classic","iconShadow":true,"reflection":true,"followTheme":false},
         "widgets":{"material":"glass","tint":"indigo","accent":"blue","radius":26,"font":"system","shadow":0.35},
         "menuBar":{"skin":"notchless"},
         "wallpaper":{"mode":"live","shader":"nebula","palette":"midnight","speed":0.7,"intensity":0.55,"dim":0.08,"cycle":"night"},
         "studio":{"backdrop":"midnight","accent":"#8FB8FF","glow":0.45},
         "icons":{"style":"clear","mode":"dark"},
         "clock":{"show":true,"face":"thin"},
         "effects":{"dockGlow":false}}
        """#,
        #"""
        {"format":1,"id":"atelier.look.aurora","name":"Aurora","version":"1.0.0","author":"Atelier",
         "description":"Curtains of green and violet light, with glass that glows from within.","tags":["dark","green","vivid"],"appearance":"dark",
         "colors":{"accent":"#4FE3C1","secondary":"#9C7CFF","glassTint":"#0D3B36"},
         "dock":{"style":"tinted","accent":"#4FE3C1","indicator":"glow","roundness":0.8,"launch":"glow","followTheme":false},
         "widgets":{"material":"tinted","tint":"mint","accent":"mint","radius":28,"font":"rounded","shadow":0.25},
         "menuBar":{"skin":"aurora"},
         "wallpaper":{"mode":"live","shader":"auroraSilk","palette":"natural","speed":0.9,"intensity":0.6,"cycle":"clock"},
         "studio":{"backdrop":"aurora","accent":"mint","glow":0.6},
         "icons":{"style":"tinted","mode":"dark","tint":"#3FD9C0"},
         "clock":{"show":true,"face":"thin"},
         "effects":{"dockGlow":true}}
        """#,
        #"""
        {"format":1,"id":"atelier.look.sunset-neon","name":"Sunset Neon","version":"1.0.0","author":"Atelier",
         "description":"A striped sun over a neon grid. Hot pink edges, warm orange light.","tags":["dark","pink","retro"],"appearance":"dark",
         "colors":{"accent":"#FF4FA3","secondary":"#FF9F43","glassTint":"#3A0F2E"},
         "dock":{"style":"neon","accent":"pink","indicator":"glow","roundness":0.55,"curve":"wave","launch":"pulse","reflection":true},
         "widgets":{"material":"dark","tint":"pink","accent":"pink","radius":18,"font":"mono","border":1,"shadow":0.5,
                    "gradient":{"from":"pink","to":"orange","angle":135}},
         "menuBar":{"skin":"sunset"},
         "wallpaper":{"mode":"live","shader":"retroHorizon","palette":"natural","speed":1.1,"intensity":0.65},
         "studio":{"backdrop":"ember","accent":"rose","glow":0.65},
         "icons":{"style":"tinted","mode":"dark","tint":"Pink"},
         "clock":{"show":true,"face":"bold"},
         "effects":{"dockGlow":true},
         "sounds":{"apply":"Funk"}}
        """#,
        #"""
        {"format":1,"id":"atelier.look.paper-studio","name":"Paper Studio","version":"1.0.0","author":"Atelier",
         "description":"Warm paper, serif type and soft daylight. A desk, not a dashboard.","tags":["light","warm","calm"],"appearance":"light",
         "colors":{"accent":"#C9733A","secondary":"#8C6A4F","glassTint":"#F3E7D3"},
         "dock":{"style":"frost","accent":"orange","indicator":"bar","roundness":0.5,"padding":0.12,"iconShadow":false,"reflection":false},
         "widgets":{"material":"frosted","tint":"amber","accent":"orange","radius":16,"font":"serif","shadow":0.15,"padding":4},
         "menuBar":{"skin":"none"},
         "wallpaper":{"mode":"live","shader":"gradientMesh","palette":"dune","speed":0.5,"intensity":0.4,"grain":0.25,"cycle":"day"},
         "studio":{"backdrop":"paper","accent":"amber","glow":0.4},
         "icons":{"style":"default"},
         "clock":{"show":true,"face":"serif"},
         "effects":{"dockGlow":false}}
        """#,
        #"""
        {"format":1,"id":"atelier.look.glacier","name":"Glacier","version":"1.0.0","author":"Atelier",
         "description":"Rain on cold glass. Pale blues, clear icons, nothing loud.","tags":["light","blue","minimal"],"appearance":"light",
         "colors":{"accent":"#7CC4F2","secondary":"#B9D7EA","glassTint":"#DDEFFA"},
         "dock":{"style":"frost","accent":"blue","indicator":"dot","roundness":0.9,"padding":0.16,"curve":"gentle"},
         "widgets":{"material":"clear","tint":"teal","accent":"teal","radius":30,"font":"rounded","blur":0.4},
         "menuBar":{"skin":"none"},
         "wallpaper":{"mode":"live","shader":"glassRain","palette":"glacier","speed":0.8,"intensity":0.45},
         "studio":{"backdrop":"light","accent":"sky","glow":0.5},
         "icons":{"style":"clear","mode":"light"},
         "clock":{"show":true,"face":"rounded"},
         "effects":{"dockGlow":false}}
        """#,
        #"""
        {"format":1,"id":"atelier.look.ember-forge","name":"Ember Forge","version":"1.0.0","author":"Atelier",
         "description":"Molten light in a dark room. Copper accents and a flip clock.","tags":["dark","orange","warm"],"appearance":"dark",
         "colors":{"accent":"#FF8A3D","secondary":"#FFC46B","glassTint":"#3A1608"},
         "dock":{"style":"midnight","accent":"orange","indicator":"bar","roundness":0.6,"launch":"bounce","reflection":true},
         "widgets":{"material":"dark","tint":"orange","accent":"amber","radius":22,"font":"system","shadow":0.6},
         "menuBar":{"skin":"sunset"},
         "wallpaper":{"mode":"live","shader":"liquidLight","palette":"ember","speed":0.8,"intensity":0.6,"dim":0.1},
         "studio":{"backdrop":"ember","accent":"amber","glow":0.55},
         "icons":{"style":"tinted","mode":"dark","tint":"Orange"},
         "clock":{"show":true,"face":"flip"},
         "effects":{"dockGlow":true}}
        """#,
        #"""
        {"format":1,"id":"atelier.look.lagoon","name":"Lagoon","version":"1.0.0","author":"Atelier",
         "description":"Draped satin the colour of shallow water. The clock tells the time in words.","tags":["dark","teal","calm"],"appearance":"dark",
         "colors":{"accent":"#2BC4C9","secondary":"#7FF0D8","glassTint":"#073A40"},
         "dock":{"style":"glass","accent":"#2BC4C9","indicator":"dot","roundness":0.75,"curve":"gentle"},
         "widgets":{"material":"glass","tint":"teal","accent":"mint","radius":26,"font":"rounded"},
         "menuBar":{"skin":"ocean"},
         "wallpaper":{"mode":"live","shader":"silkWaves","palette":"lagoon","speed":0.7,"intensity":0.5},
         "studio":{"backdrop":"aurora","accent":"mint","glow":0.5},
         "icons":{"style":"tinted","mode":"dark","tint":"#2BB7C9"},
         "clock":{"show":true,"face":"words"},
         "effects":{"dockGlow":true}}
        """#,
        #"""
        {"format":1,"id":"atelier.look.orchid","name":"Orchid","version":"1.0.0","author":"Atelier",
         "description":"Thin-film violet and rose, with an analog clock and gradient glass.","tags":["dark","purple","vivid"],"appearance":"dark",
         "colors":{"accent":"#C77DFF","secondary":"#FF7EB6","glassTint":"#2A0F3D"},
         "dock":{"style":"glass","accent":"purple","indicator":"glow","roundness":0.85,"curve":"fisheye","hoverLift":true},
         "widgets":{"material":"tinted","tint":"purple","accent":"pink","radius":28,"font":"system",
                    "gradient":{"from":"purple","to":"pink","angle":60}},
         "menuBar":{"skin":"none"},
         "wallpaper":{"mode":"live","shader":"liquidLight","palette":"orchid","speed":0.9,"intensity":0.55},
         "studio":{"backdrop":"midnight","accent":"violet","glow":0.6},
         "icons":{"style":"tinted","mode":"dark","tint":"Purple"},
         "clock":{"show":true,"face":"analog"},
         "effects":{"dockGlow":true}}
        """#,
        #"""
        {"format":1,"id":"atelier.look.graphite-pro","name":"Graphite Pro","version":"1.0.0","author":"Atelier",
         "description":"Monochrome contour lines and mono type. Everything gets out of the way.","tags":["dark","mono","focus"],"appearance":"dark",
         "colors":{"accent":"#D8D8DC","secondary":"#8A8A90","glassTint":"#141416"},
         "dock":{"style":"midnight","accent":"graphite","indicator":"bar","roundness":0.4,"padding":0.1,"iconShadow":false,"divider":true},
         "widgets":{"material":"dark","tint":"graphite","accent":"graphite","radius":14,"font":"mono","border":0.5},
         "menuBar":{"skin":"graphite"},
         "wallpaper":{"mode":"live","shader":"topography","palette":"graphite","speed":0.5,"intensity":0.45,"dim":0.2},
         "studio":{"backdrop":"graphite","accent":"silver","glow":0.3},
         "icons":{"style":"clear","mode":"dark"},
         "clock":{"show":true,"face":"mono"},
         "effects":{"dockGlow":false,"dayLine":true}}
        """#,
        #"""
        {"format":1,"id":"atelier.look.forest-dawn","name":"Forest Dawn","version":"1.0.0","author":"Atelier",
         "description":"A living survey map in moss and morning light.","tags":["dark","green","natural"],"appearance":"dark",
         "colors":{"accent":"#7BD389","secondary":"#E6D98A","glassTint":"#0E2614"},
         "dock":{"style":"wallpaper","accent":"green","indicator":"dot","roundness":0.7},
         "widgets":{"material":"frosted","tint":"green","accent":"green","radius":24,"font":"rounded","shadow":0.2},
         "menuBar":{"skin":"none"},
         "wallpaper":{"mode":"live","shader":"topography","palette":"forest","speed":0.6,"intensity":0.5,"cycle":"clock"},
         "studio":{"backdrop":"aurora","accent":"mint","glow":0.45},
         "icons":{"style":"tinted","mode":"dark","tint":"Green"},
         "clock":{"show":true,"face":"stacked"},
         "effects":{"dockGlow":false}}
        """#,
        #"""
        {"format":1,"id":"atelier.look.deep-space","name":"Deep Space","version":"1.0.0","author":"Atelier",
         "description":"Stars drifting toward you, a black menu bar and a single dot of time.","tags":["dark","black","minimal"],"appearance":"dark",
         "colors":{"accent":"#A8B6FF","secondary":"#6D7CFF","glassTint":"#05060D"},
         "dock":{"style":"midnight","accent":"blue","indicator":"glow","roundness":0.9,"curve":"classic","reflection":true},
         "widgets":{"material":"clear","tint":"indigo","accent":"indigo","radius":30,"font":"system","blur":0.6},
         "menuBar":{"skin":"notchless"},
         "wallpaper":{"mode":"live","shader":"starfield","palette":"midnight","speed":0.8,"intensity":0.5,"cycle":"night"},
         "studio":{"backdrop":"midnight","accent":"violet","glow":0.35},
         "icons":{"style":"clear","mode":"dark"},
         "clock":{"show":true,"face":"dot"},
         "effects":{"dockGlow":false}}
        """#,
        #"""
        {"format":1,"id":"atelier.look.classic","name":"Classic","version":"1.0.0","author":"Atelier",
         "description":"Back to the Mac as it ships: your own wallpaper, standard icons, plain glass.","tags":["reset"],"appearance":"dark",
         "dock":{"style":"glass","accent":"blue","indicator":"bar","hover":"peek","roundness":0.6667,"padding":0.14,"spacing":0,"gap":6,
                 "curve":"classic","launch":"bounce","hoverLift":false,"iconShadow":true,"reflection":false,"divider":true,"followTheme":true},
         "widgets":{"material":"glass","tint":"blue","accent":"blue","radius":26,"opacity":1,"font":"system","shadow":0,"border":0,"padding":0,"scale":1,"blur":0},
         "menuBar":{"skin":"none"},
         "wallpaper":{"mode":"off"},
         "studio":{"backdrop":"light","accent":"sky","glow":0.5},
         "icons":{"style":"default"},
         "clock":{"show":false},
         "effects":{"dockGlow":false,"dayLine":false}}
        """#,
    ]
}
