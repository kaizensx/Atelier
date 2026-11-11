//
// Atelier Dock Bridge — payload, loaded inside Dock.app.
//
// Ported from koekeishiya/yabai (MIT), src/osax/payload.m.
// Original work: Copyright (c) 2019 Asmund Vikane. MIT License. Adapted for Atelier:
//   * per-uid socket /tmp/atelier-sa_<uid>.socket, created 0600, with a peer-uid check;
//   * Atelier opcode set + a versioned handshake and a heartbeat;
//   * a general scale-about-anchor command (not yabai's fixed picture-in-picture quarter);
//   * trimmed to the commands Atelier's DockBridging contract exposes.
//
// Loaded via __attribute__((constructor)) when the Dock dlopen()s this dylib. It opens the
// command socket and pattern-scans the Dock for the Spaces internals. Window opacity, level,
// sticky, shadow and scale use SkyLight SPI and work without the scan; Spaces commands need it.
//
// Universal: the arm64e slice injects into the arm64e Dock (PAC-signed function pointers,
// -arm64e_preview_abi boot-arg), the x86_64 slice into the Intel Dock (raw function pointers,
// no boot-arg). The architecture-specific offset/pattern tables and register-setup macros live
// in arm64_payload.m and x64_payload.m, included per architecture below.
//

#include <Foundation/Foundation.h>
#include <mach-o/getsect.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_page_size.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <CoreGraphics/CoreGraphics.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/ucred.h>
#include <unistd.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "common.h"

#ifdef __x86_64__
#include "x64_payload.m"
#elif __arm64__
#include "arm64_payload.m"
#include <ptrauth.h>
#endif

#define page_align(addr) (vm_address_t)((uintptr_t)(addr) & (~(vm_page_size - 1)))
#define unpack(v) memcpy(&v, message, sizeof(v)); message += sizeof(v)
#define lerp(a, t, b) (((1.0-t)*a) + (t*b))

// SkyLight SPI used by the window commands.
extern int SLSMainConnectionID(void);
extern CGError SLSGetWindowAlpha(int cid, uint32_t wid, float *alpha);
extern CGError SLSSetWindowAlpha(int cid, uint32_t wid, float alpha);
extern CGError SLSGetWindowBounds(int cid, uint32_t wid, CGRect *frame);
extern CGError SLSGetWindowTransform(int cid, uint32_t wid, CGAffineTransform *t);
extern CGError SLSSetWindowTransform(int cid, uint32_t wid, CGAffineTransform t);
extern CGError SLSSetWindowTags(int cid, uint32_t wid, uint64_t *tags, size_t tag_size);
extern CGError SLSClearWindowTags(int cid, uint32_t wid, uint64_t *tags, size_t tag_size);
extern CGError SLSSetWindowSubLevel(int cid, uint32_t wid, int level);
extern uint64_t SLSGetActiveSpace(int cid);
extern CFStringRef SLSCopyManagedDisplayForSpace(int cid, uint64_t sid);
extern uint64_t SLSManagedDisplayGetCurrentSpace(int cid, CFStringRef display_ref);
extern void SLSManagedDisplaySetCurrentSpace(int cid, CFStringRef display_ref, uint64_t sid);
extern void SLSShowSpaces(int cid, CFArrayRef space_list);
extern void SLSHideSpaces(int cid, CFArrayRef space_list);
extern void SLSMoveWindowsToManagedSpace(int cid, CFArrayRef window_list, uint64_t sid);

static id dock_spaces;
static id dp_desktop_picture_manager;
static uint64_t add_space_fp;
static uint64_t remove_space_fp;
static uint64_t move_space_fp;

static pthread_t daemon_thread;
static int daemon_sockfd;

// MARK: - Dock image scanning (ported verbatim from yabai)

static uint64_t static_base_address(void)
{
    const struct segment_command_64 *command = getsegbyname("__TEXT");
    return command->vmaddr;
}

