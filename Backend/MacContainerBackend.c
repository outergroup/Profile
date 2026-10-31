#define _DARWIN_C_SOURCE
#include <arpa/inet.h>
#include <launch.h>
#include <mach-o/dyld.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
extern char **environ;
#ifndef APP_NAME
#error APP_NAME required
#endif
static volatile sig_atomic_t stopping;
static char state[PATH_MAX], docker[PATH_MAX], worker[128];
static _Atomic bool worker_ready;
static void stop(int sig) { (void)sig; stopping=1; }
static bool transfer(int fd, void *buffer, size_t size, bool writing) {
    char *p=buffer;
    while(size) {
        ssize_t n=writing?write(fd,p,size):read(fd,p,size);
        if(n<0 && errno==EINTR) continue;
        if(n<=0) return false;
        p+=n; size-=(size_t)n;
    }
    return true;
}
static int command(char *const argv[], char *output, size_t capacity) {
    int pipes[2]; if(pipe(pipes)) return -1;
    fcntl(pipes[0],F_SETFD,FD_CLOEXEC);fcntl(pipes[1],F_SETFD,FD_CLOEXEC);
    posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions,pipes[1],STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions,pipes[0]);
    posix_spawn_file_actions_addclose(&actions,pipes[1]);
    pid_t pid; int error=posix_spawn(&pid,argv[0],&actions,NULL,argv,environ);
    posix_spawn_file_actions_destroy(&actions); close(pipes[1]);
    if(error) {close(pipes[0]); return -1;}
    size_t used=0; char buffer[4096]; ssize_t n;
    while((n=read(pipes[0],buffer,sizeof(buffer)))>0) {
        size_t copy=capacity>used+1?capacity-used-1:0;
        if(copy>(size_t)n) copy=(size_t)n;
        if(copy) {memcpy(output+used,buffer,copy); used+=copy;}
    }
    if(capacity) output[used]=0;
    close(pipes[0]); int status;
    while(waitpid(pid,&status,0)<0) if(errno!=EINTR) return -1;
    return WIFEXITED(status)?WEXITSTATUS(status):-1;
}
static void registry_snapshot(void) {
    char path[256]={0};
    char *args[]={"/bin/launchctl","getenv","OUTERSHELL_API_SOCKET_org.outershell.OuterShell",NULL};
    const char *explicit_socket=getenv("OUTERSHELLD_API_SOCKET");
    if(explicit_socket && *explicit_socket) snprintf(path,sizeof(path),"%s",explicit_socket);
    else if(command(args,path,sizeof(path))) return;
    path[strcspn(path,"\r\n")]=0;
    struct sockaddr_un address={.sun_family=AF_UNIX};
    if(!*path || strlen(path)>=sizeof(address.sun_path)) return;
    strcpy(address.sun_path,path);
    int fd=socket(AF_UNIX,SOCK_STREAM,0); if(fd<0) return;
    fcntl(fd,F_SETFD,FD_CLOEXEC);
    struct timeval timeout={.tv_sec=3};
    setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
    unsigned char request[]={2,0,0,0,34,0},header[4];
    if(connect(fd,(struct sockaddr *)&address,sizeof(address)) || !transfer(fd,request,6,true) || !transfer(fd,header,4,false)) {close(fd);return;}
    uint32_t size=(uint32_t)header[0]|(uint32_t)header[1]<<8|(uint32_t)header[2]<<16|(uint32_t)header[3]<<24;
    if(size<48 || size>16*1024*1024) {close(fd);return;}
    unsigned char *body=malloc(size);
    bool ok=body && transfer(fd,body,size,false); close(fd);
    if(ok && !memcmp(body,"OSED",4)) {
        char temporary[PATH_MAX], destination[PATH_MAX];
        snprintf(temporary,sizeof(temporary),"%s/registry.tmp",state);
        snprintf(destination,sizeof(destination),"%s/registry.bin",state);
        int out=open(temporary,O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC,0600);
        if(out>=0) {ok=transfer(out,header,4,true)&&transfer(out,body,size,true);close(out);if(ok) rename(temporary,destination);else unlink(temporary);}
    }
    free(body);
}
static void *refresh_registry(void *unused) {
    (void)unused;
    while(!stopping) {
        registry_snapshot();
        for(int i=0;i<5&&!stopping;i++) sleep(1);
        if(worker_ready) {
            char running[32];char *args[]={docker,"inspect","--format","{{.State.Running}}",worker,NULL};
            if(command(args,running,sizeof(running)) || strncmp(running,"true",4)) worker_ready=false;
        }
    }
    return NULL;
}
#include "MacRuntimeTargets.h"
static pthread_mutex_t docker_mutex=PTHREAD_MUTEX_INITIALIZER;
static bool start_docker_worker(void) {
    if(!*docker) return false;
    char bundles[PATH_MAX];snprintf(bundles,sizeof(bundles),"%s/bundles",resource_directory);
    char image_path[PATH_MAX],image[128];snprintf(image_path,sizeof(image_path),"%s/../worker-image",bundles);
    FILE *file=fopen(image_path,"r");if(!file || !fgets(image,sizeof(image),file)) {if(file)fclose(file);fprintf(stderr,"Missing tracing worker image\n");return false;}fclose(file);
    image[strcspn(image,"\r\n")]=0;
    char image_id[128];char *image_args[]={docker,"image","inspect","--format","{{.Id}}",image,NULL};
    if (command(image_args,image_id,sizeof(image_id))) {
        char context[PATH_MAX];snprintf(context,sizeof(context),"%s/worker-build",resource_directory);
        char *build_args[]={docker,"build","-t",image,context,NULL};
        if (command(build_args,NULL,0)) return false;
    }
    snprintf(worker,sizeof(worker),"outer-%s-worker-%u",APP_NAME,(unsigned)getuid());
    char *remove[]={docker,"rm","-f",worker,NULL};
    char owner[128];char *inspect[]={docker,"inspect","--format","{{index .Config.Labels \"org.outershell.tracing-worker\"}}",worker,NULL};
    if(!command(inspect,owner,sizeof(owner))) {
        owner[strcspn(owner,"\r\n")]=0;
        if(strcmp(owner,APP_NAME)) {fprintf(stderr,"Container name %s is already in use.\n",worker);return false;}
        if(command(remove,NULL,0)) return false;
    }
    char mount[PATH_MAX+64];snprintf(mount,sizeof(mount),"%s:/state",state);
    char *run[]={docker,"run","-d","--rm","--name",worker,"--label","org.outershell.tracing-worker=" APP_NAME,
        "--cap-add","BPF","--cap-add","PERFMON","--cap-add","SYS_PTRACE","--cap-add","DAC_READ_SEARCH",
        "--cap-add", !strcmp(APP_NAME,"Firehose")?"SYS_ADMIN":"PERFMON",
        "--security-opt","seccomp=unconfined","--pid=host","--cgroupns=host","--network","none","-v",mount,
        "-e","OUTER_CONTAINER_REGISTRY=/state/registry.bin",image,NULL};
    if(command(run,NULL,0)) {return false;}
    TracingTarget target={0};
    snprintf(target.provider,sizeof(target.provider),"docker-worker");
    snprintf(target.id,sizeof(target.id),"%s",worker);
    bool ready=false;
    for(int i=0;i<40&&!stopping;i++) {
        size_t length=0;
        unsigned char *response=target_request(&target,"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",&length);
        ready=response&&length>=12&&!memcmp(response,"HTTP/1.1 200",12);
        free(response);
        if(ready) break;
        usleep(250000);
    }
    if(!ready) {fprintf(stderr,"Container tracing worker failed to become ready.\n");command(remove,NULL,0);return false;}
    worker_ready=true;
    return true;
}
static void runtime_descriptor(int client) {
    const char *path="/bundles/" APP_NAME "Content";
    size_t length=40+strlen(path)+2;unsigned char *body=calloc(1,length);
    if(!body){runtime_error(client,"Out of memory");return;}
    memcpy(body,"OUTR",4);tracing_put32(body+4,1);tracing_put32(body+8,40);
    tracing_put32(body+16,(uint32_t)strlen(path));tracing_put32(body+24,(uint32_t)(40+strlen(path)));tracing_put32(body+32,2);
    memcpy(body+40,path,strlen(path));memcpy(body+40+strlen(path),"{}",2);
    runtime_response(client,200,"application/vnd.outerframe",body,length);free(body);
}
static void *proxy(void *value) {
    int client=*(int *)value;free(value);
    struct timeval timeout={.tv_sec=45};setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));setsockopt(client,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
    char request[65536];size_t used=0;
    while(used<sizeof(request)-1) {
        ssize_t n=read(client,request+used,sizeof(request)-1-used);if(n<0&&errno==EINTR)continue;if(n<=0){close(client);return NULL;}
        used+=(size_t)n;request[used]=0;if(strstr(request,"\r\n\r\n"))break;
    }
    char method[16],uri[2048];
    if(sscanf(request,"%15s %2047s",method,uri)!=2||(strcmp(method,"GET")&&strcmp(method,"HEAD"))){runtime_error(client,"Only GET and HEAD requests are supported");close(client);return NULL;}
    runtime_head_request=!strcmp(method,"HEAD");
    char target_key[320]="docker",*path=uri;
    bool selected=false;
    if(!strncmp(uri,"/targets/",9)) {
        char *end=strchr(uri+9,'/');if(!end||(size_t)(end-uri-9)>=sizeof(target_key)){runtime_error(client,"Invalid target");close(client);return NULL;}
        memcpy(target_key,uri+9,(size_t)(end-uri-9));target_key[end-uri-9]=0;
        path=end;selected=true;
    }
    if(!selected&&!strcmp(path,"/")){runtime_picker(client);close(client);return NULL;}
    if(!strcmp(path,"/")||!strncmp(path,"/traces/",8)) {
        if(strcasestr(request,"application/vnd.outerframe"))runtime_descriptor(client);
        else runtime_file(client,"web/index.html","text/html; charset=utf-8");
        close(client);return NULL;
    }
    if(!strncmp(path,"/web/",5)||!strcmp(path,"/favicon.ico")) {
        const char *relative=!strcmp(path,"/favicon.ico")?"web/app-icon.png":path+1;
        const char *type=strstr(relative,".css")?"text/css":strstr(relative,".js")?"text/javascript":strstr(relative,".png")?"image/png":"application/octet-stream";
        runtime_file(client,relative,type);close(client);return NULL;
    }
    if(!strncmp(path,"/bundles/",9)) {
        char relative[256];
        if(!strcmp(path,"/bundles/" APP_NAME "Content"))runtime_response(client,200,"text/plain","macos-arm\nmacos-x86\n",20);
        else if(!strcmp(path,"/bundles/" APP_NAME "Content/macos-arm")||!strcmp(path,"/bundles/" APP_NAME "Content/macos-x86")) {
            snprintf(relative,sizeof(relative),"bundles/" APP_NAME "Content.bundle.%s.aar",strstr(path,"macos-arm")?"macos-arm":"macos-x86");runtime_file(client,relative,"application/octet-stream");
        } else runtime_error(client,"Unknown bundle");
        close(client);return NULL;
    }
    char forwarded[65536];char *first_line=strstr(request,"\r\n");
    int written=first_line?snprintf(forwarded,sizeof(forwarded),"%s %s HTTP/1.1%s",method,path,first_line):-1;
    if(written<0||written>=(int)sizeof(forwarded)){runtime_error(client,"Request is too large");close(client);return NULL;}
    if(strcmp(target_key,"docker")) {
        TracingTarget targets[256],*target=NULL;size_t count=runtime_targets(targets,256);
        for(size_t i=0;i<count;i++){char key[320];snprintf(key,sizeof(key),"%s:%s",targets[i].provider,targets[i].id);if(!strcmp(key,target_key)){target=&targets[i];break;}}
        if(!target||strcmp(target->state,"running"))runtime_error(client,"The selected container is not running or is no longer registered.");
        else {
            size_t length=0;unsigned char *response=target_request(target,forwarded,&length);
            if(response){transfer(client,response,length,true);free(response);}
            else runtime_error(client,"The container tracing helper is unavailable. Install the app's helper in the container image; Profile also requires perf and profiling capabilities.");
        }
        close(client);return NULL;
    }
    pthread_mutex_lock(&docker_mutex);bool ready=worker_ready||start_docker_worker();pthread_mutex_unlock(&docker_mutex);
    TracingTarget target={0};
    snprintf(target.provider,sizeof(target.provider),"docker-worker");
    snprintf(target.id,sizeof(target.id),"%s",worker);
    size_t length=0;unsigned char *response=ready?target_request(&target,forwarded,&length):NULL;
    if(response){transfer(client,response,length,true);free(response);}
    else runtime_error(client,"Docker tracing worker unavailable. Check that Docker is running.");
    close(client);return NULL;
}

