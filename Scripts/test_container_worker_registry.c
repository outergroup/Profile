#define _GNU_SOURCE
#include <assert.h>
#include <utime.h>
#include "ContainerContext.h"
int main(void) {
    char path[]="/tmp/tracing-registry-XXXXXX";
    int fd=mkstemp(path);assert(fd>=0);
    setenv("OUTER_CONTAINER_REGISTRY",path,1);
    const char *id="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    unsigned char body[200]={0},header[4]={200,0,0,0};
    memcpy(body,"OSED",4);body[4]=1;body[8]=200;body[12]=1;body[16]=72;body[20]=48;body[24]=120;
    body[56]=120;body[60]=4;memcpy(body+120,"Test",4);
    body[64]=124;body[68]=6;memcpy(body+124,"docker",6);
    body[72]=130;body[76]=64;memcpy(body+130,id,64);
    assert(write(fd,header,4)==4);assert(write(fd,body,200)==200);close(fd);
    ContainerContext names[1024];size_t count=0;
    container_registry("unused",names,&count);assert(count==1);assert(!strcmp(names[0].name,"Test"));
    assert(!strcmp(container_path_context(id,names,count).id,id));
    assert(!strcmp(container_path_context("/system.slice/init.scope",names,count).id,"host"));
    assert(!strcmp(container_path_context("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",names,count).id,"host"));
    struct utimbuf old={.actime=1,.modtime=1};assert(!utime(path,&old));count=0;container_registry("unused",names,&count);assert(count==0);
    unlink(path);puts("Container registry scope and expiry checks passed");return 0;
}
