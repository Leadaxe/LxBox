# Direct UDP socket probe — no tunnel, no core. Sends QUIC Initial decoy blobs
# straight to a host:443 and counts replies. Separates "general DPI" from
# "endpoint-specific handling": a server that answers proves the form is valid
# AND the path is not dropping it. Usage: python3 -I socket_probe.py
import socket, time, binascii, sys
def load(p):
    s=open(p).read().strip(); s=s[s.index('0x')+2:s.rindex('>')]; return binascii.unhexlify(s)
K1=[load('blobs/K1_cloudflare_com_i1.cps')]
C133=[load('blobs/C133_cloudflare_com_i%d.cps'%n) for n in (1,2,3)]
targets=[('cloudflare.com 104.16.132.229','104.16.132.229'),('1.1.1.1','1.1.1.1'),('WARP 162.159.192.1','162.159.192.1')]
def probe(name,ip,pkts,label):
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.bind(('0.0.0.0',0))
    for p in pkts: s.sendto(p,(ip,443)); time.sleep(0.002)
    s.settimeout(2.5); got=0; sizes=[]
    try:
        while True:
            d,a=s.recvfrom(4096); got+=1; sizes.append(len(d))
            if got>=6: break
    except socket.timeout: pass
    print("  %-26s %-5s resp=%d %s"%(name,label,got,sizes)); s.close(); time.sleep(0.3)
for name,ip in targets:
    probe(name,ip,K1,"K1"); probe(name,ip,C133,"C133")
