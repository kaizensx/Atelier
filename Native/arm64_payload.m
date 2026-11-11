//
// Atelier Dock Bridge — arm64e Dock internals (offsets, byte patterns, register-setup macros).
//
// Ported from koekeishiya/yabai (MIT), src/osax/arm64_payload.m.
// Original work: Copyright (c) 2019 Asmund Vikane. MIT License. Adapted for Atelier.
//
// The Spaces commands reach private Dock.app methods (addSpace/removeSpace/moveSpace) and two
// Dock globals (dock.spaces, DPDesktopPictureManager). The payload finds them by scanning the
// Dock's __TEXT for a version-specific byte pattern at a version-specific start offset. These
// values are tied to an exact Dock build and must be re-derived when the Dock binary changes.
//
// macOS 14 (Sonoma), 15 (Sequoia) and 26 (Tahoe) values are yabai's, copied from yabai v7.1.25
// (src/osax/arm64_payload.m). They are tied to an exact Dock build and CANNOT be verified offline
// here without those Dock binaries to scan; trust them as "from yabai v7.1.25" and re-derive if a
// Dock update moves them. macOS 14 has a separate pattern/offset for 14.0 vs 14.1+ (minorVersion),
// as yabai does. On macOS 14/15 the add/remove/move Spaces functions ARE enabled (yabai ships their
// patterns), unlike 27 below where they stay disabled pending a runtime-verified pass.
//
// macOS 27 (build 26C5035r, Dock 27.3, Apple silicon arm64e) was re-derived offline by reverse
// engineering the shipped Dock binary (SIP on; no injection, no loader run). Method, per item:
// anchor on code near a known selector/string/CGS-call, confirm the target in pseudo-code, then
// prove with an offline scanner that runs this file's hex_find_seq + decode_adrp_add against the
// Dock __TEXT: each proven pattern matches EXACTLY ONCE (both in the payload scan window and over
// the whole file) and decodes to the address REA reports for that item. Findings:
//
//   * dock.spaces  (Spaces singleton, data 0x33afd0): pattern still matches; only the start
//     offset moved (the anchor -[Tile doBindingCommand:display:] now sits below yabai's 0x30000).
//     Anchor: the clearBindingForBundleID: block of -[Tile doBindingCommand:display:]; the ADRP
//     /ADD/LDR loads the Spaces global that currentSpaceForDisplay:/setBinding: are sent to.
//   * DPDesktopPictureManager (desktop-picture-manager singleton, data 0x33b038): yabai's 26
//     pattern no longer matches (0 hits); re-derived a fresh pattern. Anchor: the ADRP/ADD/LDR
//     load inside sub_100131ba8; the loaded object is the Dock global later sent
//     -[...WallpaperAgentDesktopPictureManager spaceBecameFirst:onDisplay:], confirming identity.
//
//   * addSpace / removeSpace / moveSpace function pointers: NOT enabled on macOS 27. These are
//     called as raw function pointers with hand-set argument registers, so a wrong calling
//     convention crashes Dock. On 27.3 the private functions were reorganized: yabai's 26
//     add/move prologue patterns now collide onto ONE mover (sub_100196160, which calls
//     CGSMoveManagedSpaceToDisplayIndex) and yabai's 26 move pattern matches nothing. A strong
//     destroy candidate exists (sub_100133fe0, calls SLSTransactionDestroySpace) but its observed
//     argument handling does not match the ported remove_space_call typedef (it bridges arg1 to a
//     Swift String, where Atelier passes a display_space OBJECT). The exact signatures cannot be
//     proven offline, and SIP forbids the runtime check that would settle them, so the three
//     patterns return NULL here: hex_find_seq yields 0, the fps stay 0, and do_space_create/
//     destroy/move no-op by their existing `fp == 0` guards. Documented candidate entry points for
//     a future runtime-verified pass: add=unidentified, remove=sub_100133fe0 (0x133fe0),
//     move=sub_100196160 (0x196160). do_space_focus needs only dock.spaces + SkyLight and works.
//

#define asm__call_add_space(v0,v1,func) \
    __asm__("mov x0, %0\n""mov x20, %1\n" : :"r"(v0), "r"(v1) :"x0", "x20"); ((void (*)())(func))();

#define asm__call_move_space(v0,v1,v2,v3,func) \
    __asm__("mov x0, %0\n""mov x1, %1\n""mov x2, %2\n""mov x20, %3\n" : :"r"(v0), "r"(v1), "r"(v2), "r"(v3) :"x0", "x1", "x2", "x20"); ((void (*)())(func))();

uint64_t get_dock_spaces_offset(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 27) return 0x20000;   // target 0x2fcb8; window start < anchor
    if (os_version.majorVersion == 26) return 0x30000;
    if (os_version.majorVersion == 15) return os_version.minorVersion >= 4 ? 0x1f0000 : 0x200000; // from yabai v7.1.25
    if (os_version.majorVersion == 14) return 0x114000; // from yabai v7.1.25
    return 0;
}

