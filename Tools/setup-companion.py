#!/usr/bin/env python3
"""Create a private LAN HTTPS identity. Never changes device trust automatically."""
import argparse, json, os, pathlib, secrets, subprocess, tempfile
p = argparse.ArgumentParser()
p.add_argument('--directory', type=pathlib.Path, default=pathlib.Path.home()/'Library/Application Support/Blessenger/Companion')
p.add_argument('--host', default=None)
p.add_argument('--port', type=int, default=8943)
a = p.parse_args()
host = a.host or subprocess.check_output(['/usr/sbin/scutil','--get','LocalHostName'], text=True).strip()+'.local'
if not host or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.' for c in host): p.error('Invalid hostname')
if not 1 <= a.port <= 65535: p.error('Invalid port')
root = a.directory.resolve()
root.mkdir(parents=True, exist_ok=True, mode=0o700)
if (root/'configuration.json').exists():
    print('Already configured:', root); raise SystemExit(0)
if any(root.iterdir()): p.error('Directory is not empty; inspect the incomplete setup before retrying')
os.umask(0o077)
password=secrets.token_hex(32)
with tempfile.TemporaryDirectory(prefix='blessenger-https-') as temporary:
    d=pathlib.Path(temporary)
    (d/'ca.cnf').write_text('[req]\ndistinguished_name=dn\nx509_extensions=ca\nprompt=no\n[dn]\nCN=Blessenger '+host+'\n[ca]\nbasicConstraints=critical,CA:true,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\nnameConstraints=critical,permitted;DNS:'+host+'\n')
    (d/'server.cnf').write_text('[req]\ndistinguished_name=dn\nprompt=no\n[dn]\nCN='+host+'\n[server]\nbasicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\nsubjectAltName=DNS:'+host+'\n')
    def run(*args): subprocess.run(['/usr/bin/openssl',*args],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
    run('req','-x509','-newkey','rsa:3072','-nodes','-days','3650','-sha256','-config',str(d/'ca.cnf'),'-keyout',str(root/'ca.key'),'-out',str(root/'ca.pem'))
    run('req','-newkey','rsa:2048','-nodes','-config',str(d/'server.cnf'),'-keyout',str(d/'server.key'),'-out',str(d/'server.csr'))
    run('x509','-req','-in',str(d/'server.csr'),'-CA',str(root/'ca.pem'),'-CAkey',str(root/'ca.key'),'-set_serial','0x'+secrets.token_hex(16),'-days','365','-sha256','-extfile',str(d/'server.cnf'),'-extensions','server','-out',str(d/'server.pem'))
    env=dict(os.environ,BLESSENGER_P12_PASSWORD=password)
    subprocess.run(['/usr/bin/openssl','pkcs12','-export','-in',str(d/'server.pem'),'-inkey',str(d/'server.key'),'-certfile',str(root/'ca.pem'),'-out',str(root/'server.p12'),'-passout','env:BLESSENGER_P12_PASSWORD'],env=env,check=True,stderr=subprocess.PIPE)
    run('x509','-in',str(root/'ca.pem'),'-outform','DER','-out',str(root/'Blessenger.cer'))
config={'host':host,'port':a.port,'password':password,'invite':secrets.token_hex(32),'session':secrets.token_hex(32)}
(root/'configuration.json').write_text(json.dumps(config,indent=2)+'\n')
print('Configured:',root)
print('Address: https://'+host+':'+str(a.port))
print('Install Blessenger.cer on the iPhone and enable full trust for this certificate in Settings > General > About > Certificate Trust Settings.')
print('Then open Blessenger > Connect iPhone on the Mac and scan the pairing code. Keep the Mac awake while using the phone.')
