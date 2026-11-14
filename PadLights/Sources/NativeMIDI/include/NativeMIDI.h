#pragma once
#include <CoreMIDI/CoreMIDI.h>
#include <stddef.h>
#include <stdint.h>
typedef void (*NMReceive)(const uint8_t*, size_t, void*);
typedef struct NMConnection NMConnection;
NMConnection *NMOpen(MIDIEndpointRef destination, const MIDIEndpointRef *sources, size_t count, NMReceive receive, void *context, OSStatus *error);
OSStatus NMSend(NMConnection *, const uint8_t *, size_t);
void NMClose(NMConnection *);