uint64_t get_dppm_offset(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 27) return 0x120000;  // target 0x131f50
    if (os_version.majorVersion == 26) return 0x70000;
    if (os_version.majorVersion == 15) return 0x250000; // from yabai v7.1.25
    if (os_version.majorVersion == 14) return os_version.minorVersion > 0 ? 0x1d2000 : 0x9000; // from yabai v7.1.25
    return 0;
}

uint64_t get_add_space_offset(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 27) return 0;         // disabled; pattern NULL
    if (os_version.majorVersion == 26) return 0x250000;
    if (os_version.majorVersion == 15) return 0x250000; // from yabai v7.1.25
    if (os_version.majorVersion == 14) return 0x1D0000; // from yabai v7.1.25
    return 0;
}

uint64_t get_remove_space_offset(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 27) return 0;         // disabled; pattern NULL
    if (os_version.majorVersion == 26) return 0x1e0000;
    if (os_version.majorVersion == 15) return 0x1c0000; // from yabai v7.1.25
    if (os_version.majorVersion == 14) return 0x280000; // from yabai v7.1.25
    return 0;
}

uint64_t get_move_space_offset(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 27) return 0;         // disabled; pattern NULL
    if (os_version.majorVersion == 26) return 0x1c0000;
    if (os_version.majorVersion == 15) return 0x1c0000; // from yabai v7.1.25
    if (os_version.majorVersion == 14) return 0x280000; // from yabai v7.1.25
    return 0;
}

const char *get_dock_spaces_pattern(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 27) {
        // Anchor: clearBindingForBundleID: block of -[Tile doBindingCommand:display:].
        // ADRP x8 / ADD x8,#0xfd0 / LDR x0,[x8] / MOV x2,x19 / BL; decodes to Spaces @ 0x33afd0.
        return "?8 ?? ?? ?? 08 ?? ?? 91 00 01 40 F9 E2 03 13 AA ?? ?? ?? 94 ?? ?? ?? ?? 08";
    }
    if (os_version.majorVersion == 26) {
        // Pulling out of doBindingCommand:display (search decompiled text in ghidra) function.
        return "?8 ?? ?? ?? 08 ?? ?? 91 00 01 40 F9 E2 03 13 AA ?? ?? ?? 94 ?? ?? ?? ?? 08";
    }
    if (os_version.majorVersion == 15) {   // from yabai v7.1.25
        return "?? 12 00 ?? ?? ?? ?? 91 ?? 02 40 F9 ?? ?? 00 B4 ?? ?? ?? ??";
    }
    if (os_version.majorVersion == 14) {   // from yabai v7.1.25
        if (os_version.minorVersion > 0) {
            return "36 16 00 ?? D6 ?? ?? 91 ?? 02 40 F9 ?? ?? 00 B4 ?? 03 14 AA";
        }
        return "97 18 00 B0 F7 02 0F 91 E0 02 40 F9 E2 03 14 AA 1A 09 08 94 FD 03 1D AA 3C EF 07 94 F6 03 00 AA 00 01 00 B5 E0 02 40 F9 E2 03 14 AA 3B 0F 08 94 FD 03 1D AA 35 EF 07 94 F6 03 00 AA E0 00 00 B4 E0 03 15 AA E2 03 13 AA E3 03 16 AA F3 F3 07 94 E0 03 16 AA 1D EF 07 94 E0 03 14 AA";
    }
    return NULL;
}

const char *get_dppm_pattern(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 27) {
        // Anchor: ADRP x8 / ADD x8,#0x38 / LDR x19,[x8] / MOV x0,x19 / BL / MOV x0,x26 / BL inside
        // sub_100131ba8; decodes to the desktop-picture-manager global @ 0x33b038, confirmed by
        // -[...WallpaperAgentDesktopPictureManager spaceBecameFirst:onDisplay:] sent to it.
        return "?8 ?? ?? ?? 08 E1 00 91 13 01 40 F9 E0 03 13 AA ?? ?? ?? 94 E0 03 1A AA ?? ?? ?? 94";
    }
    if (os_version.majorVersion == 26) {
        //Pulling from function 'DPRemoteConnection::_handleEvent:'
        return "?? ?? 00 ?? 08 ?? ?? 91 00 01 40 F9 E2 03 16 AA E3 03 19 AA ?? ?? ?? 94";
    }
    if (os_version.majorVersion == 15) {   // from yabai v7.1.25
        return "?? 0F 00 ?? ?? ?? ?? 91 ?? 0E 00 ?? ?? ?? ?? F8 ?? 03 40 F9 ?? ?? ??";
    }
    if (os_version.majorVersion == 14) {   // from yabai v7.1.25
        if (os_version.minorVersion > 0) {
            return "?? 10 00 ?? ?? ?? ?? 91 ?? 0F 00 D0 ?? ?? ?? F8 ?? 03 40 F9 ?? ?? ??";
        }
        return "E0 20 00 90 00 ?? ?? 91 E1 03 13 AA ?? ?? 0C 94 73 2D 00 B4 E1 20 00 90 21 ?? ?? 91 00 00 80 D2 D9 13 0C 94 A8 1F 00 F0 00 79 43 F9 A2 38 0C 94 FD 03 1D AA 1C 1E 0C 94 F4 03 00 AA BF 7F 37 A9";
    }
    return NULL;
}

