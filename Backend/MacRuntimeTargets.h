#ifndef MAC_RUNTIME_TARGETS_H
#define MAC_RUNTIME_TARGETS_H
#include "TracingStream.h"
#include <ctype.h>

#define TRACING_WORKER_SOCKET "/run/outer-tracing/worker.sock"
typedef struct { char provider[32],id[257],name[256],state[32]; } TracingTarget;
static char resource_directory[PATH_MAX];
static _Thread_local bool runtime_head_request;
static pthread_mutex_t target_mutex=PTHREAD_MUTEX_INITIALIZER;
typedef struct { char key[320];pid_t pid;int input,output;uint32_t sequence; } TracingSession;
static TracingSession target_sessions[32];

static int target_ref(const unsigned char *b,size_t length,size_t field,size_t variable,char *out,size_t cap) {
    if(field+8>length) return 0;
    size_t offset=tracing_u32(b+field),size=tracing_u32(b+field+4);
    if(offset<variable||offset>length||size>length-offset||size>=cap||memchr(b+offset,0,size))return 0;
    memcpy(out,b+offset,size);out[size]=0;return 1;
}
static size_t runtime_targets(TracingTarget *targets,size_t capacity) {
    char path[PATH_MAX];snprintf(path,sizeof(path),"%s/registry.bin",state);
    FILE *f=fopen(path,"rb");if(!f)return 0;
    struct stat st;unsigned char header[4];
    if(fstat(fileno(f),&st)||time(NULL)-st.st_mtime>15||fread(header,1,4,f)!=4){fclose(f);return 0;}
    size_t size=tracing_u32(header);if(size<48||size>16777216){fclose(f);return 0;}
    unsigned char *body=malloc(size);if(!body){fclose(f);return 0;}
    int ok=fread(body,1,size,f)==size;fclose(f);size_t count=0;
    if(ok&&!memcmp(body,"OSED",4)&&tracing_u32(body+4)==1&&tracing_u32(body+8)==size&&tracing_u32(body+16)==72&&tracing_u32(body+20)==48&&!tracing_u32(body+28)) {
        size_t rows=tracing_u32(body+12),variable=tracing_u32(body+24);
        if(rows<=(size-48)/72&&variable==48+rows*72)for(size_t i=0;i<rows&&count<capacity;i++) {
            TracingTarget target={0};size_t row=48+i*72;
            if(!target_ref(body,size,row+8,variable,target.name,sizeof(target.name))||
               !target_ref(body,size,row+16,variable,target.provider,sizeof(target.provider))||
               !target_ref(body,size,row+24,variable,target.id,sizeof(target.id))||
               !target_ref(body,size,row+32,variable,target.state,sizeof(target.state)))continue;
            if(strcmp(target.provider,"docker")&&strcmp(target.provider,"apple.container")&&strcmp(target.provider,"wslc"))continue;
            if(!target.id[0]||strspn(target.id,"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")!=strlen(target.id))continue;
            targets[count++]=target;
        }
    }
    free(body);return count;
}
static void runtime_response(int fd,int status,const char *type,const void *body,size_t length) {
    char header[256];int n=snprintf(header,sizeof(header),"HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\nConnection: close\r\n\r\n",status,status==200?"OK":"Unavailable",type,length);
    transfer(fd,header,(size_t)n,true);if(length&&!runtime_head_request)transfer(fd,(void *)body,length,true);
}
static void runtime_error(int fd,const char *message) {runtime_response(fd,503,"text/plain; charset=utf-8",message,strlen(message));}
static void runtime_file(int fd,const char *relative,const char *type) {
    if(strstr(relative,"..")){runtime_error(fd,"Invalid resource path");return;}
    char path[PATH_MAX];snprintf(path,sizeof(path),"%s/%s",resource_directory,relative);
    FILE *f=fopen(path,"rb");if(!f){runtime_error(fd,"Resource unavailable");return;}
    struct stat st;if(fstat(fileno(f),&st)||st.st_size<0||st.st_size>128*1024*1024){fclose(f);runtime_error(fd,"Invalid resource");return;}
    char header[256];int n=snprintf(header,sizeof(header),"HTTP/1.1 200 OK\r\nContent-Type: %s\r\nContent-Length: %lld\r\nConnection: close\r\n\r\n",type,(long long)st.st_size);transfer(fd,header,(size_t)n,true);
    if(runtime_head_request){fclose(f);return;}
    char b[65536];size_t count;while((count=fread(b,1,sizeof(b),f)))if(!transfer(fd,b,count,true))break;fclose(f);
}
static void target_session_close(TracingSession *session) {
    if(!session->pid)return;
    close(session->input);close(session->output);
    for(int i=0;i<50;i++) {if(waitpid(session->pid,NULL,WNOHANG)==session->pid){memset(session,0,sizeof(*session));return;}usleep(10000);}
    tracing_stop_child(session->pid);memset(session,0,sizeof(*session));
}
static void targets_close(void) {
    pthread_mutex_lock(&target_mutex);for(int i=0;i<32;i++)target_session_close(&target_sessions[i]);pthread_mutex_unlock(&target_mutex);
}
static unsigned char *target_request(const TracingTarget *target,const char *request,size_t *length) {
    char key[320];snprintf(key,sizeof(key),"%s:%s",target->provider,target->id);
    pthread_mutex_lock(&target_mutex);TracingSession *session=NULL;
    for(int i=0;i<32;i++)if(target_sessions[i].pid&&!strcmp(target_sessions[i].key,key)){session=&target_sessions[i];break;}
    if(!session)for(int i=0;i<32;i++)if(!target_sessions[i].pid){session=&target_sessions[i];break;}
    if(!session){pthread_mutex_unlock(&target_mutex);return NULL;}
    if(!session->pid) {
        const bool docker_worker=!strcmp(target->provider,"docker-worker");
        const char *executable=docker_worker?docker:!strcmp(target->provider,"apple.container")?"/usr/local/bin/container":"/usr/local/bin/wslc";
        if(access(executable,X_OK)){pthread_mutex_unlock(&target_mutex);return NULL;}
        char context[384],name[320],helper[128];
        snprintf(context,sizeof(context),"OUTER_TRACING_CONTEXT_ID=%s",key);
        snprintf(name,sizeof(name),"OUTER_TRACING_CONTEXT_NAME=%s",target->name);
        snprintf(helper,sizeof(helper),"/usr/local/bin/outer-%s-helper",!strcmp(APP_NAME,"Profile")?"profile":"firehose");
        char *helper_args[]={(char *)executable,"exec","--interactive","--user","0","-e",context,"-e",name,(char *)target->id,helper,"serve",NULL};
        char *worker_args[]={(char *)executable,"exec","--interactive","-e","OUTER_TRACING_SOCKET=" TRACING_WORKER_SOCKET,(char *)target->id,"/usr/local/bin/worker","serve",NULL};
        char **args=docker_worker?worker_args:helper_args;
        int input[2],output[2];if(pipe(input)){pthread_mutex_unlock(&target_mutex);return NULL;}
        if(pipe(output)){close(input[0]);close(input[1]);pthread_mutex_unlock(&target_mutex);return NULL;}
        for(int i=0;i<2;i++){fcntl(input[i],F_SETFD,FD_CLOEXEC);fcntl(output[i],F_SETFD,FD_CLOEXEC);}
        posix_spawn_file_actions_t actions;posix_spawn_file_actions_init(&actions);
        posix_spawn_file_actions_adddup2(&actions,input[0],STDIN_FILENO);posix_spawn_file_actions_adddup2(&actions,output[1],STDOUT_FILENO);
        int error=posix_spawn(&session->pid,executable,&actions,NULL,args,environ);posix_spawn_file_actions_destroy(&actions);
        close(input[0]);close(output[1]);
        if(error){close(input[1]);close(output[0]);session->pid=0;pthread_mutex_unlock(&target_mutex);return NULL;}
        session->input=input[1];session->output=output[0];snprintf(session->key,sizeof(session->key),"%s",key);
    }
    unsigned char *result=NULL;uint32_t id=++session->sequence,response_id=0;
    if(tracing_frame_write(session->input,id,request,strlen(request))) {
        struct pollfd pfd={.fd=session->output,.events=POLLIN};
        if(poll(&pfd,1,45000)>0)result=tracing_frame_read(session->output,&response_id,length);
    }
    if(!result||response_id!=id){free(result);result=NULL;target_session_close(session);}
    pthread_mutex_unlock(&target_mutex);return result;
}
static void runtime_picker(int fd) {
    TracingTarget targets[256];size_t count=runtime_targets(targets,256);
    char *html=NULL;size_t length=0;FILE *f=open_memstream(&html,&length);if(!f){runtime_error(fd,"Out of memory");return;}
    fprintf(f,"<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'><title>%s</title><style>body{font:16px system-ui;margin:40px auto;padding:0 24px;max-width:640px;color:CanvasText;background:Canvas;color-scheme:light dark}a{display:block;padding:18px;margin:12px 0;border:1px solid #8886;border-radius:12px;color:inherit;text-decoration:none}small{display:block;opacity:.6;margin-top:6px}</style><h1>%s</h1><p>Choose where to capture.</p><a href='/targets/docker/'>Docker containers<small>All registered containers in Docker’s Linux VM</small></a>",APP_NAME,APP_NAME);
    for(size_t i=0;i<count;i++) {
        if (!strcmp(targets[i].provider,"docker")) continue;
        fprintf(f,"<a href='/targets/%s:%s/'>",targets[i].provider,targets[i].id);
        for(const char *p=targets[i].name;*p;p++)switch(*p){case '&':fputs("&amp;",f);break;case '<':fputs("&lt;",f);break;case '>':fputs("&gt;",f);break;default:fputc(*p,f);}
        fprintf(f,"<small>%s · %s</small></a>",!strcmp(targets[i].provider,"apple.container")?"Apple Container":"WSL containers",!strcmp(targets[i].state,"running")?"running":"stopped");
    }
    if(!count)fputs("<p>No registered containers found. Start a container in Outer Shell, then refresh.</p>",f);
    fclose(f);runtime_response(fd,200,"text/html; charset=utf-8",html,length);free(html);
}
#endif
