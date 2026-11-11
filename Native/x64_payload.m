//
// Atelier Dock Bridge — x86_64 (Intel) Dock internals (offsets, byte patterns, register-setup
// macros). The Intel counterpart of arm64_payload.m.
//
// Ported from koekeishiya/yabai (MIT), src/osax/x64_payload.m, copied from yabai v7.1.25.
// Original work: Copyright (c) 2019 Asmund Vikane. MIT License. Adapted for Atelier: trimmed to
// the five Dock internals Atelier's DockBridging contract uses (dock.spaces, DPDesktopPictureManager,
// addSpace/removeSpace/moveSpace), dropping yabai's fix-animation and set-front-window entries that
// Atelier does not call.
//
// Intel needs only System Integrity Protection partly off to inject — there is no PAC and no
// arm64e boot-arg, so the Spaces function pointers are called as raw addresses (see payload.m).
//
// These offsets and patterns are tied to an exact Intel Dock build and CANNOT be verified offline
// here without those Dock binaries to scan; trust them as "from yabai v7.1.25" and re-derive if a
// Dock update moves them. macOS 14 has a separate pattern/offset for 14.0 vs 14.1+ (minorVersion),
// as yabai does. There is no macOS 27 entry: macOS 27 is Apple-silicon only, so verify_os_version
// returns false for 27 on Intel and only the window commands (which need no scan) run.
//
// x86_64 only.
//

#define asm__call_add_space(v0,v1,func) \
    __asm__("movq %0, %%rdi;""movq %1, %%r13;""callq *%2;" : :"r"(v0), "r"(v1), "r"(func) :"%rdi", "%r13");

#define asm__call_move_space(v0,v1,v2,v3,func) \
    __asm__("movq %0, %%rdi;""movq %1, %%rsi;""movq %2, %%rdx;""movq %3, %%r13;""callq *%4;" : :"r"(v0), "r"(v1), "r"(v2), "r"(v3), "r"(func) :"%rdi", "%rsi", "%rdx", "%r13");

uint64_t get_dock_spaces_offset(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 26) return 0x90000;
    if (os_version.majorVersion == 15) return 0xA0000;
    if (os_version.majorVersion == 14) return os_version.minorVersion > 0 ? 0xD5000 : 0x140000;
    return 0;
}

uint64_t get_dppm_offset(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 26) return 0x140000;
    if (os_version.majorVersion == 15) return 0x13b000;
    if (os_version.majorVersion == 14) return os_version.minorVersion > 0 ? 0x12ce00 : 0x8000;
    return 0;
}

uint64_t get_add_space_offset(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 26) return 0x2A5000;
    if (os_version.majorVersion == 15) return os_version.minorVersion >= 4 ? 0x270000 : 0x280000;
    if (os_version.majorVersion == 14) return os_version.minorVersion > 0 ? 0x1f0000 : 0x217000;
    return 0;
}

uint64_t get_remove_space_offset(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 26) return 0x211000;
    if (os_version.majorVersion == 15) return 0x1e0000;
    if (os_version.majorVersion == 14) return os_version.minorVersion > 0 ? 0x2B0000 : 0x2D0000;
    return 0;
}

uint64_t get_move_space_offset(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 26) return 0x210000;
    if (os_version.majorVersion == 15) return 0x1e0000;
    if (os_version.majorVersion == 14) return os_version.minorVersion > 0 ? 0x2A0000 : 0x2C0000;
    return 0;
}

const char *get_dock_spaces_pattern(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 26 || os_version.majorVersion == 15) {
        return "?? ?? ?? 00 48 8B 38 48 8B 35 ?? ?? ?? 00 89 DA 41 FF D5 48 89 C7 E8 ?? ?? ?? 00 49 89 C7 48 8B 35 ?? ?? ?? 00 48 89";
    }
    if (os_version.majorVersion == 14) {
        if (os_version.minorVersion > 0) {
            return "?? ?? ?? 00 48 8B 38 48 8B 35 ?? ?? ?? 00 89 DA 41 FF D5 48 89 C7 E8 ?? ?? ?? 00 49 89 C7 48 8B 35 ?? ?? ?? 00 48 89";
        }
        return "?? ?? ?? 00 49 8B 3E 48 8B 35 A0 DD 2B 00 44 89 A5 78 FE FF FF 44 89 E2 49 89 DC FF D3 48 89 C7 E8 C5 66 1E 00 48 89 85 F8 FD FF FF 48 8B 3D FB 19 2C 00 E8 0A 66 1E 00 48 8B 1D 2F EA 2B 00 48 89 C7 48 89 DE 31 D2 41 FF D4 48 89 85 38 FE FF FF 49";
    }
    return NULL;
}

const char *get_dppm_pattern(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 26 || os_version.majorVersion == 15) {
        return "?? ?? ?? 00 31 FF 5D E9 ?? ??";
    }
    if (os_version.majorVersion == 14) {
        if (os_version.minorVersion > 0) {
            return "?? ?? ?? 00 31 FF 5D E9 ?? ?? 1C 00";
        }
        return "?? ?? ?? 00 4C 89 FE E8 ?? ?? ?? 00 4D 85 FF 0F 84 ?? 06 00 00 48 8D 35 ?? ?? 42 00 31 FF E8 ?? ?? 31 00 48 8B 3D ?? ?? 3F 00 48 8B 35 ?? ?? 3F 00 FF 15 ?? ?? 39 00 48 89 C7 E8 ?? ?? 31 00 48 89 85 10 FF FF FF C7 85 1C FF FF FF 00 00 00 00 E8 ?? ?? 31 00 48 8D 75 B0 89 C7 E8";
    }
    return NULL;
}

