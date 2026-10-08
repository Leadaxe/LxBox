import json,sys
conf,port=sys.argv[1],int(sys.argv[2])
i1f=sys.argv[3] if len(sys.argv)>3 else None
i2f=sys.argv[4] if len(sys.argv)>4 else None
kv={}
for line in open(conf):
    line=line.strip()
    if '=' in line and not line.startswith('#') and not line.startswith('['):
        k,v=line.split('=',1); kv[k.strip().lower()]=v.strip()
addrs=[a.strip() for a in kv['address'].split(',')]
addrs=[a if '/' in a else (a+'/128' if ':' in a else a+'/32') for a in addrs]
host,p=kv['endpoint'].rsplit(':',1)
ep=dict(type='wireguard',tag='wg',system=False,mtu=int(kv.get('mtu',1280)),address=addrs,private_key=kv['privatekey'],
  peers=[dict(address=host,port=int(p),public_key=kv['publickey'],allowed_ips=['0.0.0.0/0','::/0'],persistent_keepalive_interval=25)])
for k in ('jc','jmin','jmax','s1','s2','h1','h2','h3','h4'):
    if k in kv: ep[k]=int(kv[k])
if i1f: ep['i1']=open(i1f).read().strip()
elif 'i1' in kv: ep['i1']=kv['i1']
if i2f: ep['i2']=open(i2f).read().strip()
cfg=dict(log=dict(level='warn'),inbounds=[dict(type='mixed',tag='in',listen='127.0.0.1',listen_port=port)],endpoints=[ep],route=dict(final='wg'))
print(json.dumps(cfg))