const char *get_add_space_pattern(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 27) {
        // Not enabled: the add function could not be identified on 27.3 and the raw calling
        // convention cannot be proven offline (SIP). See header note.
        return NULL;
    }
    if (os_version.majorVersion == 26) {
        if (os_version.minorVersion >= 4) {
            return "7F 23 03 D5 E1 03 1E AA ?? ?? ?? 97 FE 03 01 AA FD 7B 05 A9 FD 43 01 91 F3 03 14 AA F5 03";
        }
        return "7F 23 03 D5 FF C3 01 D1 E1 03 1E AA ?? ?? 00 94 FE 03 01 AA FD 7B 06 A9 FD 83 01 91 F3 03";
    }
    if (os_version.majorVersion == 15) {   // from yabai v7.1.25
        return "7F 23 03 D5 FF C3 01 D1 E1 03 1E AA ?? ?? 00 94 FE 03 01 AA FD 7B 06 A9 FD 83 01 91 F3 03";
    }
    if (os_version.majorVersion == 14) {   // from yabai v7.1.25
        return "7F 23 03 D5 FF C3 01 D1 E1 03 1E AA ?? ?? 00 94 FE 03 01 AA FD 7B 06 A9 FD 83 01 91 F5 03";
    }
    return NULL;
}

const char *get_remove_space_pattern(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 27) {
        // Not enabled: candidate sub_100133fe0 (SLSTransactionDestroySpace) does not match the
        // ported remove_space_call typedef, and the convention cannot be proven offline. See header.
        return NULL;
    }
    if (os_version.majorVersion == 26) {
        return "7F 23 03 D5 FF ?? ?? D1 FC ?? ?? A9 FA ?? ?? A9 F8 ?? ?? A9 F6 ?? ?? A9 F4 ?? ?? A9 FD ?? ?? A9 FD ?? ?? 91 ?? 03 03 AA F5 03 02 AA F4 03 01 AA";
    }
    if (os_version.majorVersion == 15) {   // from yabai v7.1.25
        return "7F 23 03 D5 FF 83 ?? D1 FC 6F ?? A9 FA 67 ?? A9 F8 5F ?? A9 F6 57 ?? A9 F4 4F ?? A9 FD 7B ?? A9 FD 43 ?? 91 ?? 03 03 AA ?? 03 02 AA ?? 03 01 AA ?? 03 00 AA ?? ?? ?? AA";
    }
    if (os_version.majorVersion == 14) {   // from yabai v7.1.25
        return "7F 23 03 D5 FF 83 ?? D1 FC 6F ?? A9 FA 67 ?? A9 F8 5F ?? A9 F6 57 ?? A9 F4 4F ?? A9 FD 7B ?? A9 FD 43 ?? 91 ?? 03 03 AA ?? 03 02 AA ?? 03 01 AA ?? 03 00 AA ?? ?? ?? 97 FC 03 00 AA 08 FC 7E D3 ?? ?? 00 B5 88 E3 7D 92 00";
    }
    return NULL;
}

const char *get_move_space_pattern(NSOperatingSystemVersion os_version) {
    if (os_version.majorVersion == 27) {
        // Not enabled: candidate mover sub_100196160 (CGSMoveManagedSpaceToDisplayIndex) has an
        // unproven calling convention; a raw call risks crashing Dock. See header note.
        return NULL;
    }
    if (os_version.majorVersion == 26) {
        return "7F 23 03 D5 E3 03 1E AA ?? ?? ?? 97 FE 03 03 AA FD 7B ?? A9 FD ?? ?? 91 F6 03 14 AA";
    }
    if (os_version.majorVersion == 15) {   // from yabai v7.1.25
        return "7F 23 03 D5 E3 03 1E AA ?? ?? FF 97 FE 03 03 AA FD 7B 06 A9 FD 83 01 91 F6 03 14 AA F4 03 02 AA FB 03 01 AA FA 03 00 AA ?? 13 00 ?? E8 ?? ?? F9 19 68 68 F8 E0 03 19 AA E1 03 16 AA";
    }
    if (os_version.majorVersion == 14) {   // from yabai v7.1.25
        return "7F 23 03 D5 FF C3 01 D1 E3 03 1E AA ?? ?? 00 94 FE 03 03 AA FD 7B 06 A9 FD 83 01 91 F6 03 14 AA F4 03 02 AA FA 03 01 AA FB 03 00 AA ?? ?? 00 ?? F7 ?? ?? 91 E8 02 40 F9 19 68 68 F8 E0 03 19 AA E1 03 16 AA ?? 25 00 94 ?? ?? 00 B4 ?? 03 00 AA ?? 03 01 AA";
    }
    return NULL;
}