const char *get_add_space_pattern(NSOperatingSystemVersion os_version) {
    // Find this one as the function prologue where the function references
    // string 'addSpace:forDisplayUUID:'.
    if (os_version.majorVersion == 26) {
        return "55 48 89 E5 41 57 41 56 41 55 41 54 53 48 83 EC ?? 48 89 7D ?? 4D 8D 75 ??";
    }
    if (os_version.majorVersion == 15) {
        if (os_version.minorVersion >= 4) {
            return "55 48 89 E5 41 57 41 56 41 55 41 54 53 48 83 EC 28 4D 89 EE 48 89 7D B8";
        }
        return "55 48 89 E5 41 57 41 56 41 55 41 54 53 48 83 EC 28 48 BA 01 00 00 00 00";
    }
    if (os_version.majorVersion == 14) {
        if (os_version.minorVersion >= 4) {
            return "55 48 89 E5 41 57 41 56 41 55 41 54 53 48 83 EC 28 48 89 7D C8 49 BE 01 00 00 00 00 00 00 40 49 BC F8 FF FF FF FF FF FF 00 49 8D 45 28 48 89 45 D0 4D 8B 7D 28 4C 89 6D B8 41 80 7D 38 01 75 15 4D 85 F7 0F 85 4D 03 00 00 4D 21 E7 49 8B 5F 10 E9 96 01 00 00 4D 85 F7 0F 85 68 03 00 00 4C 89 F8 4C 21 E0 48 8B 58 10 4C 89 FF E8 ?? ?? 10 00 48 85 DB 0F 84 24 01 00 00 49 89 DC 49 FF CC 0F 80 67 03 00 00 49 BE 03 00 00 00 00 00";
        }
        return "55 48 89 E5 41 57 41 56 41 55 41 54 53 48 83 EC 28 48 89 7D C0 48 B8 01 00 00 00 00 00 00 40 48 BB F8 FF FF FF FF FF FF 00 4D 8B 65 28 41 80 7D 38 01 75 1A 49 85 C4 0F 85 7F 03 00 00 49 21 DC 49 8B 4C 24 10 48 89 4D D0 E9 9A 01 00 00 49 85 C4 4C 89 6D C8 0F 85 9C 03 00 00 4C 89 E0 48 21 D8 48 8B 58 10 4C 89 E7 E8 ?? ?? 10 00 48 85 DB 0F 84 10 01 00 00 49 89 DF 49 FF CF 0F 80 9E 03 00 00 49 BE 03 00 00 00 00 00 00 C0 31";
    }
    return NULL;
}

const char *get_remove_space_pattern(NSOperatingSystemVersion os_version) {
    // Here a regex search over decompiled text; _objc_msgSend\(.*,"removeSpace:"
    // and the function with four parameters.
    if (os_version.majorVersion == 26) {
        return "55 48 89 E5 41 57 41 56 41 55 41 54 53 48 83 EC ?? ?? 89 ?? ?? 89 ?? 49 89 F5 49";
    }
    if (os_version.majorVersion == 15) {
        return "55 48 89 E5 41 57 41 56 41 55 41 54 53 48 83 EC ?? 49 89 ?? 49 89 D6 49 89 F5 ?? 89 ??";
    }
    if (os_version.majorVersion == 14) {
        return "55 48 89 E5 41 57 41 56 41 55 41 54 53 48 83 EC 68 48 89 4D ?? 49 89 D7 49 89 F5 49 89 FC 48 BB F8 FF FF FF FF FF FF 00 E8 ?? ?? ?? FF 49 89 C6 48 B8 01 00 00 00 00 00 00 40 4C 21 F3 49 85 C6 0F 85 ?? 02 00 00 48 8B 43 10 48 83 F8 02 0F 8C ?? 02 00 00 4C 89 6D ?? 4C 89 75 A0 48 8D 05 ?? ?? ?? 00 48 8B 00 49 8B 1C 04 4D 8B 74 04 08 48 8D 05 ?? ?? ?? 00 48 8B 38 48 8B 35 ?? ?? ??";
    }
    return NULL;
}

const char *get_move_space_pattern(NSOperatingSystemVersion os_version) {
    // Searching decompiled text for regex; _objc_msgSend\(.*,"moveSpace:toDisplay:displayUUID:"
    // two parameter function.
    if (os_version.majorVersion == 26) {
        return "55 48 89 E5 41 57 41 56 41 55 41 54 53 48 83 EC 38 4D 89 EC 41 89 D5 49 89 F7 48 8B 05";
    }
    if (os_version.majorVersion == 15) {
        return "55 48 89 E5 41 57 41 56 41 55 41 54 53 48 83 EC 38 4C 89 E9 41 89 D5 49 89 F7 49 89 FC 48 8B 05 ?? ?? 25";
    }
    if (os_version.majorVersion == 14) {
        return "55 48 89 E5 41 57 41 56 41 55 41 54 53 48 83 EC 48 4C 89 E9 41 89 D5 49 89 ?? 49 89 FF ?? 8D ?? ?? ?? ?? 00 ?? 8B ?? ?? 8B ?? 07 ?? 89 ?? 48 89 4D A0 48 89 CE E8 ?? ?? 00 00 48 89 55 D0 48 89 45 C8 48 85 C0 74 3F 48 8D 05 ?? ?? ?? 00 80 38 01 75 ?? ?? 8B ?? D0 ?? 89 ?? 49 83 C5 28 4C 8B 7D C8 4C 89 FF E8 ?? ?? ?? FF 48 89 C7 FF 15 ?? ?? 0C 00";
    }
    return NULL;
}