static uint64_t image_slide(void)
{
    char path[1024];
    uint32_t size = sizeof(path);
    if (_NSGetExecutablePath(path, &size) != 0) return -1;

    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (strcmp(_dyld_get_image_name(i), path) == 0) {
            return _dyld_get_image_vmaddr_slide(i);
        }
    }
    return 0;
}

static uint64_t hex_find_seq(uint64_t baddr, const char *c_pattern)
{
    if (!baddr || !c_pattern) return 0;

    uint64_t addr = baddr;
    uint64_t pattern_length = (strlen(c_pattern) + 1) / 3;
    char buffer_a[pattern_length];
    char buffer_b[pattern_length];
    memset(buffer_a, 0, sizeof(buffer_a));
    memset(buffer_b, 0, sizeof(buffer_b));

    char *pattern = (char *) c_pattern + 1;
    for (int i = 0; i < pattern_length; ++i) {
        char c = pattern[-1];
        if (c == '?') {
            buffer_b[i] = 1;
        } else {
            int temp = c <= '9' ? 0 : 9;
            temp = (temp + c) << 0x4;
            c = pattern[0];
            int temp2 = c <= '9' ? 0xd0 : 0xc9;
            buffer_a[i] = temp2 + c + temp;
        }
        pattern += 3;
    }

loop:
    for (int counter = 0; counter < pattern_length; ++counter) {
        if ((buffer_b[counter] == 0) && (((char *)addr)[counter] != buffer_a[counter])) {
            addr = (uint64_t)((char *)addr + 1);
            if (addr - baddr < 0x1286a0) goto loop;
            else return 0;
        }
    }
    return addr;
}

#if __arm64__
uint64_t decode_adrp_add(uint64_t addr, uint64_t offset)
{
    uint32_t adrp_instr = *(uint32_t *) addr;
    uint32_t immlo = (0x60000000 & adrp_instr) >> 29;
    uint32_t immhi = (0xffffe0 & adrp_instr) >> 3;
    int32_t value = (immhi | immlo) << 12;
    int64_t value_64 = value;

    uint32_t add_instr = *(uint32_t *) (addr + 4);
    uint64_t imm12 = (add_instr & 0x3ffc00) >> 10;
    if (add_instr & 0xc00000) imm12 <<= 12;

    return (offset & 0xfffffffffffff000) + value_64 + imm12;
}
#endif

static bool verify_os_version(NSOperatingSystemVersion v)
{
    NSLog(@"[atelier-sa] macOS %ld.%ld.%ld", v.majorVersion, v.minorVersion, v.patchVersion);
    // macOS 14 Sonoma, 15 Sequoia and 26 Tahoe have full Spaces pattern tables (from yabai v7.1.25)
    // for both architectures, so create/remove/move work once their patterns match.
    if (v.majorVersion == 14 || v.majorVersion == 15 || v.majorVersion == 26) return true;
#ifdef __arm64__
    if (v.majorVersion == 27) {
        NSLog(@"[atelier-sa] macOS 27: Spaces globals verified; create/remove/move desktop calls stay off until their calling convention is proven.");
        return true;
    }
#endif
    // macOS 27 is Apple-silicon only, so there is no Intel table for it; fall through on x86_64.
    NSLog(@"[atelier-sa] Spaces commands unsupported on this macOS; window commands still work.");
    return false;
}

