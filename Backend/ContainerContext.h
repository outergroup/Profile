#ifndef CONTAINER_CONTEXT_H
#define CONTAINER_CONTEXT_H
#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dirent.h>
#include <ctype.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>
#include <pthread.h>
#include <glob.h>
#include <errno.h>
#include <fcntl.h>

typedef struct {
    char id[65];
    char name[128];
    int local_pid;
} ContainerContext;
static ContainerContext container_host(void) {
    return (ContainerContext){.id="host", .name="Host"};
}
#ifdef __linux__
static ContainerContext container_names[1024];
static size_t container_name_count;
static pthread_mutex_t container_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t container_u32(const unsigned char *p) {
    return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24;
}
static bool container_exact(int fd, void *data, size_t size) {
    while (size) {
        ssize_t n=read(fd,data,size);
        if (n<0 && errno==EINTR) continue;
        if (n<=0) return false;
        data=(char *)data+n; size-=(size_t)n;
    }
    return true;
}
static bool container_string(const unsigned char *b, size_t size, size_t field, size_t variable, char *out, size_t cap) {
    size_t offset=container_u32(b+field), length=container_u32(b+field+4);
    if (offset<variable || offset>size || length>size-offset || length>=cap || memchr(b+offset,0,length)) return false;
    memcpy(out,b+offset,length); out[length]=0; return true;
}
static void container_registry(const char *path, ContainerContext *names, size_t *count) {
    struct sockaddr_un address={.sun_family=AF_UNIX};
    if (strlen(path)>=sizeof(address.sun_path)) return;
    strcpy(address.sun_path,path);
    int fd=socket(AF_UNIX,SOCK_STREAM|SOCK_CLOEXEC,0);
    if (fd<0) return;
    struct timeval timeout={.tv_sec=5};
    setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
    unsigned char header[4], request[]={2,0,0,0,34,0};
    unsigned char *body=NULL;
    if (connect(fd,(struct sockaddr *)&address,sizeof(address)) || send(fd,request,sizeof(request),MSG_NOSIGNAL)!=sizeof(request) || !container_exact(fd,header,4)) goto done;
    size_t size=container_u32(header);
    if (size<48 || size>16*1024*1024) goto done;
    body=malloc(size);
    if (!body || !container_exact(fd,body,size)) goto done;
    size_t rows=container_u32(body+12), variable=container_u32(body+24);
    if (memcmp(body,"OSED",4) || container_u32(body+4)!=1 || container_u32(body+8)!=size || container_u32(body+16)!=72 || container_u32(body+20)!=48 || variable!=48+rows*72 || variable>size || container_u32(body+28)) goto done;
    for (size_t i=0;i<rows && *count<1024;i++) {
        ContainerContext context={0}; char runtime[64]; size_t row=48+i*72;
        if (!container_string(body,size,row+16,variable,runtime,sizeof(runtime)) || strcmp(runtime,"docker") ||
            !container_string(body,size,row+24,variable,context.id,sizeof(context.id)) || strlen(context.id)!=64 || strspn(context.id,"0123456789abcdef")!=64 ||
            !container_string(body,size,row+8,variable,context.name,sizeof(context.name))) continue;
        names[(*count)++]=context;
    }
done:
    free(body); close(fd);
}
static ContainerContext container_path_context(const char *path, const ContainerContext *names, size_t count) {
    ContainerContext context=container_host();
    for (size_t i=0;i<count;i++) if (strstr(path,names[i].id)) return names[i];
    for (const char *p=path;*p;p++) {
        size_t n=strspn(p,"0123456789abcdef");
        if (n==64) {
            memcpy(context.id,p,64); context.id[64]=0;
            snprintf(context.name,sizeof(context.name),"Container %.12s",context.id); return context;
        }
        if (n) p+=n-1;
    }
    return context;
}
static void *container_worker(void *unused) {
    (void)unused;
    for (;;) {
        ContainerContext *names=calloc(1024,sizeof(*names));
        if (!names) { sleep(5); continue; }
        size_t count=0;
        const char *override=getenv("OUTERSHELLD_API_SOCKET");
        char path[256];
        snprintf(path,sizeof(path),"/run/user/%u/outershelld-api",(unsigned)geteuid());
        container_registry(override && *override ? override : geteuid()==0 ? "/run/outershelld-api" : path,names,&count);
        if (geteuid()==0 && (!override || !*override || !strcmp(override,"/run/outershelld-api"))) {
            glob_t paths={0};
            if (!glob("/run/user/*/outershelld-api",0,NULL,&paths))
                for (size_t i=0;i<paths.gl_pathc;i++) container_registry(paths.gl_pathv[i],names,&count);
            globfree(&paths);
        }
        pthread_mutex_lock(&container_lock);
        memcpy(container_names,names,count*sizeof(*names)); container_name_count=count;
        pthread_mutex_unlock(&container_lock);
        free(names); sleep(5);
    }
    return NULL;
}
static void container_start(void) {
    pthread_t thread;
    int error=pthread_create(&thread,NULL,container_worker,NULL);
    if (error) fprintf(stderr,"Container discovery: %s\n",strerror(error));
    else pthread_detach(thread);
}
#endif
static ContainerContext container_for_pid(int pid) {
    ContainerContext context=container_host(); context.local_pid=pid;
#ifdef __linux__
    char path[128], line[4096]; snprintf(path,sizeof(path),"/proc/%d/cgroup",pid);
    FILE *file=fopen(path,"r");
    if (!file) { strcpy(context.id,"unknown"); strcpy(context.name,"Unknown"); return context; }
    pthread_mutex_lock(&container_lock);
    while (fgets(line,sizeof(line),file)) {
        ContainerContext candidate=container_path_context(line,container_names,container_name_count);
        if (strcmp(candidate.id,"host")) { context=candidate; context.local_pid=pid; break; }
    }
    pthread_mutex_unlock(&container_lock); fclose(file);
    snprintf(path,sizeof(path),"/proc/%d/status",pid); file=fopen(path,"r");
    if (file) {
        while (fgets(line,sizeof(line),file)) if (!strncmp(line,"NSpid:",6)) {
            char *p=line+6,*end;
            for (;;) { long value=strtol(p,&end,10); if (end==p) break; if (value>0 && value<=2147483647) context.local_pid=(int)value; p=end; }
            break;
        }
        fclose(file);
    }
#endif
    return context;
}
#ifndef __linux__
static void container_start(void) {}
#endif
static uint64_t container_process_start(int pid) {
#ifdef __linux__
    char path[128], text[8192]; snprintf(path,sizeof(path),"/proc/%d/stat",pid);
    FILE *file=fopen(path,"r"); if (!file) return 0;
    bool ok=fgets(text,sizeof(text),file)!=NULL; fclose(file); if (!ok) return 0;
    char *end=strrchr(text,')'); if (!end) return 0;
    char *save=NULL,*field=strtok_r(end+2," ",&save);
    for (int i=3;field && i<22;i++) field=strtok_r(NULL," ",&save);
    return field ? strtoull(field,NULL,10) : 0;
#else
    (void)pid; return 0;
#endif
}
#endif
