#!/usr/bin/env python3
"""Deterministic controller lifecycle; no homelab requests or real downloads."""
import json, os, sqlite3, subprocess, tempfile, threading, time, unittest
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs
from api_smoke import request, ROOT

class Upstream(BaseHTTPRequestHandler):
    file = None
    grabs = []
    owner = False
    healthy = True
    conflict = False
    active_movie = False
    def log_message(self,*args): pass
    def reply(self,data,status=200):
        body=json.dumps(data).encode(); self.send_response(status); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(body))); self.end_headers();self.wfile.write(body)
    def do_GET(self):
        p=urlparse(self.path).path
        if p=='/api/v3/series/9':return self.reply({'id':9,'title':'Fixture Series','qualityProfileId':1,'originalLanguage':{'id':1},'runtime':45})
        if p=='/api/v2/torrents/files':return self.reply([{'name':f'Fixture.Series.S01E{n:02}.mkv','priority':7 if n==1 else 0} for n in (1,2,3,4)])
        if p=='/api/v3/episode':return self.reply([{'id':449+n,'seriesId':9,'seasonNumber':1,'episodeNumber':n} for n in range(1,9)])
        if p.startswith('/api/v3/episode/'):
            return self.reply({'id':int(p.rsplit('/',1)[1]),'seriesId':9,'hasFile':False,'episodeFileId':0})
        if p=='/api/v3/parse':
            title=parse_qs(urlparse(self.path).query)['title'][0]
            number=int(title.split('S01E')[1][:2])
            return self.reply({'parsedEpisodeInfo':{'seriesTitle':'Fixture Series','seasonNumber':1,'episodeNumbers':[number]}})
        if p=='/health':return self.reply({'healthy':self.healthy})
        if p=='/api/v3/movie/48':return self.reply({'id':48,'title':'Fixture','qualityProfileId':1,'originalLanguage':{'id':1},'hasFile':self.file is not None,'movieFile':self.file or {}})
        if p=='/api/v3/qualityprofile/1':return self.reply({'name':'Fixture profile','upgradeAllowed':True,'cutoff':19,'cutoffFormatScore':1000,'minFormatScore':0,'minUpgradeFormatScore':1,'items':[{'quality':{'id':7},'allowed':True},{'quality':{'id':19},'allowed':True}]})
        if p=='/api/v3/release':
            return self.reply([{'guid':g,'title':g,'indexerId':1,'size':size,'seeders':30,'quality':{'quality':{'id':qid,'name':name,'resolution':res}},'languages':[{'id':1}],'customFormatScore':score,'approved':True,'rejected':False,'temporarilyRejected':False,'downloadAllowed':True,'protocol':'torrent','infoHash':h*40} for g,size,qid,name,res,score,h in [('compact',2*1024**3,7,'Bluray-1080p',1080,20,'a'),('upgrade',15*1024**3,19,'Bluray-2160p',2160,1000,'b')]])
        if p=='/api/v3/queue':return self.reply({'totalRecords':8,'records':([{'movieId':48,'downloadId':'d'*40}] if self.active_movie else []) + [{'seriesId':9,'episodeId':449+n,'downloadId':'c'*40} for n in range(1,9)]})
        return self.reply({},404)
    def do_POST(self):
        p=self.path; body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))))
        if p=='/ownership/claim':
            if self.conflict:return self.reply({},409)
            type(self).owner=True; return self.reply({'token':'private-owner-token'})
        if p=='/ownership/release':type(self).owner=False;return self.reply({'released':True})
        if p=='/api/v3/release':type(self).grabs.append(body['guid']);return self.reply({})
        return self.reply({},404)