static void init_instances(void)
{
    NSOperatingSystemVersion os_version = [[NSProcessInfo processInfo] operatingSystemVersion];
    if (!verify_os_version(os_version)) return;

    uint64_t baseaddr = static_base_address() + image_slide();

    uint64_t dock_spaces_addr = hex_find_seq(baseaddr + get_dock_spaces_offset(os_version), get_dock_spaces_pattern(os_version));
    if (dock_spaces_addr == 0) {
        dock_spaces = nil;
        NSLog(@"[atelier-sa] could not locate dock.spaces; Spaces commands disabled.");
    } else {
#ifdef __x86_64__
        // Intel: the matched instruction holds a 32-bit RIP-relative displacement to the global.
        uint32_t off = *(int32_t *) dock_spaces_addr;
        dock_spaces = [(*(id *)(dock_spaces_addr + off + 0x4)) retain];
#elif __arm64__
        uint64_t off = decode_adrp_add(dock_spaces_addr, dock_spaces_addr - baseaddr);
        dock_spaces = [(*(id *)(baseaddr + off)) retain];
#endif
    }

    uint64_t dppm_addr = hex_find_seq(baseaddr + get_dppm_offset(os_version), get_dppm_pattern(os_version));
    if (dppm_addr == 0) {
        dp_desktop_picture_manager = nil;
    } else {
#ifdef __x86_64__
        uint32_t off = *(int32_t *) dppm_addr;
        dp_desktop_picture_manager = [(*(id *)(dppm_addr + off + 0x4)) retain];
        // Since Sonoma the manager is sometimes stored 8 bytes before the usual slot.
        if (dp_desktop_picture_manager == nil) {
            dp_desktop_picture_manager = [(*(id *)(dppm_addr + off + 0x4 - 0x8)) retain];
        }
#elif __arm64__
        uint64_t off = decode_adrp_add(dppm_addr, dppm_addr - baseaddr);
        dp_desktop_picture_manager = [(*(id *)(baseaddr + off)) retain];
        if (dp_desktop_picture_manager == nil) {
            dp_desktop_picture_manager = [(*(id *)(baseaddr + off - 0x8)) retain];
        }
#endif
    }

    // On arm64e the Dock calls these through PAC-signed pointers, so sign the found address with
    // the A-instruction key; on Intel there is no PAC and the raw address is called directly.
    uint64_t add_addr = hex_find_seq(baseaddr + get_add_space_offset(os_version), get_add_space_pattern(os_version));
    uint64_t rem_addr = hex_find_seq(baseaddr + get_remove_space_offset(os_version), get_remove_space_pattern(os_version));
    uint64_t mov_addr = hex_find_seq(baseaddr + get_move_space_offset(os_version), get_move_space_pattern(os_version));
#ifdef __arm64__
    add_space_fp = add_addr ? (uint64_t) ptrauth_sign_unauthenticated((void *) add_addr, ptrauth_key_asia, 0) : 0;
    remove_space_fp = rem_addr ? (uint64_t) ptrauth_sign_unauthenticated((void *) rem_addr, ptrauth_key_asia, 0) : 0;
    move_space_fp = mov_addr ? (uint64_t) ptrauth_sign_unauthenticated((void *) mov_addr, ptrauth_key_asia, 0) : 0;
#else
    add_space_fp = add_addr;
    remove_space_fp = rem_addr;
    move_space_fp = mov_addr;
#endif

    NSLog(@"[atelier-sa] spaces=%p dppm=%p add=%llx rem=%llx mov=%llx",
          dock_spaces, dp_desktop_picture_manager, add_space_fp, remove_space_fp, move_space_fp);
}

// MARK: - Dock object helpers (ported from yabai)

static inline id get_ivar_value(id instance, const char *name)
{
    id result = nil;
    object_getInstanceVariable(instance, name, (void **) &result);
    return result;
}

static inline void set_ivar_value(id instance, const char *name, id value)
{
    object_setInstanceVariable(instance, name, value);
}

static inline uint64_t get_space_id(id space)
{
    return ((uint64_t (*)(id, SEL)) objc_msgSend)(space, @selector(spid));
}

static inline id space_for_display_with_id(CFStringRef display_uuid, uint64_t space_id)
{
    NSArray *spaces_for_display = ((NSArray *(*)(id, SEL, CFStringRef)) objc_msgSend)(dock_spaces, @selector(spacesForDisplay:), display_uuid);
    for (id space in spaces_for_display) {
        if (space_id == get_space_id(space)) return space;
    }
    return nil;
}

