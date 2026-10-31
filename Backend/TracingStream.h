#ifndef OUTER_TRACING_STREAM_H
#define OUTER_TRACING_STREAM_H
#include <stdint.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <poll.h>

static int tracing_transfer(int fd, void *bytes, size_t size, int writing) {
    char *p=bytes;
    while(size) {
        ssize_t n=writing?write(fd,p,size):read(fd,p,size);
        if(n<0&&errno==EINTR) continue;
        if(n<=0) return 0;
        p+=n;size-=(size_t)n;
    }
    return 1;
}
static uint32_t tracing_u32(const unsigned char *p) {
    return (uint32_t)p[0]|(uint32_t)p[1]<<8|(uint32_t)p[2]<<16|(uint32_t)p[3]<<24;
}
static void tracing_put32(unsigned char *p,uint32_t n) {
    for(int i=0;i<4;i++) p[i]=(unsigned char)(n>>(8*i));
}
/* A frame is TRPC, version, byte length, request ID, payload offset, payload length. */
static int tracing_frame_write(int fd,uint32_t id,const void *body,size_t length) {
    if(length>16777216) return 0;
    unsigned char header[24]={0};memcpy(header,"TRPC",4);
    tracing_put32(header+4,1);tracing_put32(header+8,(uint32_t)(24+length));
    tracing_put32(header+12,id);tracing_put32(header+16,24);tracing_put32(header+20,(uint32_t)length);
    return tracing_transfer(fd,header,24,1)&&tracing_transfer(fd,(void *)body,length,1);
}
static unsigned char *tracing_frame_read(int fd,uint32_t *id,size_t *length) {
    unsigned char header[24];
    if(!tracing_transfer(fd,header,24,0)||memcmp(header,"TRPC",4)||tracing_u32(header+4)!=1||
       tracing_u32(header+16)!=24||tracing_u32(header+20)>16777216||
       tracing_u32(header+8)!=24+tracing_u32(header+20)) return NULL;
    *id=tracing_u32(header+12);*length=tracing_u32(header+20);
    unsigned char *body=malloc(*length+1);if(!body) return NULL;
    if(!tracing_transfer(fd,body,*length,0)){free(body);return NULL;}body[*length]=0;return body;
}
static void tracing_stop_child(pid_t child) {
    if (child <= 0) return;
    kill(child, SIGTERM);
    for (int i = 0; i < 100; i++) {
        pid_t result = waitpid(child, NULL, WNOHANG);
        if (result == child || (result < 0 && errno == ECHILD)) return;
        usleep(10000);
    }
    kill(child, SIGKILL);
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
}
#ifdef __linux__
#include <sys/mount.h>
static int tracing_serve(const char *executable,const char *app) {
    char temporary[]="/tmp/outer-tracing-XXXXXX";
    char path[108];
    const char *existing=getenv("OUTER_TRACING_SOCKET");
    if(existing&&*existing) {
        if(strlen(existing)>=sizeof(path)) return 1;
        snprintf(path,sizeof(path),"%s",existing);
    } else {
        if(!mkdtemp(temporary)) return 1;
        snprintf(path,sizeof(path),"%s/socket",temporary);
    }
    char tracefs[128] = "";
    if (!existing && !strcmp(app, "Firehose") && access("/sys/kernel/tracing/events", R_OK) &&
        access("/sys/kernel/debug/tracing/events", R_OK)) {
        snprintf(tracefs, sizeof(tracefs), "%s/tracefs", temporary);
        if (!mkdir(tracefs, 0700) && !mount("tracefs", tracefs, "tracefs", 0, NULL))
            setenv("OUTER_TRACEFS", tracefs, 1);
    }
    pid_t child=existing?0:fork();
    if(child<0){rmdir(temporary);return 1;}
    if(!child&&!existing) {
        dup2(STDERR_FILENO,STDOUT_FILENO);
        if(!strcmp(app,"Profile")) {
            const char *home=getenv("HOME");if(!home) home="/tmp";
            char state[4096];snprintf(state,sizeof(state),"%s/.local/state/outer-profile-helper",home);
            execl(executable,executable,"--socket-path",path,"--state-dir",state,(char *)NULL);
        } else execl(executable,executable,"--socket-path",path,(char *)NULL);
        _exit(127);
    }
    int ready=0;
    for(int i=0;i<100;i++) {
        if(!access(path,F_OK)){ready=1;break;}
        if(child&&waitpid(child,NULL,WNOHANG)==child){child=0;break;}
        usleep(100000);
    }
    if(ready) for(;;) {
        uint32_t id;size_t length;
        unsigned char *request=tracing_frame_read(STDIN_FILENO,&id,&length);if(!request) break;
        struct sockaddr_un address={.sun_family=AF_UNIX};strcpy(address.sun_path,path);
        int fd=socket(AF_UNIX,SOCK_STREAM,0);
        if(fd<0||connect(fd,(struct sockaddr *)&address,sizeof(address))||!tracing_transfer(fd,request,length,1)) {
            free(request);if(fd>=0)close(fd);break;
        }
        free(request);shutdown(fd,SHUT_WR);
        size_t used=0,capacity=65536;unsigned char *response=malloc(capacity);int ok=response!=NULL;
        while(ok) {
            if(used==capacity) {
                if(capacity>=16777216){ok=0;break;}
                capacity*=2;void *next=realloc(response,capacity);if(!next){ok=0;break;}response=next;
            }
            ssize_t n=read(fd,response+used,capacity-used);
            if(n<0&&errno==EINTR)continue;
            if(n<0){ok=0;break;}if(!n)break;used+=(size_t)n;
        }
        close(fd);
        if(ok)ok=tracing_frame_write(STDOUT_FILENO,id,response,used);
        free(response);if(!ok)break;
    }
    if(existing) return ready?0:1;
    tracing_stop_child(child);
    if (*tracefs) { umount(tracefs); rmdir(tracefs); }
    unlink(path);rmdir(temporary);return ready?0:1;
}
#endif
#endif
