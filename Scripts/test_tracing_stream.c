#include <assert.h>
#include "../Backend/TracingStream.h"
int main(void) {
    int pipes[2]; assert(!pipe(pipes));
    unsigned char payload[]={0,1,255,0,17};
    assert(tracing_frame_write(pipes[1],42,payload,sizeof(payload)));
    uint32_t id=0;size_t length=0;
    unsigned char *body=tracing_frame_read(pipes[0],&id,&length);
    assert(body&&id==42&&length==sizeof(payload)&&!memcmp(body,payload,length));free(body);
    assert(!tracing_frame_write(pipes[1],1,payload,16777217));
    unsigned char bad[24]={0};memcpy(bad,"TRPC",4);
    tracing_put32(bad+4,1);tracing_put32(bad+8,24);tracing_put32(bad+16,28);
    assert(write(pipes[1],bad,24)==24);
    assert(!tracing_frame_read(pipes[0],&id,&length));
    close(pipes[1]);assert(!tracing_frame_read(pipes[0],&id,&length));close(pipes[0]);
    puts("PASS binary frame round trip, payload bounds, invalid offsets, and EOF");
}