static inline id display_space_for_display_uuid(CFStringRef display_uuid)
{
    NSArray *display_spaces = get_ivar_value(dock_spaces, "_displaySpaces");
    if (display_spaces != nil) {
        for (id display_space in display_spaces) {
            id current = get_ivar_value(display_space, "_currentSpace");
            uint64_t sid = get_space_id(current);
            CFStringRef uuid = SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), sid);
            bool match = CFEqual(uuid, display_uuid);
            CFRelease(uuid);
            if (match) return display_space;
        }
    }
    return nil;
}

static inline id display_space_for_space_with_id(uint64_t space_id)
{
    NSArray *display_spaces = get_ivar_value(dock_spaces, "_displaySpaces");
    if (display_spaces != nil) {
        for (id display_space in display_spaces) {
            id current = get_ivar_value(display_space, "_currentSpace");
            if (get_space_id(current) == space_id) return display_space;
        }
    }
    return nil;
}

// MARK: - Window commands

static void do_window_opacity(char *message)
{
    uint32_t wid; unpack(wid);
    if (!wid) return;
    float alpha; unpack(alpha);
    SLSSetWindowAlpha(SLSMainConnectionID(), wid, alpha);
}

struct window_fade_context { uint32_t wid; float alpha; float duration; };

static void *window_fade_thread_proc(void *data)
{
    struct window_fade_context *ctx = (struct window_fade_context *) data;
    float start_alpha = 1.0f;
    SLSGetWindowAlpha(SLSMainConnectionID(), ctx->wid, &start_alpha);

    int frame_duration = 8;
    int total_duration = (int)(ctx->duration * 1000.0f);
    int frame_count = (int)(((float) total_duration / (float) frame_duration) + 1.0f);
    if (frame_count < 1) frame_count = 1;

    for (int i = 1; i <= frame_count; ++i) {
        float t = (float) i / (float) frame_count;
        if (t > 1.0f) t = 1.0f;
        SLSSetWindowAlpha(SLSMainConnectionID(), ctx->wid, lerp(start_alpha, t, ctx->alpha));
        usleep(frame_duration * 1000);
    }
    free(ctx);
    return NULL;
}

static void do_window_opacity_fade(char *message)
{
    uint32_t wid; unpack(wid);
    if (!wid) return;
    float alpha, duration; unpack(alpha); unpack(duration);

    struct window_fade_context *ctx = malloc(sizeof(struct window_fade_context));
    ctx->wid = wid; ctx->alpha = alpha; ctx->duration = duration;
    pthread_t t;
    pthread_create(&t, NULL, &window_fade_thread_proc, ctx);
    pthread_detach(t);
}

static void do_window_layer(char *message)
{
    uint32_t wid; unpack(wid);
    if (!wid) return;
    int layer; unpack(layer);
    SLSSetWindowSubLevel(SLSMainConnectionID(), wid, CGWindowLevelForKey((CGWindowLevelKey) layer));
}

static void do_window_sticky(char *message)
{
    uint32_t wid; unpack(wid);
    if (!wid) return;
    uint8_t value; unpack(value);
    uint64_t tags = (1ULL << 11);
    if (value) SLSSetWindowTags(SLSMainConnectionID(), wid, &tags, 64);
    else       SLSClearWindowTags(SLSMainConnectionID(), wid, &tags, 64);
}

static void do_window_shadow(char *message)
{
    uint32_t wid; unpack(wid);
    if (!wid) return;
    uint8_t value; unpack(value);
    uint64_t tags = (1ULL << 3);
    if (value) SLSClearWindowTags(SLSMainConnectionID(), wid, &tags, 64);
    else       SLSSetWindowTags(SLSMainConnectionID(), wid, &tags, 64);
}

