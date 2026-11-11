#ifndef ATELIER_SA_COMMON_H
#define ATELIER_SA_COMMON_H

//
// Atelier Dock Bridge — shared wire protocol.
//
// Ported from koekeishiya/yabai (MIT), src/osax/common.h.
// Original work: Copyright (c) 2019 Asmund Vikane. MIT License.
// Adapted for Atelier: bundle name, per-uid socket path, Atelier opcode numbering, a
// protocol version, and a heartbeat.
//
// The socket is per-uid and created 0600; the payload verifies the peer's uid on connect.
//

#define SA_SOCKET_PATH_FMT   "/tmp/atelier-sa_%d.socket"
#define SA_SOCKET_BUFF_LEN   0x1000

// Payload build version. The client compares this against the installed bundle's
// CFBundleVersion and the handshake reply.
#define OSAX_VERSION         "1.0.0"

// Wire protocol version. Bump on any framing change. Must match bridgeProtocolVersion in Swift.
#define SA_PROTOCOL_VERSION  1

// Attribute mask: which Dock internals the payload located by pattern scanning. Window opacity,
// level, sticky, shadow and scale use public-ish SkyLight SPI and never need these; the Spaces
// commands do.
#define OSAX_ATTRIB_DOCK_SPACES  0x01
#define OSAX_ATTRIB_DPPM         0x02
#define OSAX_ATTRIB_ADD_SPACE    0x04
#define OSAX_ATTRIB_REM_SPACE    0x08
#define OSAX_ATTRIB_MOV_SPACE    0x10

#define OSAX_ATTRIB_ALL (OSAX_ATTRIB_DOCK_SPACES | OSAX_ATTRIB_DPPM | \
                         OSAX_ATTRIB_ADD_SPACE | OSAX_ATTRIB_REM_SPACE | OSAX_ATTRIB_MOV_SPACE)

// Opcodes. Values MUST match BridgeOpcode in Sources/DockCore/BridgeWire.swift.
enum sa_opcode
{
    SA_OPCODE_HANDSHAKE        = 0x01,
    SA_OPCODE_HEARTBEAT        = 0x02,
    SA_OPCODE_SPACE_FOCUS      = 0x03,
    SA_OPCODE_SPACE_CREATE     = 0x04,
    SA_OPCODE_SPACE_DESTROY    = 0x05,
    SA_OPCODE_SPACE_MOVE       = 0x06,
    SA_OPCODE_WINDOW_TO_SPACE  = 0x07,
    SA_OPCODE_WINDOW_OPACITY   = 0x08,
    SA_OPCODE_WINDOW_OPACITY_FADE = 0x09,
    SA_OPCODE_WINDOW_LAYER     = 0x0A,
    SA_OPCODE_WINDOW_STICKY    = 0x0B,
    SA_OPCODE_WINDOW_SHADOW    = 0x0C,
    SA_OPCODE_WINDOW_SCALE     = 0x0D,
};

#endif