class ControllerContract(unittest.TestCase):
    def setUp(self):
        Upstream.file=None;Upstream.grabs=[];Upstream.owner=False;Upstream.healthy=True;Upstream.conflict=False;Upstream.active_movie=False
        self.server=ThreadingHTTPServer(('127.0.0.1',0),Upstream)
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()
        self.temp=tempfile.TemporaryDirectory(prefix='prontarr-controller-');self.folder=Path(self.temp.name)
        url=f'http://127.0.0.1:{self.server.server_port}'
        config={'radarr':{'url':url,'api_key':'fixture-secret'},'sonarr':{'url':url,'api_key':'fixture-secret'},'qbittorrent':{'url':url},'coordinator':{'url':url},'vpn_health':{'url':url},'execution':{'enabled':True,'allowed_movie_ids':[48]}}
        path=self.folder/'connections.json';path.write_text(json.dumps(config));path.chmod(0o600)
        self.env=os.environ|{'PRONTARR_DB':str(self.folder/'db.sqlite'),'PRONTARR_CONNECTIONS':str(path)}
        self.log=tempfile.TemporaryFile();self.process=None;self.start()
    def start(self):
        self.process=subprocess.Popen([str(ROOT/'zig-out/bin/prontarr')],cwd=ROOT,env=self.env,stdout=self.log,stderr=self.log)
        for _ in range(100):
            if self.process.poll() is not None:self.log.seek(0);raise AssertionError(self.log.read().decode())
            try:
                if request('/api/health')[0]==200:return
            except OSError:pass
            time.sleep(.05)
        raise AssertionError('server startup timeout')
    def stop(self):
        if self.process and self.process.poll() is None:self.process.terminate();self.process.wait(timeout=5)
    def tearDown(self):
        self.stop();self.server.shutdown();self.server.server_close();self.log.close();self.temp.cleanup()
    def wait_stage(self,id,stage):
        for _ in range(100):
            status,data,_=request(f'/api/jobs/{id}')
            if data['job']['stage']==stage:return data
            time.sleep(.1)
        raise AssertionError(data)
    def plan(self):
        status,data,_=request('/api/jobs',{'target':{'app':'radarr','media_id':48}});self.assertEqual(status,202)
        self.wait_stage(data['id'],'ready');return data['id']
    def test_full_lifecycle_restart_idempotency_and_redaction(self):
        id=self.plan();status,again,_=request('/api/jobs',{'target':{'app':'radarr','media_id':48}});self.assertEqual(again['id'],id)
        self.assertEqual(request(f'/api/jobs/{id}/start',{})[0],202)
        self.wait_stage(id,'compact')
        for _ in range(50):
            if Upstream.grabs:break
            time.sleep(.1)
        self.assertEqual(Upstream.grabs,['compact']);self.assertTrue(Upstream.owner)
        self.stop()
        with sqlite3.connect(self.folder/'db.sqlite') as db:
            state=json.loads(db.execute('SELECT state FROM live_jobs WHERE id=?',(id,)).fetchone()[0])
            state['stage']='completed'
            for n in range(150):db.execute('INSERT INTO live_jobs(request_key,state) VALUES(?,?)',(f'past-{n}',json.dumps(state)))
        self.start();time.sleep(2.2);self.assertEqual(Upstream.grabs,['compact'])
        Upstream.file={'id':10,'quality':{'quality':{'id':7}},'customFormatScore':20}
        self.wait_stage(id,'upgrading')
        for _ in range(50):
            if len(Upstream.grabs)==2:break
            time.sleep(.1)
        self.assertEqual(Upstream.grabs,['compact','upgrade'])
        Upstream.file={'id':11,'quality':{'quality':{'id':19}},'customFormatScore':1000}
        final=self.wait_stage(id,'completed');self.assertFalse(Upstream.owner)
        encoded=json.dumps(final)
        for secret in ['private-owner-token','fixture-secret','indexer_id','"guid"']:self.assertNotIn(secret,encoded)
        self.assertEqual((self.folder/'db.sqlite').stat().st_mode&0o777,0o600)
    def test_vpn_failure_prevents_claim_and_grab_then_cancel(self):
        id=self.plan();Upstream.healthy=False;request(f'/api/jobs/{id}/start',{});time.sleep(2.3)
        self.assertEqual(Upstream.grabs,[]);self.assertFalse(Upstream.owner)
        Upstream.healthy=True
        self.wait_stage(id,'compact')
        recovered=request(f'/api/jobs/{id}')[1]
        self.assertIsNone(recovered['job']['error_code'])
        request(f'/api/jobs/{id}/cancel',{});self.wait_stage(id,'cancelled')
        self.assertFalse(Upstream.owner)
    def test_ownership_conflict_prevents_grab(self):
        id=self.plan();Upstream.conflict=True;request(f'/api/jobs/{id}/start',{})
        self.wait_stage(id,'review');self.assertEqual(Upstream.grabs,[])
    def test_existing_native_download_prevents_duplicate_acquisition(self):
        id=self.plan();Upstream.active_movie=True
        request(f'/api/jobs/{id}/start',{})
        detail=self.wait_stage(id,'review')
        self.assertEqual(detail['job']['error_code'],'ExistingDownloadNeedsAnalysis')
        self.assertEqual(Upstream.grabs,[]);self.assertFalse(Upstream.owner)

    def test_pack_scope_uses_file_priorities_not_eight_queue_rows(self):
        status,data,_=request('/api/jobs',{'target':{'app':'sonarr','media_id':9,'original_hash':'c'*40}})
        self.assertEqual(status,202)
        detail=self.wait_stage(data['id'],'ready')
        scope=detail['report']['scope']
        self.assertTrue(scope['verified'])
        self.assertEqual(scope['contained_episode_ids'],[450,451,452,453])
        self.assertEqual(scope['selected_episode_ids'],[450])
        self.assertEqual(scope['absent_queue_episode_ids'],[454,455,456,457])
        self.assertEqual(detail['job']['target']['episode_ids'],[450])

    def test_whitelist_and_second_process_lock(self):
        status,data,_=request('/api/jobs',{'target':{'app':'radarr','media_id':49}})
        self.assertEqual(request(f'/api/jobs/{data["id"]}/start',{})[0],409)
        other=subprocess.run([str(ROOT/'zig-out/bin/prontarr')],cwd=ROOT,env=self.env,capture_output=True,timeout=5)
        self.assertNotEqual(other.returncode,0);self.assertIn(b'ControllerAlreadyRunning',other.stderr)

if __name__=='__main__':unittest.main(verbosity=2)