// Scale a window about an anchor point. The anchor (ax, ay) is in GLOBAL screen points with a
// top-left origin, i.e. CGWindowList / SLSGetWindowBounds coordinates. The anchor screen point
// stays fixed while the window shrinks/grows by `scale`. scale == 1 (or <= 0) restores the
// window to its untransformed position (identity translate to the window's own origin).
static void do_window_scale(char *message)
{
    uint32_t wid; unpack(wid);
    if (!wid) return;
    float scale, ax, ay; unpack(scale); unpack(ax); unpack(ay);

    CGRect frame = {};
    SLSGetWindowBounds(SLSMainConnectionID(), wid, &frame);

    CGAffineTransform identity = CGAffineTransformMakeTranslation(-frame.origin.x, -frame.origin.y);
    if (scale == 1.0f || scale <= 0.0f) {
        SLSSetWindowTransform(SLSMainConnectionID(), wid, identity);
        return;
    }

    // Scale about (ax, ay): translate anchor to origin in the window's local space, scale,
    // translate back, then fold in the window-origin offset the server expects.
    CGFloat s = 1.0 / scale;                 // SLS transforms map screen->window, so invert.
    CGFloat lx = ax - frame.origin.x;
    CGFloat ly = ay - frame.origin.y;
    CGAffineTransform t = CGAffineTransformMakeTranslation(-frame.origin.x, -frame.origin.y);
    t = CGAffineTransformTranslate(t, lx, ly);
    t = CGAffineTransformScale(t, s, s);
    t = CGAffineTransformTranslate(t, -lx, -ly);
    SLSSetWindowTransform(SLSMainConnectionID(), wid, t);
}

static void do_window_move_to_space(char *message)
{
    uint64_t sid; unpack(sid);
    uint32_t wid; unpack(wid);
    CFNumberRef num = CFNumberCreate(NULL, kCFNumberSInt32Type, &wid);
    CFArrayRef list = CFArrayCreate(NULL, (const void **)&num, 1, &kCFTypeArrayCallBacks);
    SLSMoveWindowsToManagedSpace(SLSMainConnectionID(), list, sid);
    CFRelease(list);
    CFRelease(num);
}

// MARK: - Spaces commands

static void do_space_focus(char *message)
{
    if (dock_spaces == nil) return;
    uint64_t dest_space_id; unpack(dest_space_id);
    if (!dest_space_id) return;

    CFStringRef dest_display = SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), dest_space_id);
    id source_space = ((id (*)(id, SEL, CFStringRef)) objc_msgSend)(dock_spaces, @selector(currentSpaceForDisplayUUID:), dest_display);
    uint64_t source_space_id = get_space_id(source_space);

    if (source_space_id != dest_space_id) {
        id dest_space = space_for_display_with_id(dest_display, dest_space_id);
        if (dest_space != nil) {
            id display_space = display_space_for_space_with_id(source_space_id);
            if (display_space != nil) {
                NSArray *ns_source = @[ @(source_space_id) ];
                NSArray *ns_dest = @[ @(dest_space_id) ];
                SLSShowSpaces(SLSMainConnectionID(), (__bridge CFArrayRef) ns_dest);
                SLSHideSpaces(SLSMainConnectionID(), (__bridge CFArrayRef) ns_source);
                SLSManagedDisplaySetCurrentSpace(SLSMainConnectionID(), dest_display, dest_space_id);
                set_ivar_value(display_space, "_currentSpace", [dest_space retain]);
            }
        }
    }
    CFRelease(dest_display);
}

static uint64_t do_space_create(char *message)
{
    uint32_t display_arg; unpack(display_arg);     // reserved: create on the active display
    if (dock_spaces == nil || add_space_fp == 0) return 0;

    uint64_t active = SLSGetActiveSpace(SLSMainConnectionID());
    CFStringRef __block display_uuid = SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), active);

    dispatch_sync(dispatch_get_main_queue(), ^{
        id new_space = [[objc_getClass("ManagedSpace") alloc] init];
        id display_space = display_space_for_display_uuid(display_uuid);
        asm__call_add_space(new_space, display_space, add_space_fp);
    });

    // Best effort: the newly added space is the last one for the display.
    uint64_t created = 0;
    NSArray *spaces = ((NSArray *(*)(id, SEL, CFStringRef)) objc_msgSend)(dock_spaces, @selector(spacesForDisplay:), display_uuid);
    if (spaces.count) created = get_space_id([spaces lastObject]);
    CFRelease(display_uuid);
    return created;
}