int main(int argc,char **argv) {
    const char *socket_path=NULL,*bundles=NULL,*launchd_name=NULL;
    char resources[PATH_MAX], executable[PATH_MAX];
    uint32_t capacity=sizeof(executable);
    if(_NSGetExecutablePath(executable,&capacity)) return 1;
    char *slash=strrchr(executable,'/');if(!slash) return 1;*slash=0;
    snprintf(resources,sizeof(resources),"%s/../Resources/bundles",executable);
    bundles=resources;
    for(int i=1;i<argc;i++) {
        if(!strcmp(argv[i],"--socket-path") && i+1<argc) socket_path=argv[++i];
        else if(!strcmp(argv[i],"--launchd-socket-name") && i+1<argc) launchd_name=argv[++i];
        else if(!strcmp(argv[i],"--bundles-dir") && i+1<argc) bundles=argv[++i];
        else if(!strcmp(argv[i],"--state-dir") && i+1<argc) snprintf(state,sizeof(state),"%s",argv[++i]);
        else if((!strcmp(argv[i],"--label")||!strcmp(argv[i],"--icon-file")||!strcmp(argv[i],"--api-socket-path")||!strcmp(argv[i],"--web-root")) && i+1<argc) i++;
        else {fprintf(stderr,"Unsupported argument: %s\n",argv[i]);return 2;}
    }
    if(!socket_path||!bundles) {fprintf(stderr,"--socket-path and --bundles-dir are required\n");return 2;}
    const char *home=getenv("HOME"); if(!home) return 1;
    if(!*state) {
        const char *service=getenv("OUTERSHELL_SERVICE_STATE_DIR");
        if(service && *service) snprintf(state,sizeof(state),"%s",service);
        else snprintf(state,sizeof(state),"%s/Library/Application Support/org.outershell.%s",home,APP_NAME);
    }
    if(mkdir(state,0700) && errno!=EEXIST) {perror(state);return 1;}
    const char *candidates[]={"/usr/local/bin/docker","/opt/homebrew/bin/docker","/Applications/Docker.app/Contents/Resources/bin/docker",NULL};
    for(int i=0;candidates[i];i++) if(!access(candidates[i],X_OK)) {snprintf(docker,sizeof(docker),"%s",candidates[i]);break;}
    snprintf(resource_directory,sizeof(resource_directory),"%s/..",bundles);
    signal(SIGPIPE,SIG_IGN);signal(SIGTERM,stop);signal(SIGINT,stop);
    registry_snapshot();pthread_t registry;pthread_create(&registry,NULL,refresh_registry,NULL);
    int listener=-1;
    if(launchd_name) {
        int *fds=NULL;size_t count=0;
        int error=launch_activate_socket(launchd_name,&fds,&count);
        if(error || count!=1) {free(fds);fprintf(stderr,"Could not activate launchd socket: %d\n",error);goto cleanup;}
        listener=fds[0];free(fds);
    } else {
        listener=socket(AF_UNIX,SOCK_STREAM,0);if(listener<0) goto cleanup;
        struct sockaddr_un address={.sun_family=AF_UNIX};if(strlen(socket_path)>=sizeof(address.sun_path)){close(listener);goto cleanup;}
        strcpy(address.sun_path,socket_path);unlink(socket_path);
        if(bind(listener,(struct sockaddr *)&address,sizeof(address))||chmod(socket_path,0600)||listen(listener,64)) {perror("listen");close(listener);goto cleanup;}
    }
    fcntl(listener,F_SETFD,FD_CLOEXEC);
    fprintf(stderr,APP_NAME " container tracing listening on %s\n",socket_path);
    while(!stopping) {
        struct pollfd pfd={.fd=listener,.events=POLLIN};if(poll(&pfd,1,1000)<=0) continue;
        int client=accept(listener,NULL,NULL);if(client<0) continue;
        fcntl(client,F_SETFD,FD_CLOEXEC);int *value=malloc(sizeof(int));if(!value){close(client);continue;}*value=client;
        pthread_t thread;if(pthread_create(&thread,NULL,proxy,value)){free(value);close(client);}else pthread_detach(thread);
    }
    close(listener);if(!launchd_name) unlink(socket_path);
cleanup:
    stopping=1;pthread_join(registry,NULL);targets_close();
    if(worker_ready) {char *remove[]={docker,"rm","-f",worker,NULL};command(remove,NULL,0);}
    return 0;
}
