#!/usr/bin/env python3
"""Add the ownership gate to the known legacy coordinator source, fail closed on drift.
Usage: patch_legacy.py SOURCE DESTINATION. Does not deploy or restart services.
"""
from pathlib import Path
import ast
import sys

def patch(source):
    if 'prontarr_ownership' in source:
        raise ValueError('Already patched; inspect installed integration')
    source=source.replace('import base64,','from prontarr_ownership import Ownership, Conflict\nimport base64,',1)
    for name in ('process_grab','process_import'):
        marker=f'def {name}(app,e):\n mid,ids=media_key(app,e)'
        if source.count(marker)!=1:raise ValueError(f'Unexpected {name} layout')
        source=source.replace(marker,f'def {name}(app,e):\n mid,ids=media_key(app,e)\n if ownership.owns(app,mid):return',1)
    marker=' for key,item in list(state.items()):\n  try:'
    if source.count(marker)!=1:raise ValueError('Unexpected reconcile layout')
    source=source.replace(marker,' for key,item in list(state.items()):\n  if ownership.owns(item["app"],item["mid"]):continue\n  try:',1)
    old="   if e.get('eventType')=='Grab':process_grab(app,e)\n   elif e.get('eventType') in ['Download','ImportComplete']:process_import(app,e)"
    new="   with lock:\n    if e.get('eventType')=='Grab':process_grab(app,e)\n    elif e.get('eventType') in ['Download','ImportComplete']:process_import(app,e)"
    if old not in source:raise ValueError('Unexpected worker layout')
    source=source.replace(old,new,1)
    old='  if time.monotonic()>=next_check:reconcile();next_check=time.monotonic()+30'
    if old not in source:raise ValueError('Unexpected reconcile scheduling')
    source=source.replace(old,'  if time.monotonic()>=next_check:\n   with lock:reconcile()\n   next_check=time.monotonic()+30',1)
    marker="  app=self.path.strip('/')"
    if source.count(marker)!=1:raise ValueError('Unexpected HTTP handler layout')
    route='''  if self.path in ['/ownership/claim','/ownership/release']:
   try:
    length=int(self.headers.get('Content-Length','0'))
    if not 0<length<=4096:self.send_error(413);return
    body=json.loads(self.rfile.read(length))
    if not isinstance(body,dict):raise ValueError('Object required')
    with lock:result=ownership.update(body,state,self.path.endswith('/release'))
   except Conflict:self.send_error(409);return
   except (ValueError,TypeError):self.send_error(400);return
   except Exception:self.send_error(503);return
   encoded=json.dumps(result).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(encoded)));self.end_headers();self.wfile.write(encoded);return
'''
    source=source.replace(marker,route+marker,1)
    marker=' threading.Thread(target=worker,daemon=True).start();'
    if source.count(marker)!=1:raise ValueError('Unexpected startup layout')
    source=source.replace(marker," ownership=Ownership('/etc/coisinhas/prontarr-ownership.json')\n"+marker,1)
    ast.parse(source)
    return source
if __name__=='__main__':Path(sys.argv[2]).write_text(patch(Path(sys.argv[1]).read_text()))