typedef void (*remove_space_call)(id space, id display_space, id dock_spaces, uint64_t a, uint64_t b);
static void do_space_destroy(char *message)
{
    if (dock_spaces == nil || remove_space_fp == 0) return;
    uint64_t space_id; unpack(space_id);

    CFStringRef display_uuid = SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), space_id);
    uint64_t active_space_id = SLSManagedDisplayGetCurrentSpace(SLSMainConnectionID(), display_uuid);
    id space = space_for_display_with_id(display_uuid, space_id);
    id display_space = display_space_for_display_uuid(display_uuid);

    dispatch_sync(dispatch_get_main_queue(), ^{
        ((remove_space_call) remove_space_fp)(space, display_space, dock_spaces, space_id, space_id);
    });

    if (active_space_id == space_id) {
        uint64_t dest = SLSManagedDisplayGetCurrentSpace(SLSMainConnectionID(), display_uuid);
        id dest_space = space_for_display_with_id(display_uuid, dest);
        set_ivar_value(display_space, "_currentSpace", [dest_space retain]);
    }
    CFRelease(display_uuid);
}

static void do_space_move(char *message)
{
    if (dock_spaces == nil || dp_desktop_picture_manager == nil || move_space_fp == 0) return;
    uint64_t source_space_id, dest_space_id, source_prev_space_id;
    unpack(source_space_id); unpack(dest_space_id); unpack(source_prev_space_id);
    uint8_t focus_dest; unpack(focus_dest);

    CFStringRef source_display_uuid = SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), source_space_id);
    id source_space = space_for_display_with_id(source_display_uuid, source_space_id);
    CFStringRef dest_display_uuid = SLSCopyManagedDisplayForSpace(SLSMainConnectionID(), dest_space_id);
    id dest_space = space_for_display_with_id(dest_display_uuid, dest_space_id);
    unsigned dest_display_id = ((unsigned (*)(id, SEL, id)) objc_msgSend)(dock_spaces, @selector(displayIDForSpace:), dest_space);

    asm__call_move_space(source_space, dest_space, dest_display_uuid, dock_spaces, move_space_fp);

    dispatch_sync(dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, id, unsigned, CFStringRef)) objc_msgSend)(dp_desktop_picture_manager, @selector(moveSpace:toDisplay:displayUUID:), source_space, dest_display_id, dest_display_uuid);
    });

    CFRelease(source_display_uuid);
    CFRelease(dest_display_uuid);
}

// MARK: - Handshake + dispatch

static void send_handshake(int sockfd)
{
    uint32_t attrib = 0;
    if (dock_spaces != nil)                attrib |= OSAX_ATTRIB_DOCK_SPACES;
    if (dp_desktop_picture_manager != nil) attrib |= OSAX_ATTRIB_DPPM;
    if (add_space_fp)                      attrib |= OSAX_ATTRIB_ADD_SPACE;
    if (remove_space_fp)                   attrib |= OSAX_ATTRIB_REM_SPACE;
    if (move_space_fp)                     attrib |= OSAX_ATTRIB_MOV_SPACE;

    char bytes[256] = {};
    int version_length = strlen(OSAX_VERSION);
    memcpy(bytes, OSAX_VERSION, version_length);
    bytes[version_length] = '\0';
    memcpy(bytes + version_length + 1, &attrib, sizeof(uint32_t));
    send(sockfd, bytes, version_length + 1 + sizeof(uint32_t), 0);
}

static void ack(int sockfd) { char ok = 0x01; send(sockfd, &ok, 1, 0); }

