#include "NativeMIDI.h"
#include <mach/mach_time.h>
#include <stdlib.h>

struct NMConnection {
 MIDIClientRef client;
 MIDIPortRef input, output;
 MIDIEndpointRef destination;
 NMReceive receive;
 void *context;
 uint8_t storage[1024];
};
static void received(const MIDIPacketList *list, void *context, void *source) {
 NMConnection *connection = context;
 const MIDIPacket *packet = &list->packet[0];
 for(UInt32 n=0;n<list->numPackets;n++) {
  connection->receive(packet->data,packet->length,connection->context);
  packet=MIDIPacketNext(packet);
 }
}
NMConnection *NMOpen(MIDIEndpointRef destination,const MIDIEndpointRef *sources,size_t count,NMReceive receive,void *context,OSStatus *error) {
 NMConnection *c=calloc(1,sizeof(NMConnection));
 if(!c){*error=-1;return NULL;}
 c->destination=destination;c->receive=receive;c->context=context;
 *error=MIDIClientCreate(CFSTR("SMK25II Lights"),NULL,NULL,&c->client);
 if(!*error)*error=MIDIInputPortCreate(c->client,CFSTR("Lights replies"),received,c,&c->input);
 if(!*error)*error=MIDIOutputPortCreate(c->client,CFSTR("Lights output"),&c->output);
 for(size_t i=0;!*error&&i<count;i++)*error=MIDIPortConnectSource(c->input,sources[i],NULL);
 if(*error){NMClose(c);return NULL;}
 return c;
}
OSStatus NMSend(NMConnection *c,const uint8_t *bytes,size_t length) {
 if(!c||!bytes||length>256)return -1;
 MIDIPacketList *list=(MIDIPacketList*)c->storage;
 MIDIPacket *packet=MIDIPacketListInit(list);
 if(!MIDIPacketListAdd(list,sizeof(c->storage),packet,mach_absolute_time(),length,bytes))return -1;
 return MIDISend(c->output,c->destination,list);
}
void NMClose(NMConnection *c){if(c){if(c->client)MIDIClientDispose(c->client);free(c);}}
