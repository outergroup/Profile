#!/usr/bin/env python3
import http.client, os, pathlib, socket, struct, subprocess, tempfile, time, sys
root=pathlib.Path(__file__).resolve().parents[1]
class Connection(http.client.HTTPConnection):
    def __init__(self,path):super().__init__('localhost',timeout=10);self.path=str(path)
    def connect(self):self.sock=socket.socket(socket.AF_UNIX);self.sock.connect(self.path)
def get(path,url):
    c=Connection(path);c.request('GET',url);r=c.getresponse();data=r.read();c.close();assert r.status==200,(r.status,data);return data
with tempfile.TemporaryDirectory(prefix='profile-test-',dir='/tmp') as temporary:
    work=pathlib.Path(temporary)
    subprocess.run(['cc','-std=gnu17','-O1','-g','-fsanitize=address,undefined',str(root/'Backend/main.c'),'-lpthread','-lm','-o',str(work/'backend')],check=True)
    process=subprocess.Popen([str(work/'backend'),'--socket-path',str(work/'socket')],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    try:
        for _ in range(100):
            if (work/'socket').exists():break
            if process.poll() is not None:raise RuntimeError(process.stderr.read().decode())
            time.sleep(.03)
        def check(data,stride):
            count,offset,strings=struct.unpack_from('<III',data,16)
            assert strings==offset+count*stride
            for i in range(count):
                o=offset+i*stride
                if struct.unpack_from('<I',data,o)[0]==os.getpid():return o
            raise AssertionError('test process missing')
        check(get(work/'socket','/api/processes'),24)
        data=get(work/'socket','/api/processes?containers=1');o=check(data,56)
        def text(field):
            start,length=struct.unpack_from('<II',data,field);assert start+length<=len(data);return data[start:start+length].decode()
        assert text(o+24)=='Host' and text(o+32)=='host'
        assert struct.unpack_from('<I',data,o+40)[0]==os.getpid()
        (work/'processes.bin').write_bytes(data)
        if len(sys.argv) > 1:
            pathlib.Path(sys.argv[1]).write_bytes(data)
            print('Decoder fixture PID:', os.getpid())
        else:
            subprocess.run(['node',str(root/'Scripts/test_container_codec.cjs'),str(work/'processes.bin'),str(os.getpid())],check=True)
        print('PASS process host identity, container metadata, and unchanged outerframe response')
    finally:
        process.terminate();process.wait(timeout=5);process.stderr.close()