static void handle_message(int sockfd, char *message)
{
    enum sa_opcode op = *message++;
    switch (op) {
    case SA_OPCODE_HANDSHAKE:        send_handshake(sockfd); break;
    case SA_OPCODE_HEARTBEAT: {
        uint32_t v = SA_PROTOCOL_VERSION;
        char reply[5]; reply[0] = 0x01; memcpy(reply + 1, &v, sizeof(v));
        send(sockfd, reply, sizeof(reply), 0);
    } break;
    case SA_OPCODE_SPACE_FOCUS:      do_space_focus(message); ack(sockfd); break;
    case SA_OPCODE_SPACE_CREATE: {
        uint64_t sid = do_space_create(message);
        char reply[9]; reply[0] = sid ? 0x01 : 0x00; memcpy(reply + 1, &sid, sizeof(sid));
        send(sockfd, reply, sizeof(reply), 0);
    } break;
    case SA_OPCODE_SPACE_DESTROY:    do_space_destroy(message); ack(sockfd); break;
    case SA_OPCODE_SPACE_MOVE:       do_space_move(message); ack(sockfd); break;
    case SA_OPCODE_WINDOW_TO_SPACE:  do_window_move_to_space(message); ack(sockfd); break;
    case SA_OPCODE_WINDOW_OPACITY:   do_window_opacity(message); ack(sockfd); break;
    case SA_OPCODE_WINDOW_OPACITY_FADE: do_window_opacity_fade(message); ack(sockfd); break;
    case SA_OPCODE_WINDOW_LAYER:     do_window_layer(message); ack(sockfd); break;
    case SA_OPCODE_WINDOW_STICKY:    do_window_sticky(message); ack(sockfd); break;
    case SA_OPCODE_WINDOW_SHADOW:    do_window_shadow(message); ack(sockfd); break;
    case SA_OPCODE_WINDOW_SCALE:     do_window_scale(message); ack(sockfd); break;
    default: break;
    }
}

static inline bool read_message(int sockfd, char *message)
{
    int bytes_read = 0;
    int16_t bytes_to_read = 0;

    if (read(sockfd, &bytes_to_read, sizeof(int16_t)) == sizeof(int16_t)) {
        if (bytes_to_read >= SA_SOCKET_BUFF_LEN) return false;
        if (bytes_to_read <= 0)                  return false;
        do {
            int cur = read(sockfd, message + bytes_read, bytes_to_read - bytes_read);
            if (cur <= 0) break;
            bytes_read += cur;
        } while (bytes_read < bytes_to_read);
        return bytes_read == bytes_to_read;
    }
    return false;
}

// Only accept connections from the same uid that owns the socket.
static bool peer_is_owner(int sockfd)
{
    uid_t euid = 0; gid_t egid = 0;
    if (getpeereid(sockfd, &euid, &egid) != 0) return false;
    return euid == getuid();
}

static void *handle_connection(void *unused)
{
    (void) unused;
    for (;;) {
        int sockfd = accept(daemon_sockfd, NULL, 0);
        if (sockfd == -1) continue;

        if (peer_is_owner(sockfd)) {
            char message[SA_SOCKET_BUFF_LEN];
            if (read_message(sockfd, message)) handle_message(sockfd, message);
        }
        shutdown(sockfd, SHUT_RDWR);
        close(sockfd);
    }
    return NULL;
}

static bool start_daemon(const char *socket_path)
{
    struct sockaddr_un addr;
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", socket_path);
    unlink(socket_path);

    if ((daemon_sockfd = socket(AF_UNIX, SOCK_STREAM, 0)) == -1) return false;
    if (bind(daemon_sockfd, (struct sockaddr *) &addr, sizeof(addr)) == -1) return false;
    if (chmod(socket_path, 0600) != 0) return false;
    if (listen(daemon_sockfd, SOMAXCONN) == -1) return false;

    init_instances();
    pthread_create(&daemon_thread, NULL, &handle_connection, NULL);
    return true;
}

__attribute__((constructor))
void load_payload(void)
{
    NSLog(@"[atelier-sa] payload loaded (v%s, proto %d)", OSAX_VERSION, SA_PROTOCOL_VERSION);

    char socket_file[255];
    snprintf(socket_file, sizeof(socket_file), SA_SOCKET_PATH_FMT, getuid());

    if (start_daemon(socket_file)) NSLog(@"[atelier-sa] listening on %s", socket_file);
    else                          NSLog(@"[atelier-sa] failed to start daemon");
}
